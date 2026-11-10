# rk806_rstfix —— 修 RK3588「Linux 软件重启卡死」

## 现象
`systemctl reboot`（含飞牛 Web 重启）后：systemd-shutdown 正常完成、打印 `systemd-shutdown[1]: Rebooting.`，
随后串口完全静默、无 DDR/U-Boot、红灯、网络不通。板子只能断电重启。

## 根因
RK806 PMIC 的 `SYS_CFG3`（寄存器 0x72）bit[7:6] = `RST_FUN`（复位功能模式）。
厂商板级 DT 写的是 `pmic-reset-func = <1>`（MODE1）：厂商 u-boot（`drivers/power/pmic/rk8xx.c`、
`rk8xx_spi.c`）与 Android 内核（`drivers/mfd/rk806-core.c`）都会读它并写入 PMIC。

我们的主线 DTS / mainline `rk8xx` 驱动**都不支持该属性**，实测本板 PMIC `SYS_CFG3 = 0x02`
（RST_FUN=0 = MODE0）⇒ SoC 复位信号发出后 PMIC 不做整板复位，板子卡死。

## 实测验证（2026-10-30）
```
insmod rk806_rstfix.ko dry_run=1   # SYS_CFG3 原值=0x02, RST_FUN=0
insmod rk806_rstfix.ko mode=1      # 写 mode=1 后 SYS_CFG3=0x42, RST_FUN=1
sync; systemctl reboot             # 串口：DDR → U-Boot SPL → U-Boot → kernel → 登录，ping 恢复 ✅
```

## 构建（在板子/native arm64 上）
```bash
make -C /lib/modules/6.18.18-trim/build M=$PWD modules
strip --strip-debug rk806_rstfix.ko   # 10KB
```
产物放到 `assets/modules/6.18.18-trim/rk806_rstfix.ko`，
由 `patches/rootfs/27-vendor-modules.sh` 安装进 `updates/zerot1/`，
由 `patches/rootfs/53-rk806-rstfix.sh` 写 `/etc/modules-load.d/zt1-rk806-rstfix.conf` 开机自动加载。
