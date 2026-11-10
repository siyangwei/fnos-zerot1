# 使用与实现详解（GUIDE）

> 面向想深入了解构建链/引导链/驱动适配的读者。只想快速烧录使用请看仓库根目录的 [README](../README.md)。

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
GitHub Actions 一键完成，产物见 [Releases](https://github.com/siyangwei/fnos-zerot1/releases)。

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
上游 U-Boot v2026.10（自建 zerot1-rk3588_defconfig + 板级 dts；bootstd + extlinux 引导）
        ↓
output/fnos-aiot3588a-v1.1-update-<日期>.img   （RKFW，upgrade_tool uf 一条命令烧录）
```

### 引导链（上游 U-Boot）

```
BootROM
  ↓  eMMC 0x40      idbloader.img     （binman: TPL(DDR) + SPL）
  ↓  eMMC 0x4000    u-boot.itb        （FIT: BL31 v1.56 + U-Boot 2026.10 + DTB）
  ↓  bootstd 扫描所有分区 → extlinux bootmeth
  ↓  boot 分区(p4) /extlinux/extlinux.conf
  ↓  kernel = /Image（软链 → vmlinuz-<ver>）、initrd = /uInitrd、fdt = /dtb/rockchip/…dtb
  ↓  append: root=UUID=<rootfs 分区 UUID> rootfstype=btrfs …
fnOS（rootfs p5，按 UUID 挂载，不写死分区号）
```

- **不写死 rootfs 分区**：bootstd 默认只扫描带 legacy-bootable 属性的分区，因此我们在
  `parameter.txt` 里给 boot 分区加了 `bootable` 标识（`0x00100000@0x00010000(boot:bootable)`），
  bootstd 就能扫到 p4 的 `/extlinux/extlinux.conf`；root 由 `append root=UUID=…` 决定。
  **U-Boot 源码保持上游 v2026.10 原样，不打任何补丁。**
- u-boot 阶段不需要再修 CPLL：内核 dtsi 的 `assigned-clocks` 会把 `pll_cpll` 设成 1.5GHz、
  `clk_gmac_125m` 设成 125MHz（实测 Linux 侧 `clk_gmac_125m = 125000000`）。
- **Linux 侧不做任何改动**，所以与 fnOS 官方内核/rootfs 完全兼容。
- 旧的「厂商定制 u-boot」方案仍保留：构建时传 `UBOOT_MODE=vendor` 即可（见 [UBOOT.md](UBOOT.md)）。

`uf` 的 loader 槽必须是 `LDR ` 容器，仓库用 `scripts/make-ldr-loader.sh`（boot_merger 的厂商
`NEWIDB=true` ini 流水线：DDR + 上游 SPL）生成 `assets/uboot-upstream/MiniLoaderAll.bin`，
因此**一条 `uf` 命令就能把整条上游引导链刷进板子**。

**为什么用 fnOS 官方内核而不是主线/友善内核**：fnOS 管理界面（trim 系列服务）依赖
`trimafs` 私有文件系统、ZFS、`rk_vcodec` 等只存在于官方内核的驱动，换内核会导致 Web 管理界面
无法启动；因此内核保持官方预编译版本，板级支持全部通过 **设备树 + initramfs 里的模块替换 +
用户态模块** 实现。

**为什么换上游 u-boot**：厂商 2017.09 u-boot 用内核 dtb 设时钟时 PLL 编号与内核差 1，
会把 CPLL 写成 1188MHz，导致 GMAC 参考时钟 99MHz（千兆网口完全不通），而且它的
bootcmd 写死「从 0x40 处读 SPL、直连 /Image」，升级/换布局都很别扭。上游 U-Boot 2026.10
用 bootstd + extlinux 扫描分区、按 UUID 挂 rootfs，引导链清晰且完全可复现（源码/补丁都在仓库）。

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
| USB | **adb over USB3.0 SuperSpeed**（bcdUSB 0x0320、5Gbps 链路）；唯一 Type-C（OTG）口由内核 tcpm **原生自动切换 device/host**：插 U 盘自动切主机并挂载（host 模式为 USB2 480Mbps）、插 PC 自动切 device（adb 可用）；2 个标准 USB-A（3.0/2.0）+ 6 路插针 USB 均正常 |
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
- Type-C（唯一 OTG 口）**自动识别**：由内核 tcpm（fusb302 + usb-role-switch）原生切换，插 U 盘/键鼠自动 host 并挂载，插 PC 自动 device（adb）。2026-11-10 修好：DTS 把 role_sw 端点挂到 connector 的 `port@2`，并删掉 `&usbdp_phy1` 误绑的 `phy-supply = <&vbus5v0_typec>`（否则 VBUS 常开，U 盘场景卡在 `SRC_ATTACH_WAIT`）。旧的 `zt1-usb-role` / `zt1-otg-autoswitch` 用户态方案已归档到 `archive/rootfs/`。
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
  uboot-upstream/         上游 U-Boot v2026.10：idbloader.img / u-boot.itb / LDR MiniLoaderAll.bin / src 源码
  uboot.img               厂商定制 u-boot（UBOOT_MODE=vendor 时使用，4MB）
  tools/boot_merger       Rockchip loader 打包工具（生成 LDR 用）
  modules/6.18.18-trim/   analogix_dp.ko / brcmfmac 三件套 / smdt_mcu_wdt.ko / tcpm.ko
  bcmdhd/                 bcmdhd WiFi 驱动（模块 + 源码 + 固件，默认 WiFi 驱动）
  adbd-ss-shim/           libadbd_ss_shim.so（adb SuperSpeed 描述符 shim）
  tools/                  mkupdate.sh / resource_tool 等 Rockchip 打包工具
dts/mainline-6.18/      板级设备树（只有 rk3588-aiot3588a.dts）
kernel-modules/         out-of-tree 模块完整源码（analogix-dp、smdt-mcu-wdt、tcpm-defer-fix）
patches/kernel/6.18.18/ 内核补丁记录（diff 形式，不参与构建，供审阅/移植参考）
patches/rootfs/         构建时对 rootfs 做的全部改动（按文件名顺序执行）
archive/                淘汰备案（旧 dtb 变体、厂商 u-boot 补丁、停用脚本/模块，不参与构建）
scripts/                构建脚本（见下）
docs/                   构建/音频/U-Boot/VPU 说明
.github/workflows/      GitHub Actions 自动构建
config.env.example      构建配置模板（复制为 config.env 后填写；含密码，不入库）
AGENTS.md               项目规范与编译约定（目录职责/改动流程/禁止事项，动手前先读）
```

**目录与缓存约定**（同一个项目只放一个文件夹，避免散落）：

| 目录 | 内容 | 是否入库 |
|---|---|---|
| `assets/` | 实际使用的预编译产物（我们的上游 u-boot/idbloader/LDR、rkbin、bcmdhd、内核模块、打包工具） | 是 |
| `work/` | 本机构建工作区（解包出的 rootfs、内核包缓存、u-boot/内核源码树、中间产物） | 否（gitignore） |
| `download/` | 下载缓存（大 tar 包等），可随时删除 | 否（gitignore） |
| `tmp/` | 临时文件 | 否（gitignore） |

说明：fnOS 使用的内核是 ophub 官方 `6.18.18-trim` 预编译包（`scripts/prepare-boot.sh` 下载并解包，缓存放
`work/kernel-fnos/`），本仓库**不存放内核源码树**；对内核驱动的修改以 `kernel-modules/` 里的完整源码重编同名
`.ko` 覆盖（initramfs 与 rootfs 各一份），`patches/kernel/` 只保存对应 diff 记录、**不参与构建**。u-boot 不是
友善 vendor 树，而是上游 U-Boot v2026.10（板级源文件在 `assets/uboot-upstream/src/`，产物与源码缓存同目录）。
早期曾放在仓库根目录的 `kernel-rockchip/`、`uboot-rockchip/`、`rkbin/` 是旧路线的中间源码树，与实际使用的不是
同一份，已删除；需要重建时按 `scripts/build-uboot-upstream.sh` 自动下载到 `work/` 下即可。

构建脚本：

| 脚本 | 作用 |
|---|---|
| `scripts/build-all.sh` | 一键：rootfs → 内核/initramfs → 设备树 → 打包（支持 `SKIP_*` 单步加速） |
| `scripts/build-rootfs.sh` | 从 ophub 底稿镜像提取 rootfs，逐条执行 `patches/rootfs/*.sh` |
| `scripts/prepare-boot.sh` | 下载 fnOS 内核包，生成 `Image`/`uInitrd`（替换 analogix_dp.ko + tcpm.ko，预置 kernel-sync marker） |
| `scripts/build-dts.sh` | 下载内核源码中必要的 dts 头文件，cpp + dtc 编译板级 dtb |
| `scripts/build-analogix-dp.sh` | 单独重编 eDP 模块（`kernel-modules/analogix-dp-6.18.18/`）并放入 `assets/modules/` |
| `scripts/check-upstream.py` | 检查上游 U-Boot / 内核是否有新版本（辅助） |
| `scripts/normalize-ownership.sh` | 修正 rootfs 属主（否则 postgres/ssh 会在新镜像里坏掉） |
| `scripts/pack-image.sh` | 组装 boot/rootfs/resource 分区并打包 `update.img` |
| `scripts/uinitrd-tool.py` | 解析/替换/重打包 initramfs（legacy uImage + zstd） |
| `scripts/build-uboot-upstream.sh` | 下载上游 u-boot v2026.10 → 应用补丁 → 构建 → 生成 LDR（仅改 u-boot 时需要；CI 直接复用 assets） |
| `scripts/make-ldr-loader.sh` | 用 boot_merger 厂商 ini 流水线把上游 SPL+DDR 封装成 LDR `MiniLoaderAll.bin` |
| `scripts/flash-image.sh` | 一条命令刷写：`sudo bash scripts/flash-image.sh output/xxx.img`（内部就是 `upgrade_tool uf`） |
| `scripts/flash-uboot-upstream.sh` | 兜底：MaskROM 下分步刷 loader1/idbloader + loader2/u-boot.itb |

---

## 使用

### 1. 烧录

```bash
sudo upgrade_tool_2.45 uf fnos-aiot3588a-v1.1-update-YYYYMMDD.img
```

`uf` 会自带 loader（镜像内置 LDR）、写入全部分区，板子进 MaskROM 后执行即可，刷完 `upgrade_tool_2.45 rd` 重启。
也可以直接用封装脚本：`sudo bash scripts/flash-image.sh output/xxx.img`。
若 `uf` 卡在 `Download Boot Fail`，说明设备侧 DDR 状态异常：**给板子断电 5 秒、重新进 MaskROM** 再试。
救砖/兜底见 [BUILD.md](BUILD.md)（`db assets/MiniLoaderAll.bin` + `scripts/flash-uboot-upstream.sh`）。

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
sudo ./scripts/build-all.sh                       # 默认 --UBOOT_MODE=upstream（上游 U-Boot）
# 或用厂商 u-boot： sudo env UBOOT_MODE=vendor ./scripts/build-all.sh
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

1. 用新内核的 `linux-headers` 重编两个外挂模块：`analogix_dp.ko`（eDP 点亮）、`smdt_mcu_wdt.ko`（板载 MCU 看门狗）；
   （RK806 PMIC 复位模式已由板级 DTB 的 `rockchip,reset-mode = <1>` 交给内核原生驱动处理，不再需要 `rk806_rstfix.ko`）
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
  `WIFI_FALLBACK_SSID` / `WIFI_FALLBACK_PASSWORD` / `ROOT_PASSWORD`）注入，仓库里不存明文。

---

## 分区布局

| 分区 | 起始(扇区) | 大小 | 文件系统 | 内容 |
|---|---|---|---|---|
| uboot | 0x4000 | 4MB | — | 上游 U-Boot 的 `u-boot.itb`（FIT: BL31 + U-Boot + DTB）；`UBOOT_MODE=vendor` 时为厂商 `uboot.img` |
| misc | 0x6000 | 4MB | — | 全零 |
| resource | 0x8000 | 16MB | — | `rk-kernel.dtb` |
| boot | 0x10000 | **512MB** | **ext4** | `vmlinuz-*` + `uInitrd-*` + `config-*` + `System.map-*` + `Image→vmlinuz-*`、`uInitrd→uInitrd-*`（软链）+ `dtb/rockchip/*.dtb` |
| rootfs | 0x110000 | 按内容 +64MB 对齐（约 5.6GB） | btrfs | fnOS rootfs |

rootfs 之后的空间不建分区，留给 fnOS 在 Web 管理界面「存储空间」里创建存储池/扩容。

`parameter.txt` 必须含 `TYPE: GPT`，否则 `upgrade_tool uf` 会假成功。

---

## 文档索引

- [BUILD.md](BUILD.md) —— 构建细节、分区/引导链、u-boot 重编、救砖
- [AUDIO.md](AUDIO.md) —— ES8388 音频拓扑与 RK3588 MCLK 门控坑
- [UBOOT.md](UBOOT.md) —— 定制 u-boot 的改动与生效验证
- [VPU.md](VPU.md) —— 视频编解码（MPP/RGA）现状
- [CONFIG.md](CONFIG.md) —— config.env 全部配置项说明

## 致谢

- [ophub/fnnas](https://github.com/ophub/fnnas)：底稿镜像与官方内核打包
- [friendlyarm](https://github.com/friendlyarm)：u-boot 基线
- [zhangyada/fnos-elf3588](https://github.com/zhangyada/fnos-elf3588)：同路线参考
