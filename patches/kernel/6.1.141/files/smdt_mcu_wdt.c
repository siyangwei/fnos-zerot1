// SPDX-License-Identifier: GPL-2.0-only
/*
 * SMDT MCU watchdog driver
 *
 * The SMDT AIOT-3588A carrier board carries an STM8S00K3 companion MCU on
 * i2c-6 at address 0x62 (device tree node "mcuinf@62", compatible
 * "smdtmcu,STM8S00K3").  That MCU implements an independent watchdog whose
 * output is wired to the SoC reset input: if nobody kicks it, the SoC is
 * reset after roughly 603 seconds.
 *
 * Because that reset comes from outside the SoC it leaves no kernel log, no
 * pstore record and no reboot reason, which is why it looks like a
 * "spontaneous reboot".  The vendor BSP keeps the MCU alive with a user
 * space daemon that talks to /dev/i2c-6; this driver moves the kicker into
 * the kernel so that the protection no longer depends on a user space
 * process surviving, and adds the MCU status dump that was missing while the
 * reboots were being investigated.
 *
 * Register protocol, replicated from the vendor daemon (i2c-6, address 0x62,
 * register/value pairs on the wire as [reg, val]):
 *
 *	0x32 <- 0x01	arm the MCU watchdog
 *	0x51 <- 0x33	vendor configuration word
 *	0x33 <- 0xab	kick, repeated every 20 seconds
 *	0x32 <- 0x00	disarm
 *
 * The vendor daemon also polls a set of status registers (0x3a, 0x3b, 0xb1,
 * 0xb2, 0xd1 and the 0xe8..0xed revision block); the values it expects on a
 * healthy board match what this driver logs at probe time.
 *
 * Read sensitivity: 0x32, 0x33 and 0x51 are write-only in practice.  The
 * vendor user space daemon warns explicitly that reading them back has been
 * suspected of disturbing the MCU, so this driver only ever writes them and
 * never reads them, including through the mcu_reg debugging attribute.
 */

#include <linux/delay.h>
#include <linux/i2c.h>
#include <linux/kstrtox.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/sysfs.h>
#include <linux/watchdog.h>
#include <linux/workqueue.h>

/* Watchdog control registers (vendor protocol). */
#define SMDT_MCU_REG_WDT_CTRL		0x32
#define SMDT_MCU_REG_WDT_KICK		0x33
#define SMDT_MCU_REG_WDT_CFG		0x51

/* Status registers worth remembering across boots. */
#define SMDT_MCU_REG_CHIP_ID		0x3a
#define SMDT_MCU_REG_STATUS		0x3b
#define SMDT_MCU_REG_STATE		0xb1
#define SMDT_MCU_REG_WDT_RUNNING	0xb2
#define SMDT_MCU_REG_WDT_STATE		0xd1

#define SMDT_MCU_WDT_ARM		0x01
#define SMDT_MCU_WDT_DISARM		0x00
#define SMDT_MCU_KICK_MAGIC		0xab
#define SMDT_MCU_WDT_CFG_VENDOR		0x33

#define SMDT_MCU_CHIP_ID_EXPECTED	0x89
#define SMDT_MCU_WDT_STATE_DEFAULT	0x55
#define SMDT_MCU_WDT_STATE_ARMED	0x33
#define SMDT_MCU_WDT_RUNNING_ON		0x01

#define SMDT_MCU_FEED_INTERVAL_MS	20000	/* vendor daemon period */
#define SMDT_MCU_RETRY_INTERVAL_MS	5000	/* back-off after a failed kick */

/*
 * Positive verification cadence.  15 kicks at the default 20 s interval is
 * five minutes, matching what the vendor userspace daemon used to do.  A
 * successful i2c write only proves the bus works, not that the MCU still has
 * its watchdog armed, so the state register is re-read periodically even
 * while kicks keep succeeding.
 */
#define SMDT_MCU_VERIFY_EVERY_KICKS	15
#define SMDT_MCU_I2C_RETRIES		5	/* vendor tries 5 times ... */
#define SMDT_MCU_I2C_RETRY_DELAY_US	10000	/* ... 10 ms apart */
#define SMDT_MCU_MAX_CONSEC_ERRORS	3	/* before re-checking MCU health */

#define SMDT_MCU_DEFAULT_TIMEOUT_S	60
#define SMDT_MCU_MIN_TIMEOUT_S		10
#define SMDT_MCU_MAX_TIMEOUT_S		600	/* MCU window is ~603 s */

