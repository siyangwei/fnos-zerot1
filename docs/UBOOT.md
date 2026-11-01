# u-boot 定制（fnOS 镜像用）

本镜像的 `assets/uboot.img` 不是友善原版，而是从
`https://github.com/friendlyarm/uboot-rockchip` 分支 `nanopi6-v2017.09`
（`/home/zero/work/uboot-fa`）打补丁后重编的版本，解决了**千兆网口 99MHz** 问题。

## 为什么必须改 u-boot

1. u-boot 开了 `CONFIG_USING_KERNEL_DTB_V2`：启动时用**内核 dtb** 替换自己的 dtb，
   并按内核 dtb 的 `assigned-clock-rates` 配时钟。
2. 但 u-boot 的 PLL 编号比 mainline 内核大 1
   （内核 `AUPLL=4 CPLL=5 GPLL=6 NPLL=7 PPLL=8`；u-boot `AUPLL=5 CPLL=6 GPLL=7 NPLL=8 PPLL=9`）。
   ⇒ 内核 dtb 里 "GPLL=1188MHz" 被 u-boot 当成 "CPLL=1188MHz" 写入，
   CPLL 从 BL31 留下的 1500MHz 变成 1188MHz，GMAC 参考时钟只剩 99MHz（千兆不通、百兆帧损坏）。
3. 因此只能在 **跳内核前**（`arch_preboot_os()`，此时 Image/uInitrd 已进 RAM、eMMC 不再使用）
   把 CPLL 切回 1500MHz 并配好 GMAC 分频。

## 补丁内容（`patches/uboot/0001-zt1-uboot-cpll-ext4-directboot.patch`）

| 文件 | 改动 |
|---|---|
| `fs/ext4/Kconfig` | 补 `config FS_EXT4`（原文件为空，`CONFIG_FS_EXT4` 会被 defconfig 静默丢弃 ⇒ 重编 u-boot 读不了 ext4 的 boot 分区） |
| `drivers/clk/rockchip/clk_rk3588.c` | 新增 `zt1_set_cpll_1500()`：`rockchip_pll_set_rate(CPLL, 1500MHz)` + 写 `CLKSEL_CON(83)`（GMAC125M=CPLL/12） |
| `arch/arm/mach-rockchip/board.c` | ①`board_late_init()` 写死 bootargs 与直接引导 bootcmd（`load mmc 0:4 Image/uInitrd/dtb` + `booti`，绕开 boot.scr 与 distro_bootcmd 的 USB 崩溃）；②`arch_preboot_os()` 调用 `zt1_set_cpll_1500()` |
| `configs/nanopi6_defconfig` | 追加 `CONFIG_FS_EXT4=y` |

## 重编步骤

```bash
cd /home/zero/work/uboot-fa
ln -sfn ../rk35xx-android14/prebuilts prebuilts
ln -sfn ../rk35xx-android14/rkbin rkbin
git apply /home/zero/work/fnos-zerot1/patches/uboot/0001-zt1-uboot-cpll-ext4-directboot.patch
./make.sh nanopi6                       # 产出 uboot.img 4,194,304B
cp uboot.img /home/zero/work/fnos-zerot1/assets/uboot.img
```

## 验证

- 串口：`ZT1PB: cpll set ret=0` / `ZT1PB: con83=00008b9d cpll=1500000000` → `Starting kernel ...`
- Linux：`/sys/kernel/debug/clk/cpll/clk_rate` = 1500000000、
  `clk_gmac_125m/clk_rate` = 125000000、eth0 1000Mb/s、ping 0% 丢包。

## 恢复

实验失败时用 MaskROM 只回写 uboot 分区：

```bash
cd /home/zero/work/fnos-zerot1
sudo upgrade_tool_2.45 db assets/MiniLoaderAll.bin
sudo upgrade_tool_2.45 wl 0x4000 <uboot.img>
sudo upgrade_tool_2.45 rd
```
