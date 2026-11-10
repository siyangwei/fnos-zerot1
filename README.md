# fnOS for 视美泰 AIOT-3588A（zeroT1）

把 [fnOS](https://www.fnnas.com/)（飞牛 NAS）移植到 **视美泰 AIOT-3588A（RK3588）** 板子，
产出 Rockchip 格式全量 `update.img`，**一条命令烧录**：

```bash
sudo upgrade_tool_2.45 uf fnos-aiot3588a-v1.1-update-YYYYMMDD.img
```

系统 = fnOS 官方 rootfs + 官方内核 `6.18.18-trim` + 本仓库板级设备树 + 上游 U-Boot v2026.10，
功能对齐官方板：eDP/HDMI 双屏、ES8388 音频、千兆、WiFi 5G（含 DFS）、adb USB3、NPU、视频硬解。

> **⚠️ 硬件版本：仅适配 AIOT-3588A *V1.1*。**
> 该板官方有 V1.1（2023 固件）与 V1.3（2024 固件）两个版本，本项目的 dtb / 供电 / 显示 / USB 配置
> 均以 V1.1 实板为准，V1.3 **未适配未验证**，请勿直接刷。镜像名、Release 均带 `v1.1`。

下载：见 [Releases](https://github.com/siyangwei/fnos-zerot1/releases)（`.img.zst` 压缩包 + 校验文件）。

---

## 功能速览

| 模块 | 状态 |
|---|---|
| 启动 | eMMC GPT 启动，fnOS 全套服务 + XFCE 桌面；Web 更新可跟进（自动重编板级模块并切内核） |
| 显示 | eDP 1920x1080 + HDMI1 自动 EDID（实测 2560x1440@60），双屏同显/主副屏自动切换 |
| 音频 | ES8388 喇叭 + 耳机自动切换，首启即有声 |
| 网络 | 千兆（实测 950/1015 Mbps）；WiFi BCM43455 2.4G/5G + **DFS**（默认 US 域，ch52-64/100-144 可用）；蓝牙 |
| USB | 唯一 Type-C（OTG）自动识别 device/host（插 U 盘自动挂载）；**adb over USB3.0 SuperSpeed**；2× USB-A |
| 存储 | boot 512MB ext4（版本化内核 + 软链）；rootfs btrfs 固定 5.6GB，剩余空间在 Web 建存储池；SD 卡 SDR104 198MHz |
| 加速器 | NPU `rknpu 0.9.8`（实测 face_det 640×640 单帧 145ms）、Mali-G610、RGA、VPU（H.264/HEVC/VP9 等硬解，H.264/MJPEG 硬编） |
| 其它 | 秒级重启、风扇 PWM、MCU 看门狗、串口 console |

## 烧录

1. 板子断电，按住 MaskROM 键（或短接）后上电，`lsusb` 可见 `2207:350b`；
2. 烧录（`uf` 会写入完整引导链，镜像内置 LDR loader）：

   ```bash
   # 下载 Release 里的 .img.zst 后：
   sha256sum -c fnos-aiot3588a-v1.1-update-*.img.zst.sha256
   unzstd fnos-aiot3588a-v1.1-update-*.img.zst
   sha256sum -c SHA256SUMS             # 校验镜像本体
   sudo upgrade_tool_2.45 uf fnos-aiot3588a-v1.1-update-*.img
   ```

3. `sudo upgrade_tool_2.45 rd` 重启。若卡在 `Download Boot Fail`：**断电 5 秒重进 MaskROM** 再试。

## 首次开机

- 网线或 WiFi 联网后，浏览器打开 `http://<板子IP>` 走 fnOS 初始化向导（出厂**无任何普通用户**，向导里创建的管理员就是登录账号）。
- 默认 root 密码 `root`（串口/SSH/控制台均可用，建议首登后 `passwd root`）。
- 调试通道：USB-C 接 PC 出现 `2207:0006 zeroT1 fnOS`，`adb shell` 直连；串口 `ttyS2 @1500000`（8N1，需 `stty raw`）。

## 构建

**本地**（约 30GB 磁盘、root 权限）：

```bash
cp config.env.example config.env    # 填 WiFi / root 密码（可留空）
sudo ./scripts/build-all.sh         # 默认上游 U-Boot；UBOOT_MODE=vendor 可回厂商 u-boot
```

**GitHub Actions**：Actions → *Build image* → Run workflow；推 `v*` 标签会自动发 Release。
产物为 zstd 压缩的 `.img.zst` + 校验文件，Secrets（`WIFI_SSID`/`WIFI_PASSWORD`/`ROOT_PASSWORD` 等）注入配置。

## 已知限制

- **AV1 硬解不可用（软解正常）**：fnOS 官方内核的 av1d IOMMU 适配缺陷（`-EADDRINUSE`），DT 保持 disabled（与官方默认一致）；`libdav1d` 软解可用。
- HEVC 硬编打开失败（`-22`）；H.264/MJPEG 硬编正常。
- HDMI 2K240 等高刷需 FRL，未启用；4K60 及以下正常。
- adb 传输约 18MB/s（受厂商 adbd 4.2.2 协议限制，链路本身 5Gbps）。
- 5G 热点在 DFS 信道时依赖 `WIFI_COUNTRY="US"`（默认）；改 `CN` 会搜不到，最省事是把路由器 5G 固定到 36-48 / 149-165。

## 文档

- **[docs/GUIDE.md](docs/GUIDE.md) —— 详细说明（技术路线 / 引导链 / 功能细节 / 使用 / 分区 / 排错）**
- [docs/BUILD.md](docs/BUILD.md) —— 构建细节与救砖
- [docs/UBOOT.md](docs/UBOOT.md) —— 上游 U-Boot 适配（LDR 封装、bootable 标识）
- [docs/AUDIO.md](docs/AUDIO.md) —— ES8388 音频与 MCLK 门控
- [docs/VPU.md](docs/VPU.md) —— 视频编解码（MPP/RGA）
- [docs/CONFIG.md](docs/CONFIG.md) —— config.env 配置项
- [docs/ADB-USB3.md](docs/ADB-USB3.md) —— adb SuperSpeed 描述符 shim

## 致谢

[ophub/fnnas](https://github.com/ophub/fnnas)（底稿镜像与内核打包）·
[friendlyarm](https://github.com/friendlyarm)（u-boot 基线）·
[zhangyada/fnos-elf3588](https://github.com/zhangyada/fnos-elf3588)（同路线参考）