/**
 * struct smdt_mcu_wdt - driver private data
 * @client:		i2c client of the MCU
 * @wdd:		watchdog core representation
 * @lock:		serialises all i2c traffic and the state below
 * @feed_work:		periodic kick
 * @feed_interval_ms:	period between kicks while the MCU acknowledges them
 * @armed:		driver believes the MCU watchdog is armed
 * @feed_enabled:	autonomous kicking is allowed (cleared on stop/remove)
 * @suspended:		system is entering or leaving sleep
 * @trust_reset_hint:	report a detected MCU reset through WDIOF_CARDRESET
 * @kick_ok:		successful kicks
 * @kick_err:		failed kicks
 * @consec_err:		consecutive failed kicks or failed arming attempts
 * @last_err:		last i2c error, 0 when the last transfer succeeded
 * @boot_regs_valid:	probe time status registers were readable
 * @boot_id:		value of SMDT_MCU_REG_CHIP_ID at probe time
 * @boot_status:	value of SMDT_MCU_REG_STATUS at probe time
 * @boot_wdt_run:	value of SMDT_MCU_REG_WDT_RUNNING at probe time
 * @boot_wdt_state:	value of SMDT_MCU_REG_WDT_STATE at probe time
 * @reg_sel:		register selected through the mcu_reg attribute
 * @reg_val:		last value read through the mcu_reg attribute
 * @reg_valid:		whether @reg_val is valid
 * @reg_refused:	last mcu_reg request targeted a write-only register
 */
struct smdt_mcu_wdt {
	struct i2c_client	*client;
	struct watchdog_device	wdd;
	struct mutex		lock;	/* i2c access and everything below */
	struct delayed_work	feed_work;

	unsigned int		feed_interval_ms;

	bool			armed;
	bool			feed_enabled;
	bool			suspended;
	bool			trust_reset_hint;

	u64			kick_ok;
	u64			kick_err;
	unsigned int		consec_err;
	int			last_err;

	bool			boot_regs_valid;
	u8			boot_id;
	u8			boot_status;
	u8			boot_wdt_run;
	u8			boot_wdt_state;

	u8			reg_sel;
	u8			reg_val;
	bool			reg_valid;
	bool			reg_refused;
};

/*
 * The MCU watchdog guards the whole system, so a stray close() of the
 * watchdog device must not be able to switch it off.  Keep the vendor
 * behaviour (the watchdog stays armed) unless explicitly overridden.
 */
static bool nowayout = true;
module_param(nowayout, bool, 0444);
MODULE_PARM_DESC(nowayout,
		 "Watchdog cannot be stopped once started (default=true)");

static unsigned int timeout;
module_param(timeout, uint, 0444);
MODULE_PARM_DESC(timeout,
		 "Timeout in seconds, 0 to use the default or 'timeout-sec'");

/* ---------------------------------------------------------------------- */
/* i2c access							          */
/* ---------------------------------------------------------------------- */

/*
 * Both helpers use SMBus byte data transfers, which produce exactly the wire
 * format the vendor daemon uses: a two byte write ([reg, val]) and a write
 * of the register address followed by a one byte read.
 */
static int smdt_mcu_write(struct smdt_mcu_wdt *priv, u8 reg, u8 val)
{
	struct i2c_client *client = priv->client;
	int ret, i;

	for (i = 0; i < SMDT_MCU_I2C_RETRIES; i++) {
		ret = i2c_smbus_write_byte_data(client, reg, val);
		if (!ret)
			return 0;

		if (i + 1 < SMDT_MCU_I2C_RETRIES)
			usleep_range(SMDT_MCU_I2C_RETRY_DELAY_US,
				     SMDT_MCU_I2C_RETRY_DELAY_US + 1000);
	}

	dev_warn_ratelimited(&client->dev,
			     "i2c write 0x%02x=0x%02x failed (%d), %d attempts\n",
			     reg, val, ret, SMDT_MCU_I2C_RETRIES);
	return ret;
}

static int smdt_mcu_read(struct smdt_mcu_wdt *priv, u8 reg, u8 *val)
{
	struct i2c_client *client = priv->client;
	int ret, i;

	for (i = 0; i < SMDT_MCU_I2C_RETRIES; i++) {
		ret = i2c_smbus_read_byte_data(client, reg);
		if (ret >= 0) {
			*val = (u8)ret;
			return 0;
		}

		if (i + 1 < SMDT_MCU_I2C_RETRIES)
			usleep_range(SMDT_MCU_I2C_RETRY_DELAY_US,
				     SMDT_MCU_I2C_RETRY_DELAY_US + 1000);
	}

	dev_warn_ratelimited(&client->dev,
			     "i2c read 0x%02x failed (%d), %d attempts\n",
			     reg, ret, SMDT_MCU_I2C_RETRIES);
	return ret;
}

