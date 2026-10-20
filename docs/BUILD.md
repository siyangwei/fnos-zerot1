# 构建文档 —— fnOS (fnNAS) for Shimeta AIOT-3588A (RK3588)

本文说明这个适配项目**用到了哪些文件**、**怎么把板级 DTS 链接进内核构建**、以及完整的构建/烧录/验证流程。

---

## 1. 项目结构

```
fnos-zerot1/
├── dts/
│   └── rk3588-aiot3588a.dts     # ★ 板级设备树（本项目的核心）
├── build-image.sh               # ★ 一键构建：下载底稿镜像 + 编译 DTB + 替换 + 打包
├── scripts/
│   └── check-upstream.py        # 检查 ophub/fnnas 上游是否有更新（内核版本变了要同步）
├── assets/
│   └── MiniLoaderAll.bin        # 原厂 loader（只在救砖/整片烧写时用，正常构建不需要）
├── .github/workflows/
│   └── build.yml                # GitHub Actions 自动构建
├── docs/
│   └── BUILD.md                 # 本文
├── work/                        # 构建中间产物（下载的镜像、内核源码，gitignore）
└── output/                      # 最终镜像（gitignore）
```

---

## 2. 用到的外部文件与版本

| 用途 | 文件 / 来源 | 版本 | 说明 |
|---|---|---|---|
| 底稿系统镜像 | [ophub/fnnas](https://github.com/ophub/fnnas) release `fnnas_rockchip_1253` 里的 `fnnas_rockchip_nanopc-t6_k6.18.18_2026.09.23.img.gz` | 内核 **6.18.18** | 选 `nanopc-t6` 是因为它同为 RK3588 + RK806 PMIC，驱动/电源域最接近 |
| 内核设备树底稿 | mainline Linux **v6.18** 的 `arch/arm64/boot/dts/rockchip/rk3588-nanopc-t6.dtsi` | 6.18.18 | 本板 DTS 在它基础上裁剪修改（显示/音频/电源/串口都不同） |
| 内核源码 | `https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.18.18.tar.xz` | 6.18.18 | **只用来编译 DTB**，不重新编译整个内核（镜像里已经有同版本内核） |
| 硬件事实来源 | 视美泰原厂 2023 固件反编译树 `rk-kernel.dts` + 我们 RK BSP 6.1 的 `rk3588-aiot3588a.dts` | — | 引脚、GPIO、面板时序、电源顺序都以原厂固件为准 |

> ⚠ **内核版本必须与底稿镜像严格一致**：DTB 里的 `compatible` 字符串是和内核驱动匹配的，
> 6.18.18 的 dtb 拿到 6.12 的内核上会大面积 probe 失败。底稿镜像升级后请同步修改
> `build-image.sh` 里的 `KERNEL_VER / BASE_DATE / FNOS_RELEASE_TAG`，并先跑
> `scripts/check-upstream.py` 确认。

---

## 3. 为什么不能直接用 NanoPC-T6 的现成 DTB

NanoPC-T6 与本板同为 RK3588，但硬件差异不少，直接套用会黑屏/无音频：

| 功能 | NanoPC-T6 | **AIOT-3588A（本板）** |
|---|---|---|
| 主显示 | HDMI0（hdptxphy0） | **eDP**（hdptxphy0 + edp0），HDMI0 与 eDP 共用 PHY，二选一 |
| HDMI0/1 | 两路都有，走 VP0/VP1 | 只有 **HDMI1**（hdptxphy1，GPIO4_A0 使能），走 **VP0** |
| eDP | 无 | 1920x1080p60@139MHz；GPIO2_C5 使能、PWM1 背光（GPIO2_C1，周期 20000ns） |
| 音频 codec | RT5616（i2c7 0x1b） | **ES8388**（i2c7 0x1b），耳机检测 GPIO4_C2、功放使能 GPIO4_A3 低有效 |
| NPU 电源 | i2c2 rk8602 | **i2c1 rk8602**（i2c2 无设备） |
| 5V 外设电源 | 无（或不同 GPIO） | **GPIO3_D5 必须 always-on**，否则 eDP AUX 无应答、USB 不工作 |
| 串口 | uart2/uart6 | **uart1/4/6/7/8**（TTL-1/TTL-2/RS232-4/RS232-5/RS485-3）+ uart9(蓝牙) |
| 风扇 | pwm1 | **pwm12（m1 引脚组，50kHz，反相）** |
| SATA / miniPCIe | pcie2x1l1/l2 | **SATA0**（combphy0_ps）+ **miniPCIe 走 pcie2x1l1**（fe180000 / combphy1_ps） |
| 显示输出芯片 | — | **LT8668** 供电 GPIO4_PB6（always-on） |

DTS 里这些差异都逐条注明了，见 `dts/rk3588-aiot3588a.dts` 头注释。

---

## 4. 构建流程

```
① 下载 ophub 底稿镜像 (.img.gz, ~1.7GB)
        │
② 下载 linux-6.18.18 源码（~140MB，只为编译 DTB）
        │
③ 把 dts/rk3588-aiot3588a.dts 拷进内核树 + Makefile 注册 dtb
        │
④ make ARCH=arm64 rockchip/rk3588-aiot3588a.dtb      ← 只用 host 的 cpp + dtc
        │
⑤ losetup --offset $((32768*512)) 挂载镜像 p1（boot 分区）
        │
⑥ 替换 /boot/dtb/rockchip/rk3588-aiot3588a.dtb
   改 /boot/armbianEnv.txt: fdtfile=rockchip/rk3588-aiot3588a.dtb
        │
⑦ gzip 打包成 output/fnos-fnnas-aiot3588a-k6.18.18-<日期>.img.gz
```

全程**不重新编译内核**、不动 rootfs、不需要交叉编译工具链。

---

## 5. 内核命令详解（怎么把 DTS 链接进内核）

### 5.1 放置位置

arm64 的板级 dts 统一放在内核树：

```
<linux-6.18.18>/arch/arm64/boot/dts/rockchip/rk3588-aiot3588a.dts
```

### 5.2 在 Makefile 里注册

`arch/arm64/boot/dts/rockchip/Makefile` 里加一行（`build-image.sh` 会自动加在
`rk3588-nanopc-t6.dtb` 之后）：

```makefile
dtb-$(CONFIG_ARCH_ROCKCHIP) += rk3588-aiot3588a.dtb
```

### 5.3 编译单个 DTB（只需要宿主机工具）

```bash
cd linux-6.18.18
make ARCH=arm64 rockchip/rk3588-aiot3588a.dtb -j$(nproc)
# 产物：arch/arm64/boot/dts/rockchip/rk3588-aiot3588a.dtb
```

**不需要交叉编译器**：dtb 的构建只用到宿主机的 `cpp`（预处理）+ 内核自带的 `scripts/dtc/dtc`。

### 5.4 等价的手工命令（调试/快速验证时用）

```bash
cd linux-6.18.18/arch/arm64/boot/dts/rockchip

# 预处理（-nostdinc 防止误用系统头，-D__DTS__ 打开 dts 分支）
cpp -nostdinc \
    -I ../../../../../include \
    -I ../../../../../include/uapi \
    -I . -I .. \
    -undef -D__DTS__ -traditional -x assembler-with-cpp \
    -o /tmp/aiot-pre.dts rk3588-aiot3588a.dts

# 编译
../../../../../scripts/dtc/dtc -I dts -O dtb -o /tmp/aiot.dtb /tmp/aiot-pre.dts

# 反编译核对（看 status / phandle 连接）
../../../../../scripts/dtc/dtc -I dtb -O dts -o /tmp/aiot-check.dts /tmp/aiot.dtb
```

### 5.5 DTS 里引用的内核头文件

```c
#include <dt-bindings/gpio/gpio.h>              // GPIO_ACTIVE_HIGH/LOW
#include <dt-bindings/input/input.h>            // KEY_VOLUMEUP
#include <dt-bindings/pinctrl/rockchip.h>       // RK_Pxx、RK_FUNC_GPIO
#include <dt-bindings/pwm/pwm.h>                // PWM_POLARITY_INVERTED
#include <dt-bindings/soc/rockchip,vop2.h>      // ROCKCHIP_VOP2_EP_EDP0/HDMI1
#include <dt-bindings/usb/pd.h>                 // PDO_FIXED
#include "rk3588.dtsi"                          // SoC 级定义（base+extra+opp+pinctrl）
```

---

## 6. 本地构建

前置：Linux 主机、`sudo`、`curl`、`make`、`gzip`、`xz-utils`，磁盘 ≥ 10GB。

```bash
cd fnos-zerot1

# 用默认参数（nanopc-t6 / 6.18.18 / 2026.09.23 / fnnas_rockchip_1253）
sudo ./build-image.sh

# 或指定底稿
sudo BASE_BOARD=nanopc-t6 KERNEL_VER=6.18.18 BASE_DATE=2026.09.23 \
     FNOS_RELEASE_TAG=fnnas_rockchip_1253 ./build-image.sh

# 复用已下载的镜像和源码（跳过下载）
sudo SKIP_DOWNLOAD=1 ./build-image.sh
```

产物：`output/fnos-fnnas-aiot3588a-k6.18.18-<日期>.img.gz`

### 检查上游是否有更新

```bash
./scripts/check-upstream.py
```

---

## 7. GitHub Actions 构建

`.github/workflows/build.yml` 提供两种触发方式：

1. **手动触发**：Actions → `build-fnos-image` → Run workflow，可填
   `base_board / base_date / kernel_ver / release_tag`
2. **打 tag 触发**：`git tag v0.1.0 && git push origin v0.1.0` → 自动构建并创建 Release

> 镜像约 700MB（压缩后），artifact 保留 30 天；走 tag 时会直接挂到 Release 上。
> runner 需要清理磁盘（workflow 里已包含），否则空间不够。

---

## 8. 烧录

```bash
# Linux
sudo dd if=output/fnos-fnnas-aiot3588a-k6.18.18-20261020.img.gz of=/dev/sdX \
        bs=4M status=progress conv=fsync

# Windows：balenaEtcher / Rufus（直接选 .img.gz）
```

**救砖**：如果刷坏无法进系统，用 `assets/MiniLoaderAll.bin` + Rockchip `upgrade_tool`
（按住 maskrom 或短接，见原厂文档）恢复 loader 后再烧完整镜像。

---

## 9. 上电后验证清单

```bash
uname -r                                   # 应为 6.18.18
cat /proc/device-tree/model                # "Shimeta AIOT-3588A (zeroT1)"
dmesg | grep -iE 'edp|drm|panel'           # 应出现 panel-edp0 与 drm 初始化
ls /sys/class/drm/                         # card0-eDP-1 应 connected
cat /proc/asound/cards                     # 应有 es8388 声卡
ls /dev/ttyS*                              # 应有 ttyS1/4/6/7/8
ip link                                    # 应有 wlan0（AP6256）
lsblk                                      # 应有 mmcblk2（eMMC）、sda（SATA/miniPCIe）
```

---

## 10. 已知限制 / 待验证项

1. **ES8388 的 MCLK 输出门**：RK BSP 里靠一个自定义 `rockchip,clk-out` 节点
   （`mclkout_i2s0`）打开 SYS_GRF 的 I2S0 MCLK "to_io" 栅极；**上游 6.18 没有这个驱动**
   （`drivers/clk/rockchip/clk-out.c` 不存在），本 DTS 用标准
   `clocks = <&cru I2S0_8CH_MCLKOUT>`。**如果耳机/喇叭无声**，需要把 BSP 的
   clk-out 补丁打进 fnOS 内核，或改用外部 MCLK 方案。
2. **IR 遥控**：原厂用 pwm3 的 `rockchip,remotectl-pwm` 驱动，上游没有，本 DTS 未启用。
3. **WiFi 固件**：AP6256 = BCM43455，需要 `brcmfmac43455-sdio.bin/.txt` + nvram；
   fnOS 镜像若未自带，需放到 `/lib/firmware/brcm/`。
4. **蓝牙固件**：BCM4345C0 需要 `BCM4345C0.hcd`（`/lib/firmware/brcm/`）。
5. **NPU**：上游 6.18 有 `rknn_core_0/1/2` 节点但没有 rknpu 驱动，NPU 不可用。
6. **VPU 硬解/硬编**：上游 rkvenc/rkvdec 支持有限，NAS 场景一般不需要。
7. **HDMI0**：与 eDP 共用 `hdptxphy0`，本板 eDP 优先，HDMI0 关闭。
8. **HDMI IN**：`hdmi_receiver` 已启用，音频采集走 i2s7_8ch，待实物验证。

---

## 11. 排错

| 现象 | 排查 |
|---|---|
| 不启动、卡 u-boot | 串口 1500000 抓日志；确认 `DTB: rk-kernel.dtb` 后是否 `HASH(c): OK` |
| 启动但黑屏 | `cat /proc/device-tree/model` 确认加载的是本板 dtb；`/sys/class/drm/card0-eDP-1/status` |
| 镜像布局变了（mount 失败） | `fdisk -l 镜像` 看 p1 起始扇区，改 `build-image.sh` 的 `BOOT_OFFSET` |
| dtb 编译报 label 不存在 | 多半是上游 dtsi 改了节点名，对照 `rk3588-base.dtsi` 修 |
| 换内核版本后大量 probe 失败 | DTB 与内核版本不匹配，见第 2 节警告 |

---

## 12. 参考

- 上游镜像与打包框架：[ophub/fnnas](https://github.com/ophub/fnnas)
- 同路线参考实现（ELF3588）：[zhangyada/fnos-elf3588](https://github.com/zhangyada/fnos-elf3588)
- mainline NanoPC-T6 设备树：`arch/arm64/boot/dts/rockchip/rk3588-nanopc-t6.dtsi`
- RK3588 上游 pinctrl：`rk3588-base-pinctrl.dtsi` / `rk3588-extra-pinctrl.dtsi`
