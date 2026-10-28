# 构建文档 —— fnOS (fnNAS) for Shimeta AIOT-3588A (RK3588)

本文说明这个适配项目**用到了哪些文件**、**怎么把板级 DTS 与补丁链进内核构建**、以及完整的
构建 / 烧录 / 验证流程。目标是：换一台机器（或 GitHub Actions）照着本文就能复现出可烧录的
`update.img`。

---

## 1. 技术路线（为什么这么选）

飞牛 fnOS 官方只发布 x86 与 ARM64 的**成品镜像**（基于 Debian 12），没有提供板级源码。
因此本项目采用「**飞牛 rootfs + 友善 BSP 启动链**」的组合：

| 部件 | 采用方案 | 为什么 |
|---|---|---|
| 根文件系统 | fnOS 官方镜像 `nanopc-t6` 的 rootfs（Debian 12 + 飞牛服务） | 飞牛只发成品 rootfs，这是唯一来源；nanopc-t6 同为 RK3588 + RK806 单 PMIC，rootfs 里的电源/驱动假设最接近 |
| 内核 | **友善 `kernel-rockchip`（nanopi6-v6.1.y，6.1.141）** | 有完整的 RK3588 BSP 驱动（eDP/HDMI/音频/WiFi/BT/PCIe/看门狗），启动参数也是 RK 风格；mainline 6.18 缺 eDP/HDMI 控制器节点 |
| u-boot + loader | **友善 `uboot-rockchip`（nanopi6-v2017.09）** | 与友善内核配套、能引导 extlinux/FIT；打一个补丁让它扫描 GPT 全部分区（见 §4.2） |
| 打包工具 | Rockchip `afptool` / `rkImageMaker` / `resource_tool`（已入库 `assets/tools/`） | 生成 `update.img`，可直接 `upgrade_tool uf` 烧录 |

> 早期曾直接改 ophub 的成品牌镜像（mainline 6.18 内核），但 mainline 的 eDP/HDMI 驱动不完整、
> WiFi/BT 固件缺失、且无法方便地加看门狗驱动，所以最终改为「友善内核 + 飞牛 rootfs」重打包。

---

## 2. 项目结构