/* ---------------------------------------------------------------------- */
/* Watchdog protocol						          */
/* ---------------------------------------------------------------------- */

/*
 * Arming mirrors the vendor wdt_prepare() sequence: the MCU is disarmed
 * first, then armed and configured, and finally kicked once so the countdown
 * starts from a known point.  A failure part way through leaves the MCU
 * disarmed, which is the safe direction: a disarmed watchdog cannot reset
 * the SoC.
 *
 * Caller must hold @priv->lock.
 */
static int smdt_mcu_arm_locked(struct smdt_mcu_wdt *priv)
{
	int ret;

	ret = smdt_mcu_write(priv, SMDT_MCU_REG_WDT_CTRL, SMDT_MCU_WDT_DISARM);
	if (!ret)
		ret = smdt_mcu_write(priv, SMDT_MCU_REG_WDT_CTRL,
				     SMDT_MCU_WDT_ARM);
	if (!ret)
		ret = smdt_mcu_write(priv, SMDT_MCU_REG_WDT_CFG,
				     SMDT_MCU_WDT_CFG_VENDOR);
	if (!ret)
		ret = smdt_mcu_write(priv, SMDT_MCU_REG_WDT_KICK,
				     SMDT_MCU_KICK_MAGIC);

	if (ret) {
		priv->armed = false;
		priv->consec_err++;
		priv->last_err = ret;
		return ret;
	}

	priv->armed = true;
	priv->consec_err = 0;
	priv->last_err = 0;
	return 0;
}

/* Caller must hold @priv->lock. */
static int smdt_mcu_kick_locked(struct smdt_mcu_wdt *priv)
{
	int ret;

	ret = smdt_mcu_write(priv, SMDT_MCU_REG_WDT_KICK, SMDT_MCU_KICK_MAGIC);
	if (ret) {
		priv->kick_err++;
		priv->consec_err++;
		priv->last_err = ret;
		return ret;
	}

	priv->kick_ok++;
	priv->consec_err = 0;
	priv->last_err = 0;
	return 0;
}

/* Caller must hold @priv->lock. */
static int smdt_mcu_disarm_locked(struct smdt_mcu_wdt *priv)
{
	int ret;

	ret = smdt_mcu_write(priv, SMDT_MCU_REG_WDT_CTRL, SMDT_MCU_WDT_DISARM);
	priv->armed = false;
	return ret;
}

/**
 * smdt_mcu_verify_running_locked() - re-arm unless the MCU confirms it runs
 * @priv: driver private data
 *
 * The MCU's read-only 0xb2 tells whether its watchdog is currently running.
 * Anything other than the documented "on" value (or a failed read, which means
 * we simply do not know) makes the next feed cycle run the full arming
 * sequence again.  Only the read-only state register is touched here: 0x32,
 * 0x33 and 0x51 are write-sensitive and are never read back.
 *
 * Caller must hold @priv->lock.
 */
static void smdt_mcu_verify_running_locked(struct smdt_mcu_wdt *priv)
{
	u8 running;
	int ret;

	ret = smdt_mcu_read(priv, SMDT_MCU_REG_WDT_RUNNING, &running);
	if (ret)
		return;

	if (running != SMDT_MCU_WDT_RUNNING_ON) {
		dev_warn_ratelimited(&priv->client->dev,
				     "MCU watchdog reports stopped (0xb2=0x%02x), re-arming\n",
				     running);
		priv->armed = false;
	}
}

/**
 * smdt_mcu_health_check_locked() - re-arm after repeated kick failures
 * @priv: driver private data
 *
 * A failing kick means either that the i2c link is broken or that the MCU
 * lost its configuration (for example because the MCU itself was reset).
 * Only re-arm on positive evidence: the MCU answers and reports its
 * watchdog as stopped.  Rewriting the configuration register blindly is
 * avoided on purpose, because the exact meaning of 0x51 is not documented.
 *
 * Caller must hold @priv->lock.
 */
static void smdt_mcu_health_check_locked(struct smdt_mcu_wdt *priv)
{
	if (priv->consec_err < SMDT_MCU_MAX_CONSEC_ERRORS)
		return;

	smdt_mcu_verify_running_locked(priv);
}

/**
 * smdt_mcu_unarm() - stop autonomous kicking and disarm the MCU watchdog
 * @priv: driver private data
 * @sync: wait for a running kick to finish
 *
 * After this returns the board can no longer be reset by the MCU watchdog.
 *
 * Caller must not hold @priv->lock.
 */
