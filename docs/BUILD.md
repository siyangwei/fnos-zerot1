# 构建与烧录说明

本文说明 `fnos-zerot1` 镜像的完整构建链路：每个文件从哪来、为什么这么拼，以及烧录/救砖。

## 0. 一句话版本

```bash
cp config.env.example config.env   # 填 WiFi / root 密码（可留空）
sudo ./scripts/build-all.sh        # 首次约 20~40 分钟（含下载约 2.1GB）
sudo upgrade_tool_2.45 uf output/fnos-aiot3588a-v1.1-update-YYYYMMDD.img
```

## 1. 镜像由哪几块拼成

| 部件 | 来源 | 是否入库 | 说明 |
|---|---|---|---|
| loader | 仓库 `assets/MiniLoaderAll.bin` | ✅ | RK3588 DDR 初始化 + 一级 loader |
| u-boot | 仓库 `assets/uboot.img`（定制，见 `docs/UBOOT.md`） | ✅ | 修 CPLL=1500MHz、补 FS_EXT4、直连引导 |
| 内核 `Image` | ophub/fnnas release `kernel_fnnas` 的 `6.18.18-rockchip.tar.gz` → `vmlinuz-6.18.18-trim` | ❌ 构建时下载 | fnOS 官方内核（trimafs/zfs/rk_vcodec 私有驱动，不可替换） |
| initramfs `uInitrd` | 同上 → `uInitrd-6.18.18-trim`，替换其中的 `analogix_dp.ko` | ❌ 构建时生成 | eDP 驱动在 initramfs 早期就要加载，只改 rootfs 不生效 |
| 设备树 | `dts/mainline-6.18/*.dts` + mainline 6.18 头文件 | ✅ dts / ❌ 头文件下载 | 全部板级硬件描述（eDP/HDMI/WiFi/BT/MPP/音频/网口/USB） |
| rootfs | ophub/fnnas 底稿镜像 `fnnas_rockchip_1253`（nanopc-t6，k6.18.18）→ GPT 第 2 分区 | ❌ 构建时下载 | Debian 12 + fnOS 服务；只取 rootfs，内核/引导全部换掉 |
| rootfs 修改 | `patches/rootfs/NN-*.sh`（按文件名顺序执行） | ✅ | 全套板级适配与出厂态整理 |

为什么内核不能自己编：fnOS 管理界面的 `trim` 服务、`trimafs` 挂载、`rk_vcodec` 等
都依赖官方内核 ABI/私有模块，自编内核（mainline 或友善 BSP）都会把 Web 管理界面搞坏。
因此本项目"内核保持官方预编译、板级支持全部走 DT + 模块 + 用户态"。

## 2. 构建环境

- Linux x86_64 构建机（GitHub Actions 的 `ubuntu-24.04` 即可）
- root 权限（loop 挂载、chroot、losetup）
- 依赖：`rsync zstd cpio device-tree-compiler gcc e2fsprogs btrfs-progs fdisk parted qemu-user-static bzip2 xz-utils curl python3`
- 磁盘 ≥ 30GB（底稿镜像 + 解包 + rootfs + 产物；`work/` 峰值约 20GB）
- 首次运行需能访问：GitHub releases（底稿镜像/内核包）、kernel.org（dts 头文件）

## 3. 构建阶段

`scripts/build-all.sh` 依次执行，每一步都能单独跑；用 `SKIP_*` 复用缓存加速。

### 3.1 `build-rootfs.sh` —— 准备 rootfs

1. 下载 `fnnas_rockchip_nanopc-t6_k6.18.18_2026.09.23.img.gz`（约 1.75GB）到 `work/`；
2. 解压后按固定 GPT offset（rootfs 在 LBA 1081344）用 `rsync` 提取出根分区到 `work/rootfs/`；
3. 交给 `patch-rootfs.sh` 逐条执行 `patches/rootfs/NN-*.sh`（chroot + qemu-aarch64-static）。

常用开关：

