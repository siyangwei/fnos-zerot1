# fnos-zerot1

**fnOS（飞牛 NAS / fnNAS）for 视美泰 AIOT-3588A（RK3588 核心板，代号 zeroT1）**

> **硬件版本：本仓库只适配 AIOT-3588A *V1.1* 板型。**
> AIOT-3588A 官方有 **V1.1** 与 **V1.3** 两个板型（分别对应 2023-06-09 与 2024-03-14 两版官方固件，
> 硬件规格书也不同）。本项目的 dtb、供电/GPIO、eDP/HDMI/USB 配置都以 **V1.1** 实板为准，
> 镜像文件名、Release 说明里均标注 `v1.1`。**V1.3 未做适配与验证，请勿直接刷 V1.3 板子。**

把 [fnOS](https://www.fnnas.com/) 移植到视美泰 AIOT-3588A 板子上，产出 **Rockchip 格式的全量 `update.img`**，
一条命令烧录：

```bash
sudo upgrade_tool_2.45 uf fnos-aiot3588a-v1.1-update-YYYYMMDD.img
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
output/fnos-aiot3588a-v1.1-update-<日期>.img   （RKFW，upgrade_tool uf 烧录）
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
| 无线 | BCM43455（AP6256）2.4G/5G，**支持 5G DFS 信道**（ch52-64/100-144，实测 5320MHz 稳定；镜像默认 `WIFI_COUNTRY=US` 并在 NetworkManager 前由 `zt1-wifi-regdom.service` 设置法规域——CN/world 域下固件不扫描 DFS，是国内 5G 搜不到的根因）；蓝牙 BCM4345C5（可搜索/连接） |
| USB | **adb over USB3.0 SuperSpeed**（bcdUSB 0x0320、5Gbps 链路）；唯一 Type-C（OTG）口**自动识别 device/host**：插 U 盘约 1.5s 自动切主机并挂载（host 模式为 USB2 480Mbps）、拔掉约 9s 自动回 device（adb 可用），也可 `zt1-usb-role status\|auto\|device\|host [--reboot\|--now]` 手动切；2 个标准 USB-A（3.0/2.0）+ 6 路插针 USB 均正常 |
| 存储 | btrfs rootfs（固定 5.6GB；**已用 dpkg-divert + `zt1-rootfs-guard` 永久禁止 fnOS 更新后自动扩容**）；剩余空间在 fnOS Web「存储空间」里建存储池；boot 分区 ext4 512MB（版本化内核 + `Image`/`uInitrd` 符号链接，与 fnOS 官方一致） |
| SD/TF 卡 | 板载 SD 控制器可用：**SDR104 198MHz**，实测顺序读 **86.9 MB/s**（`GPIO0_B7` 电源极性已修） |
| 系统更新 | Web「更新和还原」可正常更新（已验证 1.1.31 → 1.2.1000、内核 c1196）；`zt1-kernel-sync` 自动重编板级模块、切内核并自动重启一次 |
| 视频编解码 | 硬解：H.264（含 4K）、HEVC（含 4K）、VP9、VP8、MPEG-1/2/4、H.263、MJPEG；硬编：H.264、MJPEG |
| GPU | Mali-G610 用户态库（fnOS 应用中心「Mali GPU Driver」可安装）：OpenCL/Vulkan/EGL 可用；XFCE 桌面固定 `AccelMethod=none`（不用 GL，避免 Mali libgbm 与 Xorg glamor 冲突） |
| NPU | **RK3588 NPU 可用**：`rknpu 0.9.8` 正常 probe（`/sys/class/devfreq/fdab0000.npu`、`/sys/kernel/debug/rknpu/{load,freq,power}`）；实测 `librknnrt 2.3.2` + fnOS「飞牛AI引擎」`face_det.rk3588.rknn` 640x640 单帧 **145 ms**、输出 12800/3200/800 三个张量 |
| 电源 / 杂项 | 秒级重启（CRU 复位 + RK806 RST_FUN 修复）、风扇 PWM、板载 MCU 看门狗、串口 console（ttyS2@1500000） |

### 已知问题

- **AV1 只有硬解不可用（软解正常）**：fnOS 预编译内核的 av1d IOMMU 适配有缺陷（`iommu_map_nosync` 对同一
  iova 重复调用 `av1_iommu_map`，第二次返回 `-EADDRINUSE`，PTE 不回滚），启用 DT 节点后设备能注册但解码失败；
  纯设备树/CMA 层面无法修复，故 DT 里保持 `av1d@fdc70000` / `iommu@fdca0000` 的 `status = "disabled"`
  （**与 fnOS 官方默认一致**，非"砍功能"）。AV1 **软解照常可用**：ffmpeg 默认就走 `libdav1d`
  （`ffmpeg -i x.av1.mkv -f null -` → `Stream #0:0 -> #0:0 (av1 (libdav1d))`），另保留 AOM native `av1` 解码器；
  `av1_rkmpp` 解码器仍在列表里，但没有设备时调用会报 `mpp: error found on mpp initialization`，不可用。
- **HEVC 硬编**打开失败（`-22`），H.264/MJPEG 硬编正常。
- HDMI 的 2K240 等高刷模式需要 FRL，本内核/固件未启用，会被拒绝；4K60 及以下（TMDS 范围）正常。
- HDMI1 必须接在 VOP **VP2** 上（设备树已固定），否则与 eDP 同时启用时黑屏。
- adb 传输速度约 18 MB/s，受厂商 adbd（android-tools 4.2.2）协议限制，链路本身 5Gbps。
- **WiFi 5G 搜不到**：若你的 5G 热点在 DFS 信道（常见 ch52-64/100-144），请确认 `/etc/zerot1/config.env` 里 `WIFI_COUNTRY="US"`（默认即是）；改成 `CN` 会失去 DFS 扫描能力。最省事的替代方案是把路由器 5G 固定到非 DFS 信道（36-48 或 149-165）。
- Type-C（唯一 OTG 口）**自动识别**：`zt1-otg-autoswitch` 守护进程每 0.5s 读 fusb302 `STATUS0`（`0x82`=CC 上挂着 sink 设备）+ xhci 设备表，自动写 dwc3 debugfs 的 `mode` 完成 device↔host 切换。原因：fnOS 内核的 typec/tcpm 不工作（无 partner、无状态机日志，`waiting_for_supplier`），内核不会自己切角色，所以用用户态补上这一层。
- 手动/持久切换仍可用：`sudo zt1-usb-role host --now`（本次开机立即生效，不改 dtb）、`sudo zt1-usb-role host --reboot`（改 dtb 持久）；`status` 看当前 dtb 角色与运行时 mode。手动切后 10 分钟内自动切换不干预。
- 注意：Type-C 在 **host 模式下只跑 USB2 480Mbps**（该口 USB3 SS 通道未起来；厂商 Ubuntu 用同一颗 PHY
  在 host 模式可达 5Gbps，说明硬件支持、差异在 typec/phy 配置），大文件建议用标准 USB-A 3.0 口。
- 安装「Mali GPU Driver」后，Mali 的 `libgbm/libEGL` 会通过 `/etc/ld.so.conf.d/00-aarch64-mali.conf`
  抢先于 Mesa 被加载；Xorg modesetting 的 glamor 此时会 `ScreenInit failed` 导致 lightdm 起不来。
  镜像已预置 `/etc/X11/xorg.conf.d/20-zt1-accel.conf`（`AccelMethod=none`）避开该问题，桌面不受影响。
- NPU 需要两处设备树配合（镜像已内置）：①NPU 三段 reg 只映射低 `0x9000`（0x9000/0xa000 偏移被 npu iommu 占用，
  按厂商 0x10000 映射会 `-EBUSY`）；②补 `npu-opp-table`（否则 `rknpu 0.9.8` 报
  `failed to init opp info` 不绑定驱动、devfreq 不出现）。

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
sudo upgrade_tool_2.45 uf fnos-aiot3588a-v1.1-update-YYYYMMDD.img
```

`uf` 会自带 loader、写入全部分区并自动复位。板子进 MaskROM 后执行即可；若 `uf` 失败，
先 `upgrade_tool_2.45 db assets/MiniLoaderAll.bin` 再重试。更详细的救砖流程见
[docs/BUILD.md](docs/BUILD.md)。

### 2. 首次开机

- 网线/WiFi 任一能上网即可；**出厂镜像没有任何普通用户**，浏览器访问 `http://<板子IP>` 走 fnOS
  初始化向导弹出「开始使用 fnOS」，注册的管理员就是后续登录账号。
- 设备名初始为 `fnnas`，由向导设置。
- **默认 root 密码是 `root`**（与 fnOS 官方镜像一致；控制台/串口/SSH 都可用），首次登录后建议用 `passwd root` 改掉。
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

构建产物在 `output/fnos-aiot3588a-v1.1-update-<日期>.img`，脚本会打印 sha256。

### 4. 系统更新与内核同步（重要）

fnOS 的「系统更新」是按包 `dpkg` 安装的，会把新内核写进 `/boot/vmlinuz-<ver>` 并用符号链接
`Image` / `uInitrd` 指向当前版本（镜像的 boot 分区是 **512MB**，足够放多版内核）。

本镜像自带 `zt1-kernel-sync`（`/usr/local/sbin/`，systemd service + path 触发，默认 `AUTOSYNC=1`）：
Web 更新装上新内核后，它会自动

1. 用新内核的 `linux-headers` 重编三个外挂模块：`analogix_dp.ko`（eDP 点亮）、`rk806_rstfix.ko`（PMIC 复位→重启）、`smdt_mcu_wdt.ko`（板载 MCU 看门狗）；
2. `mkinitramfs` + `mkimage` 生成 `uInitrd-<ver>`；
3. 把 `Image` / `uInitrd` 软链切到新内核（旧内核保留，可回滚）。

安全措施：任一步失败或 initrd 校验不通过（会先解一层确认是 cpio）都**拒绝切换**，继续用旧内核；
同步用 `flock` 串行化，path 触发与开机触发不会重复重编。

切换成功后默认**自动重启一次**（`REBOOT_AFTER_SYNC=1`）让新内核真正生效：
fnOS 的更新流程是「装完包立刻自动重启」，那次重启时 `/Image` 仍指向旧内核，
本服务随后切软链并再自动重启一次，用户全程不用手动干预（想手动控制就设 `REBOOT_AFTER_SYNC=0`）。

```bash
zt1-kernel-sync --status     # 看当前内核/软链/AUTOSYNC
zt1-kernel-sync --force      # 立即同步一次（不等更新）
zt1-kernel-sync --rollback   # 回滚到上一个内核
zt1-kernel-sync --disable    # 关掉自动跟随
```

> 更新后如果系统自动重启了一次，此时可能只是"内核已装但未切换"。再执行一次
> `zt1-kernel-sync --status` 确认，必要时 `--force`，然后再重启一次即用上新内核。

### 4. 构建（GitHub Actions）

`.github/workflows/build.yml`：

- 手动触发（Actions → Build image → Run workflow），或推送 `v*` 标签自动创建 Release；
- 全程在 Ubuntu runner 上完成：下载底稿/内核/源码 → 构建 → **zstd 压缩** → 上传 artifact（tag 时发 Release）；
- 产物有两个文件（约 1.5~1.8GB 压缩包，比原始 6.1GB 小很多）：
  - `fnos-aiot3588a-v1.1-update-<日期>.img.zst` —— 压缩后的整盘镜像
  - `fnos-aiot3588a-v1.1-update-<日期>.img.zst.sha256` —— 压缩包自身的校验和（下载后先验）
  - `SHA256SUMS` —— 解压后镜像本体的校验和
- 下载后：

  ```bash
  sha256sum -c fnos-aiot3588a-v1.1-update-*.img.zst.sha256   # 校验压缩包
  unzstd fnos-aiot3588a-v1.1-update-*.img.zst                # 解压得到 .img
  sha256sum -c SHA256SUMS                               # 校验镜像本体
  sudo upgrade_tool_2.45 uf fnos-aiot3588a-v1.1-update-*.img # 烧录
  ```

- WiFi 密码、root 密码通过 **Actions Secrets**（`WIFI_SSID` / `WIFI_PASSWORD` /
  `WIFI_FALLBACK_SSID` / `WIFI_FALLBACK_PASSWORD` / `ROOT_PASSWORD` / `USB_ROLE`）注入，仓库里不存明文。

---

## 分区布局

| 分区 | 起始(扇区) | 大小 | 文件系统 | 内容 |
|---|---|---|---|---|
| uboot | 0x4000 | 4MB | — | 定制 u-boot |
| misc | 0x6000 | 4MB | — | 全零 |
| resource | 0x8000 | 16MB | — | `rk-kernel.dtb` |
| boot | 0x10000 | **512MB** | **ext4** | `vmlinuz-*` + `uInitrd-*` + `config-*` + `System.map-*` + `Image→vmlinuz-*`、`uInitrd→uInitrd-*`（软链）+ `dtb/rockchip/*.dtb` |
| rootfs | 0x110000 | 按内容 +64MB 对齐（约 5.6GB） | btrfs | fnOS rootfs |

rootfs 之后的空间不建分区，留给 fnOS 在 Web 管理界面「存储空间」里创建存储池/扩容。

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