static void smdt_mcu_unarm(struct smdt_mcu_wdt *priv, bool sync)
{
	if (sync)
		cancel_delayed_work_sync(&priv->feed_work);
	else
		cancel_delayed_work(&priv->feed_work);

	mutex_lock(&priv->lock);
	priv->feed_enabled = false;
	smdt_mcu_disarm_locked(priv);
	mutex_unlock(&priv->lock);
}

/* ---------------------------------------------------------------------- */
/* Periodic kick							          */
/* ---------------------------------------------------------------------- */

static void smdt_mcu_feed_work(struct work_struct *work)
{
	struct smdt_mcu_wdt *priv = container_of(to_delayed_work(work),
						 struct smdt_mcu_wdt,
						 feed_work);
	unsigned int delay_ms = priv->feed_interval_ms;

	mutex_lock(&priv->lock);
	if (priv->feed_enabled && !priv->suspended) {
		if (unlikely(!priv->armed)) {
			/*
			 * The MCU did not acknowledge the arming sequence yet
			 * (it may still have been booting when we probed).
			 * Keep trying: an unarmed MCU watchdog is harmless,
			 * while an armed one nobody kicks resets the SoC.
			 */
			if (smdt_mcu_arm_locked(priv))
				delay_ms = SMDT_MCU_RETRY_INTERVAL_MS;
		} else if (smdt_mcu_kick_locked(priv)) {
			delay_ms = SMDT_MCU_RETRY_INTERVAL_MS;
			smdt_mcu_health_check_locked(priv);
		} else if (!(priv->kick_ok % SMDT_MCU_VERIFY_EVERY_KICKS)) {
			/*
			 * Periodic positive check on the healthy path, so that
			 * an MCU which silently dropped its watchdog (while the
			 * i2c writes still succeed) gets re-armed instead of
			 * leaving the SoC unprotected.  This mirrors what the
			 * vendor userspace daemon used to do every five
			 * minutes; the driver is now the only implementation.
			 */
			smdt_mcu_verify_running_locked(priv);
		}
	}
	mutex_unlock(&priv->lock);

	/*
	 * Reschedule unconditionally.  While the system is suspending, the
	 * freezable system workqueue simply does not run this until resume,
	 * and a stale queued instance is harmless: queue_delayed_work() is a
	 * no-op while the work is already pending.  Never stopping the chain
	 * here is deliberate, so that an aborted suspend cannot leave the MCU
	 * unkicked.
	 */
	queue_delayed_work(system_wq, &priv->feed_work,
			   msecs_to_jiffies(delay_ms));
}

/* ---------------------------------------------------------------------- */
/* Watchdog core operations					          */
/* ---------------------------------------------------------------------- */

static int smdt_mcu_wdt_start(struct watchdog_device *wdd)
{
	struct smdt_mcu_wdt *priv = watchdog_get_drvdata(wdd);
	int ret;

	mutex_lock(&priv->lock);
	priv->feed_enabled = true;
	ret = smdt_mcu_arm_locked(priv);
	mutex_unlock(&priv->lock);

	if (!ret)
		mod_delayed_work(system_wq, &priv->feed_work, 0);

	return ret;
}

static int smdt_mcu_wdt_stop(struct watchdog_device *wdd)
{
	struct smdt_mcu_wdt *priv = watchdog_get_drvdata(wdd);

	/*
	 * Only reachable when the nowayout parameter was disabled: with
	 * WDOG_NO_WAY_OUT set the core refuses to stop the watchdog.
	 */
	smdt_mcu_unarm(priv, false);
	return 0;
}

static int smdt_mcu_wdt_ping(struct watchdog_device *wdd)
{
	struct smdt_mcu_wdt *priv = watchdog_get_drvdata(wdd);
	int ret;

	mutex_lock(&priv->lock);
	ret = smdt_mcu_kick_locked(priv);
	mutex_unlock(&priv->lock);

	return ret;
}

static const struct watchdog_ops smdt_mcu_wdt_ops = {
	.owner		= THIS_MODULE,
	.start		= smdt_mcu_wdt_start,
	.stop		= smdt_mcu_wdt_stop,
	.ping		= smdt_mcu_wdt_ping,
};

static const struct watchdog_info smdt_mcu_wdt_info = {
	.options	= WDIOF_KEEPALIVEPING | WDIOF_MAGICCLOSE,
	.identity	= "SMDT STM8S00K3 MCU watchdog",
};