```
fnos-zerot1/
├── dts/
│   └── rk3588-aiot3588a.dts          # ★ 板级设备树（BSP 版，44KB，从 RK BSP 树搬来）
├── patches/
│   ├── uboot/
│   │   └── 0001-distro-bootcmd-scan-all-partitions.patch   # 让 distro_bootcmd 扫全部分区
│   ├── kernel/
│   │   ├── 0001-add-smdt-mcu-watchdog.patch                # Kconfig/Makefile/defconfig 三处
│   │   └── files/smdt_mcu_wdt.c      # 板载 STM8S00K3 MCU 看门狗驱动（i2c-6 0x62）
│   └── rootfs/                       # 按文件名顺序执行（10→96），可 --only NN,NN
│       ├── 10-fstab.sh               # 重写 /etc/fstab（对齐本项目分区：rootfs=btrfs、boot=FAT32）
│       ├── 15-network.sh             # NetworkManager / 主机名等网络默认值
│       ├── 20-firmware.sh            # WiFi(AP6256/brcmfmac43456) + 蓝牙(BCM4345C5) 固件与配置
│       ├── 22-watchdog-module.sh     # 板载 STM8 MCU 看门狗 ko（i2c-6 0x62）
│       ├── 25-audio.sh               # ES8388 codec 用户态配置
│       ├── 26-audio-mclk.sh          # GRF 0xfd58c318 I2S0_MCLK "to_io" 门控（无声根因，服务固化）
│       ├── 27-vendor-modules.sh      # 自编译 out-of-tree 模块：analogix_dp / brcmfmac 三件套
│       ├── 28-graphics-modules.sh    # 显示/音频/网卡模块开机加载（modules-load.d）
│       ├── 30-adb.sh                 # Linux adb/adbd（调试用）
│       ├── 32-serial-autologin.sh    # 调试串口自动登录
│       ├── 40-xfce.sh                # XFCE + lightdm（eDP 本地桌面，不预置普通用户）
│       ├── 41-wizard-firstboot.sh    # 恢复"出厂未初始化"：无普通用户/无 timestamp，保证 Web 向导可注册管理员
│       ├── 42-logclean.sh            # 日志刷屏治理：journald 限容、mask nut-*、libupnp13、eventlogger 延迟、enable ssh
│       ├── 45-desktop-apps.sh        # 桌面快捷方式（飞牛管理界面 / 终端等）
│       ├── 50-watchdog.sh            # systemd RuntimeWatchdogSec + watchdog 工具
│       ├── 60-desktop-apps.sh        # nm-applet / blueman / chromium / alsa-utils
│       ├── 70-audio-state.sh         # 喇叭功放使能（amixer spk switch）
│       ├── 80-docker-fix.sh          # docker.service ExecStop bug + 国内镜像源
│       ├── 90-rootfs-resize.sh       # 首启扩容策略（交给 Web 管理界面）
│       ├── 95-diag-console.sh        # 开机诊断输出到串口（临时）
│       └── 96-gfx-bringup.sh         # 强制拉起显示链路并落盘（临时诊断）
├── assets/                           # ★ 预编译复用资源（已入库，日常构建不需重新生成）
│   ├── MiniLoaderAll.bin             # 友善 SPL loader（含 DDR 训练固件，487,872B）
│   ├── uboot.img                     # 友善 u-boot（4MB FIT，含 distro_bootcmd 补丁）
│   ├── firmware/                     # brcmfmac43456-sdio.bin/.txt、BCM4345C0.hcd、regulatory.db
│   └── tools/                        # afptool / rkImageMaker / resource_tool / mkupdate.sh
├── scripts/
│   ├── lib-common.sh                 # 共用变量（WORK_DIR/IMAGE_DIR/ROOTFS）与 log/die
│   ├── lib-chroot.sh                 # qemu-aarch64-static + chroot 辅助
│   ├── build-all.sh                  # ★ 一键：rootfs → kernel → pack
│   ├── build-rootfs.sh               # 下载/复用 fnOS 底稿 → 提取 rootfs → 打补丁
│   ├── build-kernel.sh               # 编译友善内核 → 打补丁 → Image + dtb + modules_install
│   ├── build-uboot.sh                # （可选）重编 u-boot 并更新 assets/
│   ├── pack-image.sh                 # 组装 boot/rootfs/resource/misc → mkupdate.sh → update.img
│   └── check-upstream.py             # 查询 ophub/fnnas 是否有新底稿镜像
├── .github/workflows/build.yml       # GitHub Actions（手动触发 / tag）
├── docs/BUILD.md                     # 本文
├── work/                             # 构建中间产物（gitignore）
├── output/                           # update.img 产物（gitignore）
└── rootfs/                           # 提取出来的 fnOS 根文件系统（gitignore）
```

---

## 3. 外部文件与版本

