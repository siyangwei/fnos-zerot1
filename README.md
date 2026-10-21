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

默认登录：`root` / `root`。串口调试：`/dev/ttyACM0`，1500000 8N1（USB 双串口模块）。

### 自己构建

```bash
# 依赖：base-devel gcc-aarch64-linux-gnu qemu-user-static btrfs-progs dosfstools mtools bc
sudo ./scripts/build-all.sh
# 产物：output/fnos-aiot3588a-update-YYYYMMDD.img
```

详细步骤（内核命令、分区布局、为什么要 resource 分区、为什么 boot 是 FAT32……）见
**[docs/BUILD.md](docs/BUILD.md)**。

### GitHub Actions

Actions → 工作流 `build-fnos-image` → Run workflow（可勾选「跳过 XFCE」做快速验证构建）；
打 tag（`v*`）会自动构建并发布 Release（附件含 `update.img.gz` 与 `SHA256SUMS`）。

---

## 目录结构

```
dts/         板级设备树（BSP 版，来自已验证的 RK BSP 树）
patches/     u-boot / 内核 / rootfs 补丁（全部可用脚本复现）
assets/      预编译复用资源：loader、uboot.img、WiFi/BT 固件、Rockchip 打包工具
scripts/     构建脚本（build-all / build-rootfs / build-kernel / pack-image）
docs/        BUILD.md 构建文档
```

---

## 已适配的功能

| 功能 | 状态 |
|---|---|
| eDP 显示（1920x1080） | ✅ 已验证（fnOS 默认 headless，装 XFCE 后出桌面） |
| 5 路串口（ttyS1/4/6/7/8）+ 蓝牙 ttyS9 | ✅ 预期可用（BSP dts 已 enable） |
| ES8388 音频（耳机/喇叭） | ⚠️ 待实物验证 |
| WiFi AP6256 / 蓝牙 AP6256 | ⚠️ 固件已装，待实物验证 |
| 千兆以太网 | ⚠️ 待实物验证 |
| 风扇（pwm12 + thermal trip） | ✅ 预期可用 |
| 板载 MCU 看门狗 | ✅ 驱动已编译（`smdt_mcu_wdt`）+ systemd RuntimeWatchdogSec |
| miniPCIe（4G EC20 / 2230 SSD） | ✅ 硬件通路就绪（EC20 走 USB，SSD 走 pcie2x1l1） |
| SATA0 | ✅ 预期可用 |
| HDMI OUT / HDMI IN | ⚠️ 待实物验证 |
| XFCE 桌面 + lightdm 自动登录 root | ✅ 构建时安装（`patches/rootfs/40-xfce.sh`） |
| Linux adb / adbd | ✅ 构建时安装（`patches/rootfs/30-adb.sh`） |

---

## 许可

本项目只包含板级适配文件（dts / patch / 构建脚本）。
fnOS rootfs 版权归[飞牛](https://www.fnnas.com/)所有；内核与 u-boot 来自
[friendlyarm](https://github.com/friendlyarm)（GPL-2.0）。