static const struct watchdog_info smdt_mcu_wdt_info_reset = {
	.options	= WDIOF_KEEPALIVEPING | WDIOF_MAGICCLOSE |
			  WDIOF_CARDRESET,
	.identity	= "SMDT STM8S00K3 MCU watchdog",
};

/* ---------------------------------------------------------------------- */
/* Status decoding							          */
/* ---------------------------------------------------------------------- */

/**
 * smdt_mcu_reset_hint() - best effort interpretation of the boot status
 * @priv: driver private data
 *
 * The MCU keeps 0xd1 at 0x55 until something arms its watchdog, at which
 * point it reads 0x33.  The MCU is not reset by a SoC reset, so the value
 * seen at probe time says something about how the previous boot ended.  This
 * is a heuristic: it is reported as such, and only promoted to
 * WDIOF_CARDRESET when the device tree explicitly asks for it.
 *
 * Returns: a human readable hint, never %NULL.
 */
static const char *smdt_mcu_reset_hint(struct smdt_mcu_wdt *priv)
{
	if (!priv->boot_regs_valid)
		return "unknown, MCU did not answer at probe time";

	switch (priv->boot_wdt_state) {
	case SMDT_MCU_WDT_STATE_DEFAULT:
		return "0xd1=0x55 (power-on default): prev boot was not an MCU wdt reset";
	case SMDT_MCU_WDT_STATE_ARMED:
		return "0xd1=0x33 (still armed): MCU kept its state across the SoC reset";
	default:
		return "unrecognised 0xd1 value, compare against a known reset";
	}
}

static struct smdt_mcu_wdt *smdt_mcu_from_dev(struct device *dev)
{
	struct watchdog_device *wdd = dev_get_drvdata(dev);

	return watchdog_get_drvdata(wdd);
}

static ssize_t mcu_status_show(struct device *dev,
			       struct device_attribute *attr, char *buf)
{
	struct smdt_mcu_wdt *priv = smdt_mcu_from_dev(dev);
	int len = 0;

	mutex_lock(&priv->lock);
	len += sysfs_emit(buf + len, "state:            %s\n",
			  priv->armed ? "armed" : "disarmed");
	len += sysfs_emit(buf + len, "autonomous feed:  %s\n",
			  priv->feed_enabled ? "enabled" : "disabled");
	len += sysfs_emit(buf + len, "feed interval:    %u ms\n",
			  priv->feed_interval_ms);
	len += sysfs_emit(buf + len, "kicks ok/err:     %llu/%llu\n",
			  priv->kick_ok, priv->kick_err);
	len += sysfs_emit(buf + len, "consecutive err:  %u\n",
			  priv->consec_err);
	len += sysfs_emit(buf + len, "last i2c error:   %d\n", priv->last_err);
	len += sysfs_emit(buf + len, "timeout:          %u s (MCU window ~603 s)\n",
			  priv->wdd.timeout);
	len += sysfs_emit(buf + len, "nowayout:         %s\n",
			  nowayout ? "yes" : "no");
	if (priv->boot_regs_valid) {
		len += sysfs_emit(buf + len, "boot: 0x3a=0x%02x 0xb2=0x%02x\n",
				  priv->boot_id, priv->boot_wdt_run);
		len += sysfs_emit(buf + len, "boot: 0xd1=0x%02x 0x3b=0x%02x\n",
				  priv->boot_wdt_state, priv->boot_status);
	} else {
		len += sysfs_emit(buf + len, "boot: unreadable at probe time\n");
	}
	len += sysfs_emit(buf + len, "reset hint:       %s\n",
			  smdt_mcu_reset_hint(priv));
	mutex_unlock(&priv->lock);

	return len;
}
static DEVICE_ATTR_RO(mcu_status);

/**
 * smdt_mcu_reg_readable() - is a register safe to read back?
 * @reg: register address
 *
 * 0x32, 0x33 and 0x51 are write-only in practice.  The vendor user space
 * daemon calls them out as write sensitive and reports that reading them has
 * been suspected of triggering a reset, so they are never read - not by the
 * probe, not by mcu_regs and not through the mcu_reg debug knob.
 *
 * Returns: true if @reg may be read.
 */
static bool smdt_mcu_reg_readable(u8 reg)
{
	return reg != SMDT_MCU_REG_WDT_CTRL &&
	       reg != SMDT_MCU_REG_WDT_KICK &&
	       reg != SMDT_MCU_REG_WDT_CFG;
}

