# fnos-zerot1

**fnOS（飞牛 NAS 系统 / fnNAS）for 视美泰 AIOT-3588A（RK3588）**

把 [fnOS](https://www.fnnas.com/) 移植到视美泰 AIOT-3588A 核心板（内部代号 zeroT1）。

**同一路线参考**：[zhangyada/fnos-elf3588](https://github.com/zhangyada/fnos-elf3588) ·
**镜像打包框架**：[ophub/fnnas](https://github.com/ophub/fnnas)

---

## 技术路线

```
fnOS 官方 rootfs（Debian 12 + 飞牛服务，来自 ophub nanopc-t6 镜像）
        +
友善 u-boot（nanopi6-v2017.09，含 distro_bootcmd 扫描全部分区补丁）
        +
友善 Linux 6.1.141 内核（BSP 驱动：eDP/HDMI/ES8388/WiFi/BT/PCIe/SATA/看门狗）
        +
本板设备树 dts/rk3588-aiot3588a.dts
        ↓
update.img（Rockchip 打包格式，upgrade_tool uf 烧录）
```

> 早期方案是「ophub 镜像 + mainline 6.18 DTB 替换」；mainline 的 eDP/HDMI 驱动不完整、
> WiFi/BT 固件缺失、无法方便地加看门狗驱动，因此改为「友善内核 + 飞牛 rootfs」重新打包。

---

## 板卡

| 项目 | 规格 |
|---|---|
| SoC | Rockchip RK3588（4×A76 + 4×A55，Mali-G610，6 TOPS NPU） |
| 内存 | LPDDR4x |
| 存储 | eMMC（`mmcblk2`）、板载 SATA0、miniPCIe（2230 NVMe SSD / 4G 模块） |
| 显示 | **eDP** 1920x1080@139MHz（PWM 背光） + HDMI1 输出 + HDMI IN |
| 音频 | ES8388（耳机 + 扬声器） |
| 网络 | 千兆以太网（GMAC1）+ AP6256 WiFi/BT |
| 串口 | 5 路：TTL-1/2、RS232-4/5、RS485-3（+ 调试串口 uart2） |
| 其他 | RTC(hym8563)、USB-C(OTG+PD)、3×USB Host、风扇(PWM)、ADC 按键、板载 MCU 看门狗 |

---

## 快速开始

### 用 Release 镜像（推荐）

```bash
# 下载 fnos-aiot3588a-update-*.img.gz → 解压
gunzip fnos-aiot3588a-update-*.img.gz

# 板子进 Maskrom/Loader（USB 2207:350b）
upgrade_tool db assets/MiniLoaderAll.bin     # Maskrom 下必须先下载 loader
upgrade_tool uf fnos-aiot3588a-update-*.img  # 约 5.8GB，USB2 需要 5~10 分钟
upgrade_tool rd
```

默认登录：`root` / `weisiyang`（由仓库根 `config.env` 的 `ROOT_PASSWORD` 决定）。串口调试：`/dev/ttyACM0`，1500000 8N1（USB 双串口模块）。

开机后设备会自动连接 `config.env` 里配置的 WiFi（`zt1-wifi-connect.service`），
连上即可 `ssh root@<设备IP>`。WiFi 名称/密码、SSH、主机名、构建开关都在
**[config.env](config.env)** 里改，说明见 **[docs/CONFIG.md](docs/CONFIG.md)**。

### 自己构建

```bash
# 依赖：base-devel gcc-aarch64-linux-gnu qemu-user-static btrfs-progs dosfstools mtools bc
sudo ./scripts/build-all.sh
# 产物：output/fnos-aiot3588a-update-YYYYMMDD.img
```

只改 `config.env`（WiFi/密码/开关）想快速重打包（复用缓存的 rootfs 与内核，约 2~3 分钟）：

```bash
sudo env SKIP_ROOTFS=1 SKIP_KERNEL=1 \
     FNOS_BOOT=$PWD/work/boot-fix-2214 IMAGE_DIR=$PWD/work/images \
     ROOTFS=$PWD/work/rootfs-official bash scripts/build-all.sh
```

详细步骤（内核命令、分区布局、为什么要 resource 分区、为什么 boot 是 FAT32……）见
**[docs/BUILD.md](docs/BUILD.md)**。

### GitHub Actions

Actions → 工作流 `build-fnos-image` → Run workflow（可勾选「跳过 XFCE」做快速验证构建）；
打 tag（`v*`）会自动构建并发布 Release（附件含 `update.img.gz` 与 `SHA256SUMS`）。

---

## 目录结构

```
dts/                        板级设备树（BSP 版，来自已验证的 RK BSP 树）
patches/
├── kernel/<版本>/          内核补丁，按内核版本分目录（当前 6.1.141/）
│   ├── NNNN-*.patch        每个补丁只做一件事，可单独增删
│   └── files/              新增文件（如驱动源码，不塞进 .patch）
├── uboot/<版本>/           u-boot 补丁（当前 2017.09/）
└── rootfs/NN-*.sh          rootfs 补丁脚本，按编号顺序执行，可 --only 单跑
assets/                     预编译复用资源：loader、uboot.img、WiFi/BT 固件、打包工具
scripts/
├── patch-kernel.sh         按内核版本应用 patches/kernel/<ver>/（可单独跑）
├── patch-uboot.sh          按 u-boot 版本应用 patches/uboot/<ver>/
├── patch-rootfs.sh         按序执行 patches/rootfs/NN-*.sh（可 --only/--list）
├── build-kernel.sh         内核配置+编译（调用 patch-kernel.sh）
├── build-uboot.sh          u-boot 编译（调用 patch-uboot.sh）
├── build-rootfs.sh         rootfs 准备（调用 patch-rootfs.sh）
├── pack-image.sh           分区镜像 + update.img 打包
└── build-all.sh            串联全流程（可 SKIP_* 跳过单步）
docs/                       BUILD.md 构建文档、CONFIG.md 配置说明、AUDIO.md
config.env                  ⭐ 构建/首启配置：WiFi、root 密码、SSH、主机名、构建开关
```

**补丁解耦约定**（便于后续换内核 / 单独改功能）：

- 内核补丁按 `<MAJOR.MINOR.PATCH>` 分目录，换版本时新建目录，老补丁原样保留；
  `patch-kernel.sh` 用 `make kernelversion` 自动选目录，找不到就跳过（不报错）。
- 每个 `.patch` 只做一件事（如"加看门狗驱动"、"加蓝牙 serdev"），可单独
  `--only 0002` 应用。
- rootfs 补丁是独立脚本，`--only 70,80` 只跑指定编号；`--list` 列出全部。
- 板级 DTS 是**新增文件**（`dts/rk3588-aiot3588a.dts`），不进 patch，改 DTS
  不用重生成补丁。

---

## 已适配的功能

| 功能 | 状态 |
|---|---|
| eDP 显示（1920x1080） | ✅ 已验证（fnOS 默认 headless，装 XFCE 后出桌面） |
| 5 路串口（ttyS1/4/6/7/8）+ 蓝牙 ttyS9 | ✅ 已验证（`/dev/ttyS*` 齐全） |
| ES8388 音频（耳机/喇叭） | ✅ 已验证（`70-audio-state.sh` 打开 spk switch 后出声） |
| WiFi AP6256 | ✅ 已验证（固件 + NetworkManager 连接成功） |
| 蓝牙 AP6256 | ✅ 改用 serdev（`&uart9/bluetooth`，hci_bcm 驱动） |
| 千兆以太网 | ⚠️ 待实物验证（gmac 时钟告警待查） |
| 风扇（pwm12 + thermal trip） | ✅ 预期可用 |
| 板载 MCU 看门狗 | ✅ 驱动已编译（`smdt_mcu_wdt`）+ systemd RuntimeWatchdogSec |
| miniPCIe（4G EC20 / 2230 SSD） | ✅ 硬件通路就绪（EC20 走 USB，SSD 走 pcie2x1l1） |
| SATA0 | ✅ 预期可用 |
| HDMI OUT / HDMI IN | ⚠️ 待实物验证 |
| XFCE 桌面 + lightdm 自动登录 root | ✅ 已验证（`patches/rootfs/40-xfce.sh`） |
| 桌面网络/蓝牙托盘图标 | ✅ `60-desktop-apps.sh`（nm-applet + blueman） |
| Chromium + 飞牛管理界面快捷方式 | ✅ `60-desktop-apps.sh` |
| Docker（含国内镜像源） | ✅ `80-docker-fix.sh`（修 ExecStop bug + registry-mirrors） |
| rootfs 首次启动扩容到 16GiB | ✅ `90-rootfs-resize.sh` + parameter.txt 不划 userdata |
| Linux adb 客户端 | ✅ 构建时安装；⚠️ adbd 在 Debian bookworm 无现成包，暂用串口/SSH 调试 |

---

## 许可

本项目只包含板级适配文件（dts / patch / 构建脚本）。
fnOS rootfs 版权归[飞牛](https://www.fnnas.com/)所有；内核与 u-boot 来自
[friendlyarm](https://github.com/friendlyarm)（GPL-2.0）。
