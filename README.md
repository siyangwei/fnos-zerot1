# fnos-zerot1

**fnOS（飞牛 NAS 系统 / fnNAS）for 视美泰 AIOT-3588A（RK3588）**

把 [fnOS](https://www.fnnas.com/) 移植到视美泰 AIOT-3588A 核心板（本项目内部代号 zeroT1）。

不重打包 rootfs，而是沿用 ophub 的通用 RK3588 镜像，**只替换板级设备树（DTB）**：

```
ophub 官方镜像（nanopc-t6 / mainline 6.18.18）
   └── 替换 /boot/dtb/rockchip/rk3588-aiot3588a.dtb
   └── armbianEnv.txt: fdtfile=rockchip/rk3588-aiot3588a.dtb
   └── 重新打包 .img.gz
```

**同一路线参考**：[zhangyada/fnos-elf3588](https://github.com/zhangyada/fnos-elf3588)

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
| 其他 | RTC(hym8563)、USB-C(OTG+PD)、3×USB Host、风扇(PWM)、ADC 按键 |

---

## 快速开始

### 直接用预编译镜像

从 [Releases](../../releases) 下载 `fnos-fnnas-aiot3588a-k*.img.gz`，用 balenaEtcher 或 `dd` 写入 SD/TF 卡或 eMMC。

```bash
sudo dd if=fnos-fnnas-aiot3588a-k6.18.18-*.img.gz of=/dev/sdX bs=4M status=progress conv=fsync
```

### 自己构建

```bash
sudo ./build-image.sh
```

产物在 `output/`。需要 ~10GB 磁盘与 `sudo`（挂载 boot 分区）。

### GitHub Actions

仓库 Actions → `build-fnos-image` → Run workflow，或打 tag 自动出 Release。

---

## 目录

```
dts/rk3588-aiot3588a.dts   板级设备树（本项目核心，基于 mainline v6.18 NanoPC-T6 裁剪）
build-image.sh             一键构建脚本
scripts/check-upstream.py  检查 ophub 上游更新
docs/BUILD.md              完整构建文档（用到的文件、内核命令、排错）
assets/MiniLoaderAll.bin   救砖用 loader（可选）
```

---

## 设备树改动要点

相对 NanoPC-T6 上游 DTS 的主要差异（详细注释见 `dts/rk3588-aiot3588a.dts` 头部）：

- 主显示 **eDP**（`hdptxphy0` + `edp0` → VOP **VP1**），HDMI0 与 eDP 共用 PHY 故关闭
- HDMI 输出走 **HDMI1**（`hdptxphy1` → VOP **VP0**）
- 音频 **ES8388**（i2c7 0x1b / i2s0_8ch），耳机检测 GPIO4_C2、功放使能 GPIO4_A3
- **NPU 电源在 i2c1**（rk8602），CPU 大核在 i2c0
- **5V 外设电源 GPIO3_D5 必须 always-on**（否则 eDP AUX 无应答、USB 不工作）
- 5 路业务串口 uart1/4/6/7/8 + uart9(蓝牙)
- 风扇 pwm12、SATA0、miniPCIe(pcie2x1l1)

---

## 已知限制

| 项目 | 状态 |
|---|---|
| eDP / HDMI1 显示 | ✅ 设备树完整，待实物验证 |
| 串口 ×5 | ✅ |
| ES8388 音频 | ⚠ 上游无 `rockchip,clk-out` 驱动，MCLK 门控可能需补丁（见 docs/BUILD.md §10） |
| WiFi AP6256 | ⚠ 需要 brcmfmac 固件/nvram |
| 蓝牙 AP6256 | ⚠ 需要 BCM4345C0.hcd |
| NPU | ❌ 上游 6.18 无 rknpu 驱动 |
| IR 遥控 | ❌ 上游无 remotectl 驱动 |
| GPU | ⚠ 依赖 panthor 驱动 |

---

## 致谢

- [ophub/fnnas](https://github.com/ophub/fnnas) —— fnOS RK3588 镜像打包框架
- [zhangyada/fnos-elf3588](https://github.com/zhangyada/fnos-elf3588) —— 同路线参考
- FriendlyElec NanoPC-T6 上游设备树
- 视美泰原厂固件与硬件资料