static ssize_t mcu_regs_show(struct device *dev,
			     struct device_attribute *attr, char *buf)
{
	/*
	 * A small curated set: the status registers the vendor daemon polls,
	 * plus its revision block.  The write-only watchdog registers are
	 * deliberately absent (see smdt_mcu_reg_readable()), and the whole
	 * 256 byte map is not dumped here because that would hold the lock for
	 * too long; use the mcu_reg attribute to poke individual registers.
	 */
	static const u8 regs[] = {
		SMDT_MCU_REG_CHIP_ID,		/* 0x3a */
		SMDT_MCU_REG_STATUS,		/* 0x3b */
		SMDT_MCU_REG_STATE,		/* 0xb1 */
		SMDT_MCU_REG_WDT_RUNNING,	/* 0xb2 */
		SMDT_MCU_REG_WDT_STATE,		/* 0xd1 */
		0xe8, 0xe9, 0xea, 0xeb, 0xec, 0xed,
	};
	struct smdt_mcu_wdt *priv = smdt_mcu_from_dev(dev);
	int len = 0;
	unsigned int i;

	mutex_lock(&priv->lock);
	for (i = 0; i < ARRAY_SIZE(regs); i++) {
		u8 val;
		int ret;

		ret = smdt_mcu_read(priv, regs[i], &val);
		if (ret)
			len += sysfs_emit(buf + len, "reg(0x%02x)=err(%d)\n",
					  regs[i], ret);
		else
			len += sysfs_emit(buf + len, "reg(0x%02x)=0x%02x\n",
					  regs[i], val);
	}
	mutex_unlock(&priv->lock);

	return len;
}
static DEVICE_ATTR_RO(mcu_regs);

static ssize_t mcu_reg_show(struct device *dev,
			    struct device_attribute *attr, char *buf)
{
	struct smdt_mcu_wdt *priv = smdt_mcu_from_dev(dev);
	ssize_t len;

	mutex_lock(&priv->lock);
	if (priv->reg_refused)
		len = sysfs_emit(buf,
				 "0x%02x=refused, write-only register\n",
				 priv->reg_sel);
	else if (priv->reg_valid)
		len = sysfs_emit(buf, "0x%02x=0x%02x\n", priv->reg_sel,
				 priv->reg_val);
	else
		len = sysfs_emit(buf, "0x%02x=read error\n", priv->reg_sel);
	mutex_unlock(&priv->lock);

	return len;
}

static ssize_t mcu_reg_store(struct device *dev,
			     struct device_attribute *attr, const char *buf,
			     size_t count)
{
	struct smdt_mcu_wdt *priv = smdt_mcu_from_dev(dev);
	u8 reg;
	int ret;

	/* Accepts both "0x3a" and "58". */
	ret = kstrtou8(buf, 0, &reg);
	if (ret)
		return ret;

	mutex_lock(&priv->lock);
	priv->reg_sel = reg;
	priv->reg_refused = !smdt_mcu_reg_readable(reg);
	if (priv->reg_refused) {
		priv->reg_valid = false;
		mutex_unlock(&priv->lock);
		dev_warn_ratelimited(dev,
				     "refusing to read write-only register 0x%02x\n",
				     reg);
		return -EPERM;
	}

	ret = smdt_mcu_read(priv, reg, &priv->reg_val);
	priv->reg_valid = !ret;
	mutex_unlock(&priv->lock);

	return count;
}
static DEVICE_ATTR_RW(mcu_reg);

static struct attribute *smdt_mcu_wdt_attrs[] = {
	&dev_attr_mcu_status.attr,
	&dev_attr_mcu_regs.attr,
	&dev_attr_mcu_reg.attr,
	NULL,
};
ATTRIBUTE_GROUPS(smdt_mcu_wdt);

/* ---------------------------------------------------------------------- */
/* Power management							          */
/* ---------------------------------------------------------------------- */

/*
 * Kicks cannot be delivered while the i2c controller is suspended, and the
 * MCU watchdog keeps counting through system sleep: leaving it armed would
 * reset the SoC after ~603 s in suspend.  Disarm on the way down, re-arm on
 * the way back up.  This is something a user space kicker cannot do at all.
 */
static int __maybe_unused smdt_mcu_wdt_suspend(struct device *dev)
{
	struct i2c_client *client = to_i2c_client(dev);
	struct smdt_mcu_wdt *priv = i2c_get_clientdata(client);

	cancel_delayed_work(&priv->feed_work);

	mutex_lock(&priv->lock);
	priv->suspended = true;
	if (priv->feed_enabled)
		smdt_mcu_disarm_locked(priv);
	mutex_unlock(&priv->lock);

	return 0;
}

