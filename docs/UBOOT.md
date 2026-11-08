# u-boot 与引导链（fnOS 镜像用）

本仓库支持两套 u-boot 方案，由 `scripts/pack-image.sh` 的 `UBOOT_MODE` 选择：

| 模式 | 默认 | loader | uboot 分区 | 说明 |
|---|---|---|---|---|
| `upstream` | ✅ | `assets/uboot-upstream/MiniLoaderAll.bin`（LDR） | `assets/uboot-upstream/u-boot.itb` | 上游 U-Boot v2026.10，bootstd/extlinux 引导 |
| `vendor` | | `assets/MiniLoaderAll.bin`（LDR） | `assets/uboot.img` | 厂商 2017.09 改造版（历史方案，保留） |

---

## 一、上游 U-Boot v2026.10（当前默认）

### 引导链

```
BootROM
  ↓ eMMC 0x40      idbloader.img   （binman: TPL(rkbin DDR) + SPL）
  ↓ eMMC 0x4000    u-boot.itb      （FIT: BL31 v1.53 + U-Boot 2026.10 + board DTB）
  ↓ bootstd 扫描所有 bootdev/分区 → extlinux bootmeth
  ↓ boot 分区 /extlinux/extlinux.conf
      kernel /Image   （软链 → vmlinuz-<ver>）
      initrd /uInitrd （软链 → uInitrd-<ver>）
      fdt    /dtb/rockchip/rk3588-aiot3588a.dtb
      append root=UUID=<rootfs UUID> rootfstype=btrfs …
  ↓
fnOS rootfs（按 UUID 挂载，**不写死分区号**）
```

### 关键点

1. **bootstd 全分区扫描补丁**（`assets/uboot-upstream/src/0001-bootflow-scan-all-partitions.patch`）：
   `cmd/bootflow.c` 默认 `BOOTFLOWIF_ONLY_BOOTABLE`，只扫带 legacy bootable 属性的分区；
   Rockchip `parameter.txt` 生成的 GPT 属性全是 0，导致只会扫分区 1（uboot）。
   补丁改为 `flags = 0`，扫描所有分区后才找到 p4 的 `/extlinux/extlinux.conf`。
2. **千兆时钟**：不需要在 u-boot 里改 CPLL。Linux 内核 dtsi 的 `assigned-clocks` 会把
   `pll_cpll` 设为 1.5GHz、`clk_gmac_125m` 设为 125MHz（实测 `125000000`）。
3. **镜像内 `Image`/`uInitrd` 是软链**：U-Boot 的 ext4 驱动会解析最长 8 层软链，
   因此与 fnOS 的「版本化内核 + 软链」布局、以及 `zt1-kernel-sync` 的自动切换机制完全兼容。
4. **LDR loader**：`uf` 的 loader 槽必须是 `LDR ` 容器。`scripts/make-ldr-loader.sh` 用
   boot_merger 的厂商 ini 流水线生成（见下），不能用 `boot_merger pack -1/-2/-3` 手工拼
   （会得到 `BOOT` 容器，`uf` 在 Download Boot 阶段失败）。

### LDR 生成原理

```
boot_merger 厂商 ini（NEWIDB=true）
  CODE471 = rk3588_ddr_lp4_2112MHz_lp5_2400MHz_v1.20.bin   （DDR 训练固件）
  CODE472 = rk3588_usbplug_v1.11.bin                       （MaskROM USB 通信）
  LOADER  = FlashData=DDR, FlashBoot=spl/u-boot-spl.bin    （上游 SPL）
        ↓
  MiniLoaderAll.bin（LDR 容器，FlashHead/RKNS 头由 boot_merger 自动生成）
        ↓  upgrade_tool uf 刷写
  eMMC 0x40 处的 flash 段 = 完整上游 idbloader
```

### 重新构建 u-boot（仅改 u-boot 时需要）

```bash
# 依赖：rkbin（DDR/usbplug/BL31）、Android prebuilts gcc 10.2（aarch64-none-linux-gnu-）
sudo bash scripts/build-uboot-upstream.sh
# 产物会覆盖 assets/uboot-upstream/ 并自动调用 make-ldr-loader.sh + 更新 MD5SUMS
```