| 用途 | 具体文件 | 版本 | 备注 |
|---|---|---|---|
| fnOS rootfs 来源 | `fnnas_rockchip_nanopc-t6_k6.18.18_2026.09.23.img.gz`<br>（[ophub/fnnas](https://github.com/ophub/fnnas) release `fnnas_rockchip_1253`） | 6.18.18（只取 rootfs） | 下载 1.75GB；只把 GPT 第 2 分区（rootfs，btrfs，offset = 1081344×512）挂出来 rsync |
| 内核源码 | [friendlyarm/kernel-rockchip](https://github.com/friendlyarm/kernel-rockchip) 分支 `nanopi6-v6.1.y` | 6.1.141 | 编译出 `Image` + `dtb` + `modules` |
| u-boot 源码 | [friendlyarm/uboot-rockchip](https://github.com/friendlyarm/uboot-rockchip) 分支 `nanopi6-v2017.09` | 2017.09 | 只在要改 u-boot 时才编；平时用 `assets/uboot.img` |
| u-boot 依赖 | [friendlyarm/rkbin](https://github.com/friendlyarm/rkbin) 分支 `nanopi6` | — | 提供 DDR 固件 / loader / resource_tool |
| 板级 DTS | `dts/rk3588-aiot3588a.dts` | BSP 6.1 版 | 来自我们 RK BSP 树（已针对本板验证过 eDP/串口/蓝牙/风扇/PCIe） |
| 打包工具 | `assets/tools/{afptool,rkImageMaker,resource_tool,mkupdate.sh,gen-package-file.sh}` | Rockchip 官方 | 已入库，无需下载 |

---

## 4. 构建流程详解

### 4.1 rootfs：`scripts/build-rootfs.sh`

1. 若 `work/fnnas_rockchip_*.img` 不存在 → 用 **8 线程分段下载** ophub 镜像（GitHub 对单连接限速，
   多段并行能到 10+ MB/s），再 `gunzip` 解压出 7GB 的 `.img`。
2. `losetup -o $((1081344*512))` 把 GPT 第 2 分区（rootfs，btrfs）挂到临时点，`rsync -aHAX --numeric-ids`
   拷到 `work/rootfs/`。
3. 按文件名顺序跑 `patches/rootfs/*.sh`（10→20→30→40→50）。
4. 环境变量 `SKIP_ROOTFS_EXTRACT=1` 可跳过提取，直接在已有的 `work/rootfs/` 上重打补丁（迭代快）。

### 4.2 u-boot 补丁（已预编译进 `assets/uboot.img`）

友善 u-boot 的 `distro_bootcmd` 原来只扫描**带 bootable 标志**的分区（`part list -bootable`），
我们的 GPT 里 boot 分区是第 4 个、没有 bootable 标志，导致 u-boot 永远找不到 `boot.extlinux`。
补丁改 `include/config_distro_bootcmd.h`：`setenv devplist 1` → `setenv devplist "1 2 3 4 5 6"`，
即**扫全部分区**。改完重新编译一次，把 `uboot.img` 放进 `assets/`（现有产物即为此版本）。

### 4.3 内核：`scripts/build-kernel.sh`

```bash
git clone -b nanopi6-v6.1.y https://github.com/friendlyarm/kernel-rockchip
cd kernel-rockchip
# 1) 应用补丁（Kconfig/Makefile/defconfig 三处）
git apply ../patches/kernel/0001-add-smdt-mcu-watchdog.patch
# 2) 拷驱动源码（大文件不进 patch）
cp ../patches/kernel/files/smdt_mcu_wdt.c drivers/watchdog/
# 3) 拷板级 dts 并注册
cp ../dts/rk3588-aiot3588a.dts arch/arm64/boot/dts/rockchip/
echo 'dtb-$(CONFIG_ARCH_ROCKCHIP) += rk3588-aiot3588a.dtb' >> arch/arm64/boot/dts/rockchip/Makefile
# 4) 配置 + 编译
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- nanopi6_linux_defconfig
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- Image modules
# 5) 产物
#    arch/arm64/boot/Image                               (35MB)
#    arch/arm64/boot/dts/rockchip/rk3588-aiot3588a.dtb   (292KB)
#    make INSTALL_MOD_PATH=../rootfs ARCH=arm64 modules_install
```

交叉工具链优先级：`$CROSS_COMPILE` → 仓库内 `prebuilts/.../aarch64-none-linux-gnu-` →
系统 `aarch64-linux-gnu-`（GitHub Actions 上 `apt install gcc-aarch64-linux-gnu`）。

> 注意 PATH：如果系统里 `bc` 被包装脚本劫持（比如某些 IDE 自带的 stub），编译会报
> `python3: can't open file ...kdev-bc-stub.py`。把 `/usr/bin` 放到 PATH 最前面，或装真 `bc`。

### 4.4 看门狗驱动

板载 MCU（STM8S00K3，i2c-6 地址 0x62）约 **603 秒**收不到喂狗就复位 SoC。驱动 `smdt_mcu_wdt.c`
把它实现成标准 `WATCHDOG_CORE` 设备（`/dev/watchdog`），寄存器协议：
`0x32←0x01`（arm）、`0x51←0x33`、`0x33←0xab`（kick）、`0x32←0x00`（disarm）。
用户态由 `50-watchdog.sh` 写 `systemd RuntimeWatchdogSec=30s` 让 systemd 自动喂狗。

### 4.5 打包：`scripts/pack-image.sh`

分区布局（512B 扇区，与 `parameter.txt` 一致）：

| 分区 | 起始 | 大小 | 文件系统 | 内容 |
|---|---|---|---|---|
| uboot | 0x00004000 | 4MB | raw | `assets/uboot.img` |
| misc | 0x00006000 | 4MB | raw | 全零（清 Android recovery 标记） |
| resource | 0x00008000 | 16MB | raw | `resource_tool` 打包的 `rk-kernel.dtb`（u-boot 从这里读 dtb） |
| boot | 0x00010000 | 64MB | **FAT32** | `Image` + `dtb/rockchip/*.dtb` + `extlinux/extlinux.conf` |
| rootfs | 0x00030000 | 按 rootfs 大小（64MB 对齐） | **btrfs** | fnOS rootfs（UUID 固定 `357e9eb7-…`） |
| userdata | rootfs 之后 | grow | — | 剩余空间 |

> **boot 为什么是 FAT32 而不是 ext4**：友善 u-boot 编译时只开了 `CONFIG_FS_FAT`，没开 `CONFIG_FS_EXT4`，
> ext4 分区会报 `Unrecognized filesystem type`。FAT32 是唯一稳的选择。
>
> **为什么要 resource 分区**：u-boot 的 `rockchip_read_resource_dtb()` 先从 resource 分区找
> `rk-kernel.dtb`（默认 `dtb_name` 是 `rk3588-nanopi6-rev0e.dtb`，找不到就回退 `rk-kernel.dtb`），
> 找不到就 `Failed to load DTB, ret=-19`，后续内核永远起不来。

`extlinux.conf`（u-boot 的 distro_bootcmd 扫到 FAT32 分区 4 后读它）：

```
label fnos
    kernel /Image
    fdt /dtb/rockchip/rk3588-aiot3588a.dtb
    append root=/dev/mmcblk2p5 rootfstype=btrfs rootwait rw \
           console=ttyS2,1500000n8 console=tty0 net.ifnames=0 max_loop=128 \
           earlycon=uart8250,mmio32,0xfeb50000
```

> 用 `root=/dev/mmcblk2p5`（分区 5）而不是 `root=UUID=...`：没有 initramfs 时内核 cmdline
> 不解析文件系统 UUID，会一直等 `Waiting for root device`。

---

## 5. 本地构建

依赖（Arch / Ubuntu 包名）：

```bash
# Arch
sudo pacman -S --needed base-devel aarch64-linux-gnu-gcc qemu-user-static \
    btrfs-progs dosfstools mtools rsync bc dtc git
# Ubuntu 24.04
sudo apt-get install -y build-essential gcc-aarch64-linux-gnu qemu-user-static \
    btrfs-progs dosfstools mtools rsync bc device-tree-compiler git
```

一键构建（需要 root：使用 losetup/mount/mkfs/chroot）：

```bash
sudo ./scripts/build-all.sh
# 产物：output/fnos-aiot3588a-update-YYYYMMDD.img
```

分阶段 / 加速：

```bash
# 只重打 rootfs 补丁（复用已提取的 rootfs）
sudo SKIP_ROOTFS_EXTRACT=1 ./scripts/build-rootfs.sh
# 只重编内核
sudo ./scripts/build-kernel.sh
# 只重新打包
sudo ./scripts/pack-image.sh
# 全部跳过 rootfs+内核，只打包（迭代 extlinux/分区布局时最常用）
sudo SKIP_ROOTFS=1 SKIP_KERNEL=1 ./scripts/build-all.sh
```

无 qemu-aarch64-static 时，`30-adb.sh` / `40-xfce.sh` 会自动跳过（系统仍能构建，只是没有 adb/XFCE）。

---

## 6. GitHub Actions

`.github/workflows/build.yml`：
- **手动触发**（workflow_dispatch）：可勾选「跳过 XFCE」做快速验证构建；
- **打 tag 触发**（`v*`）：自动构建并发布 Release（附件 = `update.img.gz` + `SHA256SUMS`）。

Actions 里会自动 `apt install qemu-user-static`（自带 binfmt 注册），因此 adb/XFCE 会在
arm64 chroot 里真正装上。产物 `update.img` 约 5.8GB，先 `gzip -1` 到 ~1.8GB 再上传。

---

## 7. 烧录

```bash
# 1) 板子进 Maskrom/Loader（USB 2207:350b）
#    正常系统里：adb reboot bootloader；或按住 REC 上电
# 2) 下载 loader（Maskrom 下必须先 db）
upgrade_tool db assets/MiniLoaderAll.bin
# 3) 烧写整包（约 5.8GB，USB2 需要 5~10 分钟）
upgrade_tool uf output/fnos-aiot3588a-update-YYYYMMDD.img
# 4) 复位
upgrade_tool rd
```

> **救砖**：`upgrade_tool db assets/MiniLoaderAll.bin` 能救回 Maskrom 设备；
> Android 镜像都保存在 `03-杂项/自建镜像/`，随时可刷回 Android 14。

---

## 8. 上电验证清单

- 串口（`/dev/ttyACM0`，1500000 8N1）应看到：
  `DDR ...` → `U-Boot SPL` → `U-Boot 2017.09` → `DTB: rk-kernel.dtb (292054)` →
  `Starting kernel ...` → Linux 启动日志 → `fnnas login:`
- 登录：`root` / `root`
- `ip a` 看 `eth0`（gmac1，DHCP）
- `dmesg | grep -iE 'fail|error'`
- WiFi：`nmcli` / `iw dev`（AP6256，需固件已装）
- 看门狗：`wdctl` / `cat /proc/uptime`（MCU 603s 不喂会复位，systemd 会持续喂）
- 桌面（如果装了 XFCE）：eDP 屏幕应出现 lightdm 登录/桌面

---

## 9. 已知限制

| 项 | 状态 | 说明 |
|---|---|---|
| eDP 显示 | ✅ 有输出 | BSP dts 里 `hdptxphy0` + `route-edp0` 正确；fnOS 默认 headless，装 XFCE 后才有桌面 |
| HDMI OUT | ⚠️ 待验证 | 板载 HDMI1（hdmi@fdea0000）已 enable，HDMI0 与 eDP 共用 PHY 保持 disabled |
| HDMI IN | ⚠️ 待验证 | hdmirx_ctrler 已配，需接信号源 |
| WiFi | ⚠️ 待验证 | brcmfmac43456 固件已装；需确认 `sdio_pwrseq`/regulator 时序 |
| 蓝牙 | ⚠️ 待验证 | BCM4345C0.hcd 已装；`hci_uart` 走 ttyS9 |
| 音频 ES8388 | ⚠️ 待验证 | BSP dts 里 I2S0 MCLK/编解码已配 |
| 5 路串口 | ✅ 预期可用 | BSP dts 已 enable uart1/4/6/7/8/9 |
| 风扇 | ✅ 预期可用 | pwm12 + thermal trip（BSP dts） |
| miniPCIe（4G/SSD） | ✅ 硬件就绪 | BSP dts 已开 pcie2x1l1；EC20 走 USB 通道 |
| SATA0 | ✅ 预期可用 | BSP dts 已开 sata0 |
| 看门狗 | ✅ 驱动已编译 | smdt_mcu_wdt + systemd RuntimeWatchdogSec |
| adb | ⚠️ 构建时安装 | Debian arm64 的 android-tools-adb |
| XFCE | ⚠️ 构建时安装 | lightdm autologin root |

---

## 10. 常见问题

| 症状 | 原因 | 解决 |
|---|---|---|
| 上电完全无串口输出 | loader 没写进 eMMC LBA 0x40，BootROM 直接进 Maskrom | `upgrade_tool db assets/MiniLoaderAll.bin` 后再 `uf` |
| u-boot 提示 `Failed to load DTB, ret=-19` | 缺 resource 分区 / resource.img | 按 §4.5 加 resource 分区并放 `rk-kernel.dtb` |
| u-boot 提示 `Unrecognized filesystem type` | boot 分区是 ext4，u-boot 没编 ext4 驱动 | boot 分区必须 FAT32 |
| `Starting kernel ...` 后无输出 | console 参数缺失或 rootfs 挂载失败 | 确认 extlinux 的 `append` 有 `console=ttyS2,1500000n8`；`root=/dev/mmcblk2p5` |
| 内核停在 `Freeing initrd memory` 后 | 板上没插 PCIe 设备时 pcie 驱动 async probe 卡死 | BSP dts 里 pcie2x1l1 仅在需要时 enable；或加 `pcie` 超时 |
| `apt update` 在 chroot 里失败 | qemu/binfmt 没注册 | `apt install qemu-user-static`（Ubuntu 自动注册），Arch 装 `qemu-user-static-binfmt` |
| 构建最后 `mkupdate 失败` | `assets/tools/` 可执行权限丢失 | `chmod +x assets/tools/*`（git 已记录 exec 位） |

---

## 11. 参考

- ophub/fnnas（fnOS ARM 镜像打包器）：https://github.com/ophub/fnnas
- zhangyada/fnos-elf3588（ELF3588 适配，本项目的思路模板）：https://github.com/zhangyada/fnos-elf3588
- 友善 NanoPC-T6 wiki：https://wiki.friendlyelec.com/wiki/index.php/NanoPC-T6/zh
- Rockchip SD-Fuse RK3588：https://github.com/friendlyarm/sd-fuse_rk3588

---

## 附：eDP 专用的 analogix_dp.ko

fnOS 官方内核（6.18.18-trim）在本板的 eDP 上需要三处修改，已整理为：

- 补丁：`patches/kernel/6.18.18/0001-analogix-dp-rockchip-edp-bringup.patch`
- 源码：`kernel-modules/analogix-dp-6.18.18/`（core.c/core.h/reg.c/reg.h/Makefile）
- 构建：`scripts/build-analogix-dp.sh`（需先准备内核树，见上文）

三处修改与原因：

1. **eDP 必须由 TX 用寄存器生成时序**（`VIDEO_TIMING_FROM_REGISTER`）
   eDP 面板没有 EDID，mainline 默认走 `VIDEO_TIMING_FROM_CAPTURE`，VOP 未就绪时拿不到有效时序。
2. **首次 DPCD 读回 `max_link_rate=0` 时重试并回退**（不用写死速率）
   部分面板/屏线首次 AUX 读不稳定；重读成功则按其值训练，仍失败才退到 1.62G。
3. **开机首次 modeset 后 400ms 补一次完整 modeset**
   现象：开机第一次使能后屏幕只有背光，手动 `blank 1→0` 或第二次 modeset 就正常。
   原因是厂商 VOP2（闭源补丁）首次编程 eDP 输出未真正生效；补一次 `drm_atomic_helper_suspend/resume`
   后立即出图，不需要任何启动脚本或人工操作。

构建后把 `analogix_dp.stripped.ko` 放到：

```
work/rootfs/lib/modules/6.18.18-trim/kernel/drivers/gpu/drm/bridge/analogix/analogix_dp.ko
work/boot-fix-2214/uInitrd   # initramfs 里同一路径（启动早期加载的是它，必须一起换）
```

注意：fnOS 启动早期从 **uInitrd 里的模块**加载 analogix_dp，rootfs 里的同名模块不会生效，两处都要替换。
