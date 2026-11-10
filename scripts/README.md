# scripts/ —— 构建、打包、刷写脚本

全部 bash（`lib-common.sh` 提供公共函数），入口是 `build-all.sh`。执行需 root（loop 挂载）。

## 构建主流程（按顺序）

| 脚本 | 阶段 | 作用 |
|---|---|---|
| `build-all.sh` | 一键 | rootfs → boot(内核/initramfs) → dts → pack；支持 `SKIP_*` 单步加速 |
| `build-rootfs.sh` | ① | 从 fnOS 底稿镜像提取 rootfs，逐条执行 `patches/rootfs/*.sh`，再 `normalize-ownership.sh` 修属主 |
| `prepare-boot.sh` | ② | 解包 fnOS 官方内核包 → 生成 `Image`/`uInitrd`（`uinitrd-tool.py` 替换 `analogix_dp.ko` + `tcpm.ko`）→ 预置 kernel-sync marker |
| `build-dts.sh` | ③ | 用 `work/linux-6.18.18` 的头文件 cpp + dtc 编译 `dts/mainline-6.18/rk3588-aiot3588a.dts` |
| `pack-image.sh` | ④ | 组装 boot/rootfs/resource 分区 → `mkupdate.sh` 打 `update.img` + 预置 marker（三位：analogix/uInitrd/tcpm md5） |

## 辅助

| 脚本 | 作用 |
|---|---|
| `patch-rootfs.sh` | 单独跑 rootfs 补丁（`--list` / `--only NN`） |
| `normalize-ownership.sh` | rootfs 属主归一（否则 postgres/ssh 在新镜像里坏掉） |
| `uinitrd-tool.py` | initramfs 解析/替换/重打包（legacy uImage + zstd），`prepare-boot.sh` 调用 |
| `build-analogix-dp.sh` | 单独重编 eDP 模块 → `assets/modules/<ver>/` |
| `build-uboot-upstream.sh` | 下载上游 u-boot v2026.10 → 覆盖 `assets/uboot-upstream/src/` 板级文件 → 构建 → 产出 `idbloader.img`/`u-boot.itb`/LDR（仅改 u-boot 时） |
| `make-ldr-loader.sh` | 用厂商 `boot_merger` ini 流水线把 SPL+DDR 封装成 LDR `MiniLoaderAll.bin` |
| `flash-image.sh` | 一条命令刷全量镜像（内部 `upgrade_tool uf`） |
| `flash-uboot-upstream.sh` | 兜底：MaskROM 下分步刷 loader1/loader2 |
| `check-upstream.py` | 检查上游 U-Boot/内核新版本（辅助） |
| `lib-common.sh` / `lib-chroot.sh` | 公共变量、日志、chroot 辅助 |

## 约定

- 改脚本后 `bash -n` 自查；CI 跑 `build.yml` 复用同样入口。
- 产物统一 `output/fnos-aiot3588a-v1.1-update-<日期>.img`；`.sha256` 需手动写回（脚本只打印）。
- 烧录唯一命令：`sudo upgrade_tool_2.45 uf output/<img>`（loader 槽必须是 LDR 容器）。