脚本做的事：下载 u-boot v2026.10 tarball → 应用 `src/*.patch` → 用 `src/zerot1-rk3588_defconfig`
构建 → 取 `idbloader.img`/`u-boot.itb` → 生成 LDR。

### 刷写（一条命令）

```bash
sudo upgrade_tool_2.45 uf output/fnos-aiot3588a-v1.1-update-YYYYMMDD.img
# 或
sudo bash scripts/flash-image.sh output/fnos-aiot3588a-v1.1-update-YYYYMMDD.img
```

- 板子进 MaskROM 后执行；刷完 `upgrade_tool rd` 重启（脚本自动做）。
- 若报 `Download Boot Fail`：设备侧 DDR/MaskROM 会话异常，**断电 5 秒后重新进 MaskROM** 再试。

### 兜底（三步刷）

```bash
sudo upgrade_tool_2.45 db   assets/uboot-upstream/MiniLoaderAll.bin
sudo upgrade_tool_2.45 wl   0x40  assets/uboot-upstream/idbloader.img
sudo upgrade_tool_2.45 wl   0x4000 assets/uboot-upstream/u-boot.itb
sudo upgrade_tool_2.45 rd
```

或 `bash scripts/flash-uboot-upstream.sh`（封装了三步）。

---

## 二、厂商定制 u-boot（`UBOOT_MODE=vendor`，历史方案）

`assets/uboot.img` 是从 <https://github.com/friendlyarm/uboot-rockchip>
分支 `nanopi6-v2017.09` 打补丁后重编的版本。

### 为什么当年必须改

1. 厂商 u-boot 开了 `CONFIG_USING_KERNEL_DTB_V2`：用内核 dtb 替换自己的 dtb，
   并按内核 dtb 的 `assigned-clock-rates` 配时钟；
2. 但 u-boot 的 PLL 编号比 mainline 内核大 1
   （内核 `AUPLL=4 CPLL=5 GPLL=6 NPLL=7 PPLL=8`；u-boot `AUPLL=5 CPLL=6 GPLL=7 NPLL=8 PPLL=9`）；
   ⇒ 内核 dtb 里 "GPLL=1188MHz" 被 u-boot 当成 "CPLL=1188MHz"，CPLL 变成 1188MHz，
   GMAC 参考时钟只剩 99MHz ⇒ 千兆不通、百兆帧损坏；
3. 解法：在跳内核前（`arch_preboot_os()`）把 CPLL 切回 1500MHz，并直连引导
   （`load mmc 0:4 /Image /uInitrd /dtb/…` + `booti`）。

### 补丁内容（`patches/uboot/0001-zt1-uboot-cpll-ext4-directboot.patch`）

| 文件 | 改动 |
|---|---|
| `fs/ext4/Kconfig` | 补 `config FS_EXT4`（原文件为空，`CONFIG_FS_EXT4` 会被静默丢弃） |
| `drivers/clk/rockchip/clk_rk3588.c` | 新增 `zt1_set_cpll_1500()`：`rockchip_pll_set_rate(CPLL, 1500MHz)` + 写 `CLKSEL_CON(83)` |
| `arch/arm/mach-rockchip/board.c` | `board_late_init()` 写死 bootargs/bootcmd；`arch_preboot_os()` 调 CPLL 修正 |
| `configs/nanopi6_defconfig` | 追加 `CONFIG_FS_EXT4=y` |

### 重编厂商 u-boot（可选）

```bash
git clone https://github.com/friendlyarm/uboot-rockchip -b nanopi6-v2017.09
cd uboot-rockchip && git apply /path/to/fnos-zerot1/patches/uboot/0001-*.patch
./make.sh nanopi6        # 产物 uboot.img 放回 assets/uboot.img
```

产物：`assets/uboot.img` 4,194,304B，md5 `0113d1d47e126772abbce148bc8500f7`。