```bash
SKIP_ROOTFS_EXTRACT=1 ROOTFS=$PWD/work/rootfs   # 复用已提取的 rootfs，跳过下载/解压
sudo ./scripts/patch-rootfs.sh work/rootfs --only 57,70   # 只重跑指定补丁
```

### 3.2 `prepare-boot.sh` —— 组装 boot 分区内容

1. 下载 `kernel_fnnas/6.18.18-rockchip.tar.gz`（约 105MB），解出 `boot-rockchip-6.18.18-trim.tar.gz`；
2. `vmlinuz-6.18.18-trim` → `work/boot-fnos/Image`；
3. `uInitrd-6.18.18-trim` 用 `scripts/uinitrd-tool.py repack` 把
   `usr/lib/modules/6.18.18-trim/kernel/drivers/gpu/drm/bridge/analogix/analogix_dp.ko`
   换成 `assets/modules/6.18.18-trim/analogix_dp.ko`（我们修过 eDP 的版本）；
4. 同时留档 `config` / `System.map`。

`uInitrd` 是 legacy uImage（64 字节头，`comp=0`）+ **zstd** 压缩的 cpio；
`uinitrd-tool.py` 支持 `info` / `list` / `repack --replace 内部路径=本地文件`。

### 3.3 `build-dts.sh` —— 编译设备树

板级 dts `#include "rk3588.dtsi"`，所以需要 mainline 源码里的 dts 头文件：

1. 若 `work/linux-6.18.18/` 缺 `include/dt-bindings/` 或 `arch/arm64/boot/dts/rockchip/rk3588.dtsi`，
   下载 `linux-6.18.18.tar.xz`（147MB，kernel.org，失败自动换清华镜像），
   只解出 `include/`、`arch/arm64/boot/dts/`、`scripts/dtc/`；
2. `cpp -nostdinc -undef -D__DTS__ -x assembler-with-cpp …` + `dtc -I dts -O dtb`；
3. 输出 `work/images/dtb/rockchip/{rk3588-aiot3588a.dtb, rk3588-aiot3588a-usbdev.dtb}`。

### 3.4 `pack-image.sh` —— 组装分区并打包

| 分区 | 起始扇区 | 大小 | FS | 内容 |
|---|---|---|---|---|
| uboot | 0x4000 | 4MB | — | `assets/uboot.img` |
| misc | 0x6000 | 4MB | — | 全零 |
| resource | 0x8000 | 16MB | — | `resource_tool` 打的 `rk-kernel.dtb` |
| boot | 0x10000 | **512MB** | **ext4** | `vmlinuz-*`/`uInitrd-*`/`config-*`/`System.map-*` + `Image`、`uInitrd` 符号链接 + `dtb/rockchip/*` + `extlinux/` |
| rootfs | 0x30000 | 内容 +64MB 对齐 | btrfs | `work/rootfs` |
| userdata | rootfs 之后 | grow | btrfs | 空分区 |

要点：

- **boot 必须是 ext4、512MB**：定制 u-boot 里补了 `CONFIG_FS_EXT4`，直接从 `mmc 0:4` 读
  `/Image` → `/uInitrd` → `/dtb/rockchip/rk3588-aiot3588a.dtb` 后 `booti`；`Image`/`uInitrd`
  是符号链接（u-boot 的 ext4 驱动支持解析），指向版本化内核文件，这样 fnOS Web 更新
  装的新内核能自动生效。512MB 才能容纳 42.8MB vmlinuz + initrd + 旧版本（每版约 87MB）；
  不读 `boot.scr` / `extlinux.conf`（后者只留给宿主机手动 `sysboot`）。
- **u-boot 2017.09 的 ext4 驱动不支持 64bit / metadata_csum**，`mkfs.ext4` 必须加
  `-O ^64bit,^metadata_csum -I 256`，否则 u-boot 报 `Unrecognized filesystem type`。
