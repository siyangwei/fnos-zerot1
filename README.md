# fnos-zerot1

**fnOS（飞牛 NAS / fnNAS）for 视美泰 AIOT-3588A（RK3588 核心板，代号 zeroT1）**

把 [fnOS](https://www.fnnas.com/) 移植到视美泰 AIOT-3588A 板子上，产出 **Rockchip 格式的全量 `update.img`**，
一条命令烧录：

```bash
sudo upgrade_tool_2.45 uf fnos-aiot3588a-update-YYYYMMDD.img
```

除烧录外全部流程（拉取底稿、准备内核与 initramfs、编译设备树、组装各分区、打包）都可由
GitHub Actions 一键完成，产物见 [Releases](../../releases)。

参考：同路线项目 [zhangyada/fnos-elf3588](https://github.com/zhangyada/fnos-elf3588) ·
镜像打包框架 [ophub/fnnas](https://github.com/ophub/fnnas)

---

## 技术路线

```
fnOS 官方 rootfs（Debian 12 + 飞牛服务，取自 ophub/fnnas 的 nanopc-t6 底稿镜像）
        +
fnOS 官方内核 6.18.18-trim（vmlinuz + uInitrd + modules，含 trimafs/zfs/rk_vcodec 等私有驱动）
        +
本仓库的板级设备树（mainline 6.18 dts + 厂商 BSP 节点移植，含 eDP/HDMI/WiFi/BT/PCIe/MPP）
        +
定制 u-boot（预编译 assets/uboot.img：修千兆网口 CPLL、补 FS_EXT4、直连引导）
        ↓
output/fnos-aiot3588a-update-<日期>.img   （RKFW，upgrade_tool uf 烧录）
```

**为什么用 fnOS 官方内核而不是主线/友善内核**：fnOS 管理界面（trim 系列服务）依赖
`trimafs` 私有文件系统、ZFS、`rk_vcodec` 等只存在于官方内核的驱动，换内核会导致 Web 管理界面
无法启动；因此内核保持官方预编译版本，板级支持全部通过 **设备树 + initramfs 里的模块替换 +
用户态模块** 实现。

**为什么需要定制 u-boot**：官方/友善 u-boot 用内核 dtb 设时钟时 PLL 编号与内核差 1，
会把 CPLL 写成 1188MHz，导致 GMAC 参考时钟 99MHz（千兆网口完全不通）。
定制版在跳内核前把 CPLL 设回 1500MHz，并改为直连引导（`/Image` + `/uInitrd` + 板级 dtb）。

---

## 功能状态

### 已验证可用

| 类别 | 状态 |
|---|---|
| 启动 / 系统 | eMMC GPT 启动，fnOS 完整服务（trim Web 管理、文件服务、Docker），XFCE 桌面 + lightdm |
| 显示 | **eDP 1920x1080**（dclk 132MHz）+ **HDMI1 自动 EDID**（实测 2560x1440@60）；双屏同时输出、主副屏自动切换（HDMI 插入 → HDMI 主屏，eDP 放其下方，均原生分辨率） |
| 音频 | ES8388：喇叭 + 耳机，插入耳机自动切输出（SARADC 检测）；首启即有声（MCLK 门控已修） |
| 有线网络 | 千兆，实测 950 / 1015 Mbps 双向、md5 一致 |
| 无线 | BCM43455（AP6256）2.4G/5G，5G 支持 DFS 信道（ch60/5300MHz）；蓝牙 BCM4345C5（可搜索/连接） |
| USB | **adb over USB3.0 SuperSpeed**（bcdUSB 0x0320、5Gbps 链路）；Type-C 角色切换 `zt1-usb-role status\|device\|host` |
| 存储 | btrfs rootfs，首启自动扩到整盘；boot 分区 ext4 |
| 视频编解码 | 硬解：H.264（含 4K）、HEVC（含 4K）、VP9、VP8、MPEG-1/2/4、H.263、MJPEG；硬编：H.264、MJPEG |
| 电源 / 杂项 | 秒级重启（CRU 复位 + RK806 RST_FUN 修复）、风扇 PWM、板载 MCU 看门狗、串口 console（ttyS2@1500000） |

### 已知问题

- **AV1 硬解不可用**：fnOS 预编译内核的 av1d IOMMU 适配有缺陷（`iommu_map_nosync` 对同一 iova 重复
  调用 `av1_iommu_map`，第二次返回 `-EADDRINUSE`，PTE 不回滚），启用 DT 节点后设备能注册但解码失败；
  纯设备树/CMA 层面无法修复。AV1 可走 `libdav1d` 软解（ffmpeg 默认）。
- **HEVC 硬编**打开失败（`-22`），H.264/MJPEG 硬编正常。
- HDMI 的 2K240 等高刷模式需要 FRL，本内核/固件未启用，会被拒绝；4K60 及以下（TMDS 范围）正常。
- HDMI1 必须接在 VOP **VP2** 上（设备树已固定），否则与 eDP 同时启用时黑屏。
- adb 传输速度约 18 MB/s，受厂商 adbd（android-tools 4.2.2）协议限制，链路本身 5Gbps。
- Type-C 的 host 模式数据面未做完整验证（默认 `USB_ROLE=host`，插 PC 自动切 device 跑 adb）。

---

## 仓库结构

```
assets/                 预编译产物（u-boot、定制内核模块、打包工具）
  uboot.img               定制 u-boot（4MB）
  modules/6.18.18-trim/   analogix_dp.ko / brcmfmac 三件套 / smdt_mcu_wdt.ko
  adbd-ss-shim/           libadbd_ss_shim.so（adb SuperSpeed 描述符 shim）
  tools/                  mkupdate.sh / resource_tool 等 Rockchip 打包工具
dts/mainline-6.18/      板级设备树（rk3588-aiot3588a.dts + usbdev 变体）
kernel-modules/         out-of-tree 模块源码（analogix-dp、smdt-mcu-wdt）
patches/rootfs/         构建时对 rootfs 做的全部改动（按文件名顺序执行）
patches/uboot/          定制 u-boot 的源码补丁（记录如何从友善 u-boot 生成 assets/uboot.img）
scripts/                构建脚本（见下）
docs/                   构建/音频/U-Boot/VPU 说明
.github/workflows/      GitHub Actions 自动构建
config.env.example      构建配置模板（复制为 config.env 后填写；含密码，不入库）
```

构建脚本：

| 脚本 | 作用 |
|---|---|
| `scripts/build-all.sh` | 一键：rootfs → 内核/initramfs → 设备树 → 打包（支持 `SKIP_*` 单步加速） |
| `scripts/build-rootfs.sh` | 从 ophub 底稿镜像提取 rootfs，逐条执行 `patches/rootfs/*.sh` |
| `scripts/prepare-boot.sh` | 下载 fnOS 内核包，生成 `Image`/`uInitrd`（替换 analogix_dp.ko） |
| `scripts/build-dts.sh` | 下载内核源码中必要的 dts 头文件，cpp + dtc 编译板级 dtb |
| `scripts/normalize-ownership.sh` | 修正 rootfs 属主（否则 postgres/ssh 会在新镜像里坏掉） |
| `scripts/pack-image.sh` | 组装 boot/rootfs/resource 分区并打包 `update.img` |
| `scripts/uinitrd-tool.py` | 解析/替换/重打包 initramfs（legacy uImage + zstd） |

---

## 使用

### 1. 烧录

```bash
sudo upgrade_tool_2.45 uf fnos-aiot3588a-update-YYYYMMDD.img
```

`uf` 会自带 loader、写入全部分区并自动复位。板子进 MaskROM 后执行即可；若 `uf` 失败，
先 `upgrade_tool_2.45 db assets/MiniLoaderAll.bin` 再重试。更详细的救砖流程见
[docs/BUILD.md](docs/BUILD.md)。

### 2. 首次开机

- 网线/WiFi 任一能上网即可；**出厂镜像没有任何普通用户**，浏览器访问 `http://<板子IP>` 走 fnOS
  初始化向导弹出「开始使用 fnOS」，注册的管理员就是后续登录账号。
- 设备名初始为 `fnnas`，由向导设置。
- 默认调试通道：USB-C 接 PC 出现 `2207:0006`（识别为 `zeroT1 fnOS`），`adb shell` 直连；
  串口 `ttyS2` 波特率 1500000（8N1，需 `stty raw` 才不吞字符）。

### 3. 构建（本地）

依赖：`bash`、`rsync`、`zstd`、`cpio`、`dtc`、`cpp`、`mkfs.ext4`、`mkfs.btrfs`、`fdisk`、
`qemu-user-static`（可选）、root 权限（loop 挂载）、约 30GB 磁盘、8GB+ 内存。

```bash
cp config.env.example config.env   # 按需填写 WiFi / root 密码
sudo ./scripts/build-all.sh
```

首次构建会自动下载（约 2.1GB）：

| 内容 | 来源 |
|---|---|
| 底稿镜像 `fnnas_rockchip_1253` | https://github.com/ophub/fnnas/releases |
| fnOS 内核包 `6.18.18-rockchip.tar.gz` | https://github.com/ophub/fnnas/releases/tag/kernel_fnnas |
| 内核源码（只要 dts 头文件） | https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.18.18.tar.xz |

迭代常用：

```bash
# 只改了 rootfs 补丁
sudo ./scripts/build-all.sh                    # SKIP_BOOT=1 SKIP_DTS=1 可复用已有内核/dtb
# 只改了设备树
sudo env SKIP_ROOTFS=1 SKIP_BOOT=1 ./scripts/build-all.sh
# 只重打包
sudo env SKIP_ROOTFS=1 SKIP_BOOT=1 SKIP_DTS=1 ./scripts/build-all.sh
```

构建产物在 `output/fnos-aiot3588a-update-<日期>.img`，脚本会打印 sha256。

### 4. 构建（GitHub Actions）

`.github/workflows/build.yml`：

- 手动触发（Actions → Build image → Run workflow），或推送 `v*` 标签自动创建 Release；
- 全程在 Ubuntu runner 上完成：下载底稿/内核/源码 → 构建 → 上传 `update.img` 为 artifact（tag 时发 Release）；
- WiFi 密码、root 密码通过 **Actions Secrets**（`WIFI_SSID` / `WIFI_PASSWORD` /
  `WIFI_FALLBACK_SSID` / `WIFI_FALLBACK_PASSWORD` / `ROOT_PASSWORD`）注入，仓库里不存明文。

---

## 分区布局

| 分区 | 起始(扇区) | 大小 | 文件系统 | 内容 |
|---|---|---|---|---|
| uboot | 0x4000 | 4MB | — | 定制 u-boot |
| misc | 0x6000 | 4MB | — | 全零 |
| resource | 0x8000 | 16MB | — | `rk-kernel.dtb` |
| boot | 0x10000 | 64MB | **ext4** | `Image` + `uInitrd` + `dtb/rockchip/*.dtb` |
| rootfs | 0x30000 | 按内容 +64MB 对齐 | btrfs | fnOS rootfs |
| userdata | 紧随 rootfs | grow | btrfs | 数据分区 |

`parameter.txt` 必须含 `TYPE: GPT`，否则 `upgrade_tool uf` 会假成功。

---

## 文档

- [docs/BUILD.md](docs/BUILD.md) —— 构建细节、分区/引导链、u-boot 重编、救砖
- [docs/AUDIO.md](docs/AUDIO.md) —— ES8388 音频拓扑与 RK3588 MCLK 门控坑
- [docs/UBOOT.md](docs/UBOOT.md) —— 定制 u-boot 的改动与生效验证
- [docs/VPU.md](docs/VPU.md) —— 视频编解码（MPP/RGA）现状

## 致谢

- [ophub/fnnas](https://github.com/ophub/fnnas)：底稿镜像与官方内核打包
- [friendlyarm](https://github.com/friendlyarm)：u-boot 基线
- [zhangyada/fnos-elf3588](https://github.com/zhangyada/fnos-elf3588)：同路线参考
