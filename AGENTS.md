# AGENTS.md —— zeroT1 fnOS 项目规范与编译约定

> 面向 AI Agent 与人类协作者：**动手前先读这一份**。它回答「目录是什么」「改完哪一步要重跑」「什么不能动」。
> 构建/引导链深入细节见 [docs/GUIDE.md](docs/GUIDE.md) 与 [docs/BUILD.md](docs/BUILD.md)。

## 0. 项目定位

把 [fnOS](https://www.fnnas.com/) 移植到 **视美泰 AIOT-3588A V1.1**（RK3588 核心板，代号 zeroT1），
产出 Rockchip 格式**全量 `update.img`**，一条命令烧录：

```bash
sudo upgrade_tool_2.45 uf fnos-aiot3588a-v1.1-update-YYYYMMDD.img
```

系统 = fnOS 官方 rootfs + **官方预编译内核**（6.18.18-trim）+ 本仓库板级设备树 + 上游 U-Boot v2026.10。
**本仓库不存放、不修改内核源码树**（fnOS 内核只有官方预编译包，改了 Web 管理界面会起不来）。

## 1. 核心架构：四个「外挂层」

板级支持全部通过下面四层实现，一切编译约定都由它推导：

| 层 | 载体 | 生效方式 |
|---|---|---|
| 设备树 | `dts/mainline-6.18/rk3588-aiot3588a.dts`（唯一主 dts） | `scripts/build-dts.sh` 编译 → `pack-image.sh` 放进 boot 分区 `dtb/rockchip/` |
| initramfs 内模块 | `assets/modules/<ver>/*.ko`（analogix_dp、tcpm） | `scripts/prepare-boot.sh` 用 `scripts/uinitrd-tool.py repack --replace` 替换 uInitrd 内同名 `.ko` |
| out-of-tree 模块 | `kernel-modules/<name>/`（**完整源码**） | 目标内核 headers 编译 → 产物入 `assets/modules/<ver>/`；板端换内核后由 `zt1-kernel-sync` 现编 |
| rootfs 改动 | `patches/rootfs/NN-*.sh` | `scripts/build-rootfs.sh` 按文件名顺序执行，打补丁进 rootfs |

引导链（上游 U-Boot）不走「内核源码树」，而是：`assets/uboot-upstream/src/` 里放板级源文件
（`zerot1-rk3588_defconfig`、`rk3588-aiot3588a.dts`、`rk3588-aiot3588a-u-boot.dtsi`），
`scripts/build-uboot-upstream.sh` 构建时覆盖进 u-boot 源码树 → 产物回写 `assets/uboot-upstream/`。

## 2. 目录结构（每个目录是什么、改完做什么）

| 目录 | 内容 | 入库 | 修改后要做 |
|---|---|---|---|
| `assets/` | 预编译产物：上游 u-boot（`uboot-upstream/`，含 `src/` 板级源文件）、厂商 `uboot.img`、内核模块 ko（`modules/<ver>/`）、bcmdhd、adbd-ss-shim（`.so` + 源码）、rkbin、Rockchip 打包工具 | ✅ | 改源码后重新编译产物并更新到这里 |
| `dts/mainline-6.18/` | 内核板级设备树（只有主 dts；host/usbdev 变体已归档） | ✅ | `./scripts/build-dts.sh`，然后重打镜像 |
| `kernel-modules/` | out-of-tree 模块**完整源码**：`analogix-dp-6.18.18/`（eDP）、`smdt-mcu-wdt/`（MCU 看门狗）、`tcpm-defer-fix/`（Type-C defer 修复） | ✅ | 编译 → 更新 `assets/modules/<ver>/`；同步 patch 记录 |
| `patches/kernel/<ver>/` | **内核补丁记录**（0001 analogix、0002 tcpm）：给人看的 diff，**不参与构建** | ✅ | 改模块时重新 `diff -u` 更新 |
| `patches/rootfs/` | 对 rootfs 的全部改动，`NN-` 前缀决定执行顺序（10…98），**必须幂等** | ✅ | 重跑 `build-rootfs`（可 `SKIP_ROOTFS_EXTRACT=1` 复用） |
| `scripts/` | 构建/打包/刷写脚本（见 §5） | ✅ | 用 `bash -n` 自查语法 |
| `archive/` | 淘汰备案（旧 dtb 变体、厂商 u-boot 补丁、停用脚本/模块），**不参与构建** | ✅ | 只归档、不删除，`archive/README.md` 写原因 |
| `docs/` | GUIDE/BUILD/CONFIG/AUDIO/UBOOT/VPU/ADB-USB3 | ✅ | 改动相关功能时同步更新 |
| `.github/workflows/` | CI：构建 + zstd 压缩 + tag 发 Release | ✅ | 改构建流程时同步 |
| `config.env.example` | 构建配置模板（WiFi/root 密码）；`config.env` 本地专用、不入库 | ✅ | 不改密钥进模板 |
| `work/` | 构建工作区（rootfs 缓存、内核包、源码树、中间产物） | ❌ | 可随时删；**不要手改** |
| `download/` `tmp/` | 下载缓存 / 临时文件 | ❌ | 可随时删 |
| `output/` | 镜像产物 `fnos-aiot3588a-v1.1-update-<日期>.img` + `.sha256` | ❌ | — |

## 3. `patches/kernel` 与 `kernel-modules` 的区别（最容易困惑）

- **`kernel-modules/` 是真正参与构建的完整源码**。fnOS 内核是预编译的，我们无法改内核源码树，
  所以对某个内核模块（analogix_dp、tcpm…）的修改方式是把**完整源文件**维护在这里，用目标内核
  headers 重编出同名 `.ko` 覆盖原厂模块（initramfs 里也替换）。
- **`patches/kernel/` 只是补丁记录**（`diff -u` 格式）：说明「相对上游 6.18.18 改了什么、为什么」，
  供审阅、移植、将来提上游参考。**构建脚本不会读取它**（可用 `grep -rn "patches/kernel" scripts/` 验证）。
- **规则**：改一个模块的行为 = 改 `kernel-modules/<name>/*.c` + 重新生成对应 `patches/kernel/6.18.18/NNNN-*.patch`，
  两处保持一致。新增模块时：目录带 `README.md`（根因/与哪些 DTS 配合/编译方法）+ patch 记录。

## 4. 编译约定

### 4.1 内核模块（out-of-tree）

- **必须用目标内核 headers**：板端 `/lib/modules/$(uname -r)/build`；主机侧用 `work/kernel-fnos/` 解包的
  `linux-headers-<ver>`。**不要用主机内核 headers**（架构/版本都不同）。
- 命令：`make -C <headers> M=$PWD modules`；产物 `strip --strip-debug` 后放 `assets/modules/<ver>/`。
- 每个模块加版本标识：`MODULE_VERSION("zt1-<name>")`，运行时用 `/sys/module/<name>/version` 验证。
- 每个模块目录三件套：源码 + `Makefile` + `README.md`（**写清楚为什么改**，含与 DTS/其他模块的配合关系）。

### 4.2 设备树

- `KERNEL_DIR=$PWD/work/linux-6.18.18 ./scripts/build-dts.sh`（只编 `rk3588-aiot3588a.dts`）。
- 改完检查：dtc 无 error；板端 `/proc/device-tree/...` 属性与预期一致（大端展示）。

### 4.3 U-Boot（仅在改引导时）

- 板级源文件只改 `assets/uboot-upstream/src/`；**不要改 `work/` 下解包出来的源码树**（一次性缓存）。
- `bash scripts/build-uboot-upstream.sh` 重新构建 → 更新 `assets/uboot-upstream/` 的
  `idbloader.img` / `u-boot.itb` / `u-boot-rockchip.bin` / `MD5SUMS`，再用 `scripts/make-ldr-loader.sh`
  生成 LDR `MiniLoaderAll.bin`。uf 的 loader 槽必须是 LDR 容器（BOOT 容器会 Download Boot Fail）。

### 4.4 rootfs 补丁（`patches/rootfs/NN-*.sh`）

- 文件名 `NN-` 数字前缀 = 执行顺序；**必须幂等**（重复执行结果一致）：用 `install`/`cat >`/`sed -i`，
  避免 `>>` 追加、避免 `mkdir` 不带 `-p`。
- 新增补丁：选未占用号段（现有 10~98），加文件后跑一次 `build-rootfs` 验证。
- 注意 `patch-rootfs.sh` 只执行 `*.sh`（`.disabled` 会被跳过）。

## 5. 构建与迭代

`scripts/build-all.sh` 四阶段（顺序固定）：

```
build-rootfs.sh   → 提取 fnOS 底稿 rootfs + 执行 patches/rootfs/*.sh
prepare-boot.sh   → 官方内核包 → Image/uInitrd（替换 analogix_dp.ko + tcpm.ko）+ 预置 kernel-sync marker
build-dts.sh      → 編译板级 dtb
pack-image.sh     → boot/rootfs/resource 分区 → mkupdate.sh 打包 update.img + 预置 marker
```

常用加速（迭代时只跑必要阶段）：

```bash
# 只改 rootfs 补丁
sudo env SKIP_BOOT=1 SKIP_DTS=1 ./scripts/build-all.sh
# 只改 DTS / 模块（boot 已就绪）
sudo env SKIP_ROOTFS=1 SKIP_BOOT=1 ./scripts/build-all.sh
# 只重打包
sudo env SKIP_ROOTFS=1 SKIP_BOOT=1 SKIP_DTS=1 ./scripts/build-all.sh
# 复用已有 rootfs 解包（SKIP_ROOTFS_EXTRACT 不是 SKIP_ROOTFS；会重跑 patch-rootfs）
sudo env SKIP_ROOTFS_EXTRACT=1 ROOTFS=$PWD/work/rootfs-official SKIP_BOOT=1 FNOS_BOOT=$PWD/work/boot-fnos SKIP_DTS=1 ./scripts/build-all.sh
```

- 首次构建自动下载约 2.1GB（底稿镜像、官方内核包、内核源码只需 dts 头文件）。
- 产物：`output/fnos-aiot3588a-v1.1-update-<日期>.img`（约 6.2GB）+ `.sha256`（**手动更新**：脚本只打印 sha256，
  不会写 `.sha256` 文件，改完记得 `sha256sum` 写回）。
- 需要 root（loop 挂载）、约 30GB 磁盘。

## 6. 镜像、内核与烧录约定

- **镜像内核 = fnOS 初始版**（当前 `6.18.18-trim`）；`c1202-trim` 是 Web 更新后的内核。验证问题时先确认
  `uname -r`，不要混淆两个内核的行为。
- boot 分区（512MB ext4）布局：`vmlinuz-<ver>` / `uInitrd-<ver>` / `config-<ver>` / `System.map-<ver>` +
  `Image`、`uInitrd` 软链 + `dtb/rockchip/` + `extlinux/`。
- **kernel-sync marker** `/boot/.zt1-uinitrd-<ver>.md5` 是三位：`<analogix_dp.ko md5> <uInitrd md5> <tcpm.ko md5>`
  （最后一位 2026-11-10 新增，旧两位向后兼容）。改动这三个文件中的任何一个都**必须同步 marker**，
  否则首次开机会走「修复模式」重编 initrd 并 30s 自动重启。
- **initramfs 优先加载**：uInitrd 里的 `.ko` 会在 ~2.3s 的 initramfs 阶段先于 rootfs 加载。所以修改
  analogix_dp / tcpm 时**必须同时替换 uInitrd 内的副本**（prepare-boot.sh 已做），只改 rootfs 不生效。
- 烧录：`sudo upgrade_tool_2.45 uf <img>` 是**唯一**命令（不要附加 db/rd；失败断电 5s 重进 MaskROM）。
- 镜像命名固定 `fnos-aiot3588a-v1.1-update-<YYYYMMDD>.img`；只适配 V1.1 板，**V1.3 勿刷**。

## 7. 板端验证约定

- 登录：`root` / `root`（SSH 或串口 `ttyS2 @1500000 8N1`，需 `stty raw`）。
- 自检：`zt1-check`（PASS/WARN/FAIL，日志 `/var/log/zt1-check.log`）——**改完镜像必跑**。
- 关键日志：`journalctl -b`、`dmesg`、`/var/log/zt1-kernel-sync.log`、
  Type-C 状态机 `/sys/kernel/debug/usb/tcpm-6-0022/log`（读一次即清空）。
- Type-C 验证三场景：插 U 盘 → `mode=host` + `lsblk` 出 `sda` + 挂载 `/vol00/USB`；插 PC → `mode=device` +
  adb 可见；拔除 → 回到无连接。
- 重启验证用 `systemctl reboot --no-block` 并比较 `boot_id`（**不要** `nohup sh -c "sleep 1; reboot"`，
  会延迟十几秒触发、误判失败）。

## 8. Git 提交约定

- 格式：`<type>(<scope>): <中文摘要>`；type 用 `fix` / `feat` / `refactor` / `docs` / `chore`。
- scope 常用：`typec`、`edp`、`wifi`、`audio`、`uboot`、`dts`、`kernel-sync`、`repo`、`check`、`build`。
- 一次提交一件事；提交前 `git status` 确认没有 `work/`、`output/` 产物（`.gitignore` 已挡）。
- `assets/` 里的二进制（u-boot、模块 ko）允许入库，更新时在提交说明里写清来源与验证方式。
- 实验性/被淘汰但值得保留的改动 → 移入 `archive/`（**不要直接删除**），在 `archive/README.md` 补原因。

## 9. 禁止 / 注意

- **不要动 `/home/zero/work/rk35xx-android14/`**（另一个项目的 Android14 SDK，与本项目无关）。
- 不要手改 `work/` 下的任何东西（rootfs 缓存、解包的 u-boot/内核源码树）——改源文件、重跑构建。
- 不要用「改了源码」冒充「已验证」：必须 构建 → 烧录/板端验证 → 记录结果。
- 烧录是破坏性操作，执行前先让用户确认。
- `assets/` 与 `patches/`、`kernel-modules/` 的一致性比「好看」重要：源码、patch 记录、ko 产物三者必须对应同一个改动。

## 10. 文档索引

- [docs/GUIDE.md](docs/GUIDE.md) —— 技术路线、引导链、功能状态、分区布局、使用
- [docs/BUILD.md](docs/BUILD.md) —— 构建细节、u-boot 重编、救砖
- [docs/CONFIG.md](docs/CONFIG.md) —— `config.env` 全部配置项 + Type-C/显示等关键修复说明
- [docs/UBOOT.md](docs/UBOOT.md) —— 上游 u-boot 的改动与验证
- [docs/AUDIO.md](docs/AUDIO.md) —— ES8388 音频拓扑与 MCLK 门控坑
- [docs/VPU.md](docs/VPU.md) —— 视频编解码现状
- [archive/README.md](archive/README.md) —— 淘汰方案清单与归档原因