- **rootfs 属主归一**：`normalize-ownership.sh` 以官方底稿为参照把 uid/gid 校正回来。
  历史坑：构建树里 3 万多个文件被改成 uid 1000 后，postgres 无法读数据目录（Web 注册报
  `E_DATABASE_ERROR`）、`sshd_config` 非 root 拥有导致 sshd 拒绝启动。
- `parameter.txt` 必须含 `TYPE: GPT`，否则 `upgrade_tool uf` 会假成功。

## 4. 常用迭代命令

```bash
# 全量
sudo ./scripts/build-all.sh

# 只改 rootfs 补丁（复用内核/dtb）
sudo env SKIP_BOOT=1 SKIP_DTS=1 ./scripts/build-all.sh

# 只改设备树
sudo env SKIP_ROOTFS=1 SKIP_BOOT=1 ./scripts/build-all.sh

# 只重打包（rootfs/boot/dtb 都就绪）
sudo env SKIP_ROOTFS=1 SKIP_BOOT=1 SKIP_DTS=1 ./scripts/build-all.sh

# 复用现成 rootfs.img（只改 boot/uboot 时最快）
sudo env SKIP_ROOTFS=1 SKIP_BOOT=1 SKIP_DTS=1 \
     ROOTFS_IMG_REUSE=$PWD/work/fnos-update/rootfs.img ./scripts/build-all.sh
```

产物 `output/fnos-aiot3588a-v1.1-update-<日期>.img`，脚本末尾打印 sha256。

## 5. 烧录与救砖

### 5.1 正常烧录（一条命令）

```bash
sudo upgrade_tool_2.45 uf output/fnos-aiot3588a-v1.1-update-YYYYMMDD.img
```

板子进入 MaskROM（按住 recovery 键上电，或 `reboot loader`）后执行。`uf` 会写入全部分区并自动复位。

### 5.2 只刷引导（调试 u-boot/kernel 时）

```bash
sudo upgrade_tool_2.45 db assets/MiniLoaderAll.bin
sudo upgrade_tool_2.45 wl 0x4000 assets/uboot.img
sudo upgrade_tool_2.45 wl 0x10000 work/fnos-update/boot.img    # boot 分区（64MB ext4）
sudo upgrade_tool_2.45 rd
```

注意：**单独 `wl loader` 后不要直接 `rd`**（会退回 MaskROM 状态），要么补齐 uboot+boot，要么整包 `uf`。

### 5.3 串口

调试串口是 **ttyS2，1500000 8N1**。板侧串口默认有 getty 自动登录 root；
若只收到乱码/无回显，先 `stty -F /dev/ttyACM1 1500000 raw -echo` 再读。

## 6. 常见故障

| 现象 | 原因 / 处理 |
|---|---|
| `uf` 报成功但开不了机 | `parameter.txt` 缺 `TYPE: GPT`，或分区大小算错；见 §3.4 |
| u-boot 报 `Unrecognized filesystem type` | boot.img 不是 ext4，或 mkfs 开了 64bit/metadata_csum |
| u-boot 卡在 `Synchronous Abort`/重启 | 用了原版 distro_bootcmd；换定制 `assets/uboot.img` |
| 千兆网口不通（百兆能通但丢包） | u-boot 未修 CPLL（Linux 侧 `clk_gmac_125m` 应为 125000000，不是 99MHz） |
| 进桌面后 eDP 黑屏、HDMI 有画面 | 设备树里 HDMI1 走了 VP0；必须走 VP2（见 `dts/mainline-6.18/rk3588-aiot3588a.dts` 注释） |
| 没声音（喇叭/耳机） | 内核没开 I2S0 MCLK 的 GRF `to_io` 门控；镜像里 `zt1-audio-mclk.service` 负责写 `0xfd58c318` |
| Web 注册报 `E_DATABASE_ERROR` | rootfs 属主被污染 → 重跑 `normalize-ownership.sh` 后重打镜像 |
| adb 只有 USB2 速度 | `patches/rootfs/48-adb-gadget.sh` 的 shim 没装上，或 `max_speed` 不是 `super-speed` |

