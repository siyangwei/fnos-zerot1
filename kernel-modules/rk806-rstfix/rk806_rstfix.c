// rk806_rstfix: 设置 RK806 SYS_CFG3(0x72) bit[7:6] = RST_FUN 模式
// 目的：验证"Linux 重启卡死"是否因 PMIC 复位功能未配置（厂商 DT 用 pmic-reset-func=<1>）
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/string.h>
#include <linux/device.h>
#include <linux/regmap.h>
#include <linux/spi/spi.h>

#define RK806_SYS_CFG3     0x72
#define RK806_RST_FUN_MASK 0xC0   /* bit[7:6] */

static char *dev_name_str = "spi2.0";
module_param(dev_name_str, charp, 0644);
MODULE_PARM_DESC(dev_name_str, "SPI device name of the PMIC (default spi2.0)");

static uint mode = 1;      /* 0=MODE0 1=MODE1 2=MODE2 */
module_param(mode, uint, 0644);
MODULE_PARM_DESC(mode, "RST_FUN mode: 0/1/2 (default 1)");

static bool dry_run = false;
module_param(dry_run, bool, 0644);
MODULE_PARM_DESC(dry_run, "only read/print, do not write");

static struct device *pmic_dev;

static int match_devname(struct device *dev, const void *data)
{
	return !strcmp(dev_name(dev), (const char *)data);
}

static int __init rk806_rstfix_init(void)
{
	struct regmap *map;
	unsigned int val = 0;
	int ret;

	pmic_dev = bus_find_device(&spi_bus_type, NULL, dev_name_str, match_devname);
	if (!pmic_dev) {
		pr_err("rk806_rstfix: 找不到 SPI 设备 %s\n", dev_name_str);
		return -ENODEV;
	}
	pr_info("rk806_rstfix: 找到设备 %s（driver=%s）\n", dev_name(pmic_dev),
		pmic_dev->driver ? pmic_dev->driver->name : "?");

	map = dev_get_regmap(pmic_dev, NULL);
	if (!map) {
		pr_err("rk806_rstfix: dev_get_regmap 返回 NULL\n");
		put_device(pmic_dev);
		return -ENODEV;
	}

	ret = regmap_read(map, RK806_SYS_CFG3, &val);
	if (ret) {
		pr_err("rk806_rstfix: 读 0x72 失败 %d\n", ret);
		put_device(pmic_dev);
		return ret;
	}
	pr_info("rk806_rstfix: SYS_CFG3 原值=0x%02x, RST_FUN=%u\n", val, (val >> 6) & 3);

	if (dry_run) {
		pr_info("rk806_rstfix: dry_run，不写\n");
		put_device(pmic_dev);
		return 0;
	}

	ret = regmap_update_bits(map, RK806_SYS_CFG3, RK806_RST_FUN_MASK,
				 (mode & 0x3) << 6);
	if (ret) {
		pr_err("rk806_rstfix: 写 0x72 失败 %d\n", ret);
		put_device(pmic_dev);
		return ret;
	}

	val = 0;
	ret = regmap_read(map, RK806_SYS_CFG3, &val);
	pr_info("rk806_rstfix: 写 mode=%u 后 SYS_CFG3=0x%02x, RST_FUN=%u\n",
		mode, val, (val >> 6) & 3);
	return 0;
}

static void __exit rk806_rstfix_exit(void)
{
	if (pmic_dev)
		put_device(pmic_dev);
	pr_info("rk806_rstfix: 卸载（寄存器保持，重启后由 bootloader 重写）\n");
}

module_init(rk806_rstfix_init);
module_exit(rk806_rstfix_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Set RK806 SYS_CFG3 RST_FUN for reboot test");