static int __maybe_unused smdt_mcu_wdt_resume(struct device *dev)
{
	struct i2c_client *client = to_i2c_client(dev);
	struct smdt_mcu_wdt *priv = i2c_get_clientdata(client);
	int ret = 0;

	mutex_lock(&priv->lock);
	priv->suspended = false;
	if (priv->feed_enabled && !priv->armed)
		ret = smdt_mcu_arm_locked(priv);
	mutex_unlock(&priv->lock);

	mod_delayed_work(system_wq, &priv->feed_work, 0);

	return ret;
}

static const struct dev_pm_ops smdt_mcu_wdt_pm_ops = {
	SET_SYSTEM_SLEEP_PM_OPS(smdt_mcu_wdt_suspend, smdt_mcu_wdt_resume)
};

/* ---------------------------------------------------------------------- */
/* Probe / remove							          */
/* ---------------------------------------------------------------------- */

static void smdt_mcu_log_boot_status(struct smdt_mcu_wdt *priv)
{
	struct device *dev = &priv->client->dev;
	u8 id, status, running, state;
	int ret;

	ret = smdt_mcu_read(priv, SMDT_MCU_REG_CHIP_ID, &id);
	if (!ret && id != SMDT_MCU_CHIP_ID_EXPECTED)
		dev_warn(dev,
			 "unexpected chip id 0x%02x (vendor expects 0x%02x)\n",
			 id, SMDT_MCU_CHIP_ID_EXPECTED);

	if (ret ||
	    smdt_mcu_read(priv, SMDT_MCU_REG_WDT_RUNNING, &running) ||
	    smdt_mcu_read(priv, SMDT_MCU_REG_WDT_STATE, &state) ||
	    smdt_mcu_read(priv, SMDT_MCU_REG_STATUS, &status)) {
		priv->boot_regs_valid = false;
		dev_warn(dev, "MCU status registers unreadable\n");
		return;
	}

	priv->boot_regs_valid = true;
	priv->boot_id = id;
	priv->boot_wdt_run = running;
	priv->boot_wdt_state = state;
	priv->boot_status = status;

	dev_info(dev, "MCU status: 0x%02x=0x%02x 0x%02x=0x%02x 0x%02x=0x%02x 0x%02x=0x%02x\n",
		 SMDT_MCU_REG_CHIP_ID, id,
		 SMDT_MCU_REG_WDT_RUNNING, running,
		 SMDT_MCU_REG_WDT_STATE, state,
		 SMDT_MCU_REG_STATUS, status);

	/* One line the next reboot investigation can grep for. */
	dev_info(dev, "last-reset hint: %s\n", smdt_mcu_reset_hint(priv));
}