## 7. GitHub Actions 产物

`build.yml` 构建完成后会把镜像做 zstd 压缩再上传（原始 6.1GB → 约 1.5~1.8GB）：

- `fnos-aiot3588a-v1.1-update-<日期>.img.zst`：整盘镜像
- `fnos-aiot3588a-v1.1-update-<日期>.img.zst.sha256`：压缩包校验和（下载后先验）
- `SHA256SUMS`：解压后镜像本体的校验和

```bash
sha256sum -c fnos-aiot3588a-v1.1-update-*.img.zst.sha256
unzstd fnos-aiot3588a-v1.1-update-*.img.zst
sha256sum -c SHA256SUMS
sudo upgrade_tool_2.45 uf fnos-aiot3588a-v1.1-update-*.img
```

推 `v*` 标签时这三个文件会直接挂到 GitHub Release 上。

## 8. 相关文档

- [UBOOT.md](UBOOT.md) —— 定制 u-boot 的源码改动与重编方法
- [AUDIO.md](AUDIO.md) —— ES8388 音频拓扑与 MCLK 门控
- [VPU.md](VPU.md) —— MPP/RGA 编解码启用记录与 AV1 结论
- [ADB-USB3.md](ADB-USB3.md) —— adb SuperSpeed 的 FunctionFS v2 shim
- [CONFIG.md](CONFIG.md) —— config.env 变量与 CI Secrets


## 附：rootfs 自动扩容已被禁用

fnOS 的 `trim` 包 postinst 每次升级都会 `systemctl enable resize-rootfs.service`，
该服务会把 rootfs 扩到 28GB、吃掉留给存储池的空间。本镜像在 `patches/rootfs/90-rootfs-resize.sh`
里用 **dpkg-divert + stub + `zt1-rootfs-guard` 开机自愈** 彻底关掉它（原脚本保留在
`/usr/trim/bin/resize-rootfs.sh.distrib`，用 `dpkg-divert --remove --rename` 可恢复官方行为）。

## 上游 U-Boot 引导链（默认）

默认使用**上游 U-Boot（v2026.10）引导链**（`UBOOT_MODE=upstream`）；`UBOOT_MODE=vendor` 可退回厂商 2017.09 方案：

| 位置 | 内容 |
|---|---|
| `assets/uboot-upstream/idbloader.img` | binman 产物：TPL(2112/2400 DDR) + SPL，写到 eMMC 0x40 |
| `assets/uboot-upstream/u-boot.itb` | FIT：BL31 v1.56 + U-Boot + DTB，写到 eMMC 0x4000 |
| `assets/uboot-upstream/MiniLoaderAll.bin` | **LDR 封装**：厂商 USB 段 + 上游 idbloader 三段，供 `uf` 整包刷写 |
| `assets/uboot-upstream/src/` | defconfig / 板级 dts / u-boot dtsi |

要点：

- 上游 bootstd + extlinux 自动扫描：`parameter.txt` 给 boot 分区带 `bootable` 标识，bootstd 才能扫到 `/extlinux/extlinux.conf`；**不写死 rootfs 分区**，root 由 `extlinux.conf` 的 `append root=UUID=…` 决定。
- `uf` 的 loader 槽只接受 LDR 格式，`scripts/make-ldr-loader.sh` 会把上游 `idbloader.img` 重新封装成 LDR（生成 `assets/uboot-upstream/MiniLoaderAll.bin`），已做回读校验。
- 构建：`sudo bash scripts/build-uboot-upstream.sh`（下载 tarball → 应用补丁 → 构建 → 生成 LDR → 更新 MD5SUMS）。
- 打包：`UBOOT_MODE=upstream sudo -E bash scripts/pack-image.sh`。
- 刷写：`sudo bash scripts/flash-image.sh output/xxx.img`（等价 `upgrade_tool uf`）；失败兜底为三步刷 `db - wl 0x40 idbloader - wl 0x4000 u-boot.itb - rd`。