static int smdt_mcu_wdt_probe(struct i2c_client *client)
{
	struct device *dev = &client->dev;
	struct smdt_mcu_wdt *priv;
	u32 interval_ms = SMDT_MCU_FEED_INTERVAL_MS;
	int ret;

	if (!i2c_check_functionality(client->adapter, I2C_FUNC_SMBUS_BYTE_DATA))
		return dev_err_probe(dev, -EOPNOTSUPP,
				     "adapter lacks SMBus byte data support\n");

	priv = devm_kzalloc(dev, sizeof(*priv), GFP_KERNEL);
	if (!priv)
		return -ENOMEM;

	priv->client = client;
	mutex_init(&priv->lock);
	INIT_DELAYED_WORK(&priv->feed_work, smdt_mcu_feed_work);

	if (!of_property_read_u32(dev->of_node, "smdt,feed-interval-ms",
				  &interval_ms)) {
		if (interval_ms < 1000 || interval_ms > 120000) {
			dev_warn(dev, "smdt,feed-interval-ms=%u out of range, using %d\n",
				 interval_ms, SMDT_MCU_FEED_INTERVAL_MS);
			interval_ms = SMDT_MCU_FEED_INTERVAL_MS;
		}
	}
	priv->feed_interval_ms = interval_ms;
	priv->trust_reset_hint =
		of_property_read_bool(dev->of_node, "smdt,wdt-reset-detect");

	priv->wdd.parent = dev;
	priv->wdd.info = &smdt_mcu_wdt_info;
	priv->wdd.ops = &smdt_mcu_wdt_ops;
	priv->wdd.groups = smdt_mcu_wdt_groups;
	priv->wdd.timeout = SMDT_MCU_DEFAULT_TIMEOUT_S;
	priv->wdd.min_timeout = SMDT_MCU_MIN_TIMEOUT_S;
	priv->wdd.max_timeout = SMDT_MCU_MAX_TIMEOUT_S;
	watchdog_set_drvdata(&priv->wdd, priv);
	watchdog_set_nowayout(&priv->wdd, nowayout);

	ret = watchdog_init_timeout(&priv->wdd, timeout, dev);
	if (ret)
		dev_warn(dev, "invalid timeout, using %u s\n", priv->wdd.timeout);

	i2c_set_clientdata(client, priv);

	/*
	 * Snapshot and report the MCU state before touching anything, so the
	 * values still describe how the previous boot ended.
	 */
	mutex_lock(&priv->lock);
	smdt_mcu_log_boot_status(priv);

	/*
	 * The firmware is already armed when we get here (the bootloader or
	 * the vendor user space daemon did it), so advertise the hardware as
	 * running.  If nobody kicks it, it resets the SoC.
	 */
	set_bit(WDOG_HW_RUNNING, &priv->wdd.status);

	if (smdt_mcu_arm_locked(priv)) {
		/*
		 * Do not fail the probe: the MCU may still be booting, and the
		 * periodic work keeps retrying.  A missing kicker is far worse
		 * than a driver that shows up late.
		 */
		dev_warn(dev, "MCU watchdog did not acknowledge arming, retrying every %d ms\n",
			 SMDT_MCU_RETRY_INTERVAL_MS);
	}
	priv->feed_enabled = true;
	mutex_unlock(&priv->lock);

	if (priv->trust_reset_hint && priv->boot_regs_valid &&
	    priv->boot_wdt_state == SMDT_MCU_WDT_STATE_ARMED) {
		priv->wdd.info = &smdt_mcu_wdt_info_reset;
		priv->wdd.bootstatus = WDIOF_CARDRESET;
	}

	ret = devm_watchdog_register_device(dev, &priv->wdd);
	if (ret)
		return ret;

	queue_delayed_work(system_wq, &priv->feed_work,
			   msecs_to_jiffies(priv->feed_interval_ms));

	dev_info(dev, "kick 0x%02x=0x%02x every %u ms, timeout %u s, nowayout %s\n",
		 SMDT_MCU_REG_WDT_KICK, SMDT_MCU_KICK_MAGIC,
		 priv->feed_interval_ms, priv->wdd.timeout,
		 nowayout ? "on" : "off");
	dev_info(dev, "watchdog%d registered (MCU hardware window ~603 s)\n",
		 priv->wdd.id);

	return 0;
}

static void smdt_mcu_wdt_remove(struct i2c_client *client)
{
	struct smdt_mcu_wdt *priv = i2c_get_clientdata(client);

	/*
	 * Order matters: stop kicking first, then disarm, so a kick can never
	 * race with the arming state.
	 */
	smdt_mcu_unarm(priv, true);

	dev_info(&client->dev, "removed, MCU watchdog disarmed (%llu kicks, %llu errors)\n",
		 priv->kick_ok, priv->kick_err);
}

static void smdt_mcu_wdt_shutdown(struct i2c_client *client)
{
	struct smdt_mcu_wdt *priv = i2c_get_clientdata(client);

	/*
	 * A clean shutdown should not leave the MCU holding the SoC reset
	 * line, so disarm it.  This matches the vendor daemon, which disarms
	 * with 0x32=0x00.
	 */
	smdt_mcu_unarm(priv, false);
}

static const struct of_device_id smdt_mcu_wdt_of_match[] = {
	{ .compatible = "smdtmcu,STM8S00K3" },
	{ /* sentinel */ }
};
MODULE_DEVICE_TABLE(of, smdt_mcu_wdt_of_match);

static const struct i2c_device_id smdt_mcu_wdt_id[] = {
	{ "smdt-mcu-wdt", 0 },
	{ /* sentinel */ }
};
MODULE_DEVICE_TABLE(i2c, smdt_mcu_wdt_id);

static struct i2c_driver smdt_mcu_wdt_driver = {
	.driver = {
		.name		= "smdt-mcu-wdt",
		.of_match_table	= smdt_mcu_wdt_of_match,
		.pm		= &smdt_mcu_wdt_pm_ops,
	},
	.probe_new	= smdt_mcu_wdt_probe,
	.remove		= smdt_mcu_wdt_remove,
	.shutdown	= smdt_mcu_wdt_shutdown,
	.id_table	= smdt_mcu_wdt_id,
};
module_i2c_driver(smdt_mcu_wdt_driver);

MODULE_AUTHOR("zeroT1 BSP");
MODULE_DESCRIPTION("SMDT AIOT-3588A onboard STM8S00K3 MCU watchdog driver");
MODULE_LICENSE("GPL");
