#!/usr/bin/env bash
# build-all.sh —— 一键构建 fnOS for AIOT-3588A 的 update.img
#
# 阶段（都可单独跑，也可用 SKIP_* 跳过）：
#   1) build-rootfs.sh   下载/复用 fnOS 底稿镜像 → 提取 rootfs → 按序打 rootfs 补丁
#   2) prepare-boot.sh   下载 fnOS 官方内核包 → 组装 boot 内容（uInitrd 换 analogix_dp.ko）
#   3) build-dts.sh      用上游 6.18.18 源码编译板级 dtb（eDP/HDMI/WiFi/... 全部硬件描述）
#   4) pack-image.sh     组装 boot/rootfs/resource/misc → mkupdate.sh 打 update.img
#
# u-boot 与 loader 直接复用 assets/ 下的预编译产物（已修千兆时钟 + 直连引导，
# 见 docs/UBOOT.md）；只有要改 u-boot 时才需要重新编译。
#
# 用法：
#   sudo ./scripts/build-all.sh
#
# 常用加速开关（复用 work/ 里已下载/已提取的中间产物）：
#   SKIP_ROOTFS_EXTRACT=1  ROOTFS=$PWD/work/rootfs-official   跳过底稿下载/解压
#   SKIP_ROOTFS=1                                             rootfs 已打好补丁
#   SKIP_BOOT=1 FNOS_BOOT=$PWD/work/boot-fnos                 boot 内容已就绪
#   SKIP_DTS=1                                               dtb 已编译
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib-common.sh"

START_TS=$(date +%s)
need_root

# 兼容老变量：SKIP_KERNEL=1 视为“boot 与 dtb 都已就绪”
[ "${SKIP_KERNEL:-0}" = "1" ] && { SKIP_BOOT="${SKIP_BOOT:-1}"; SKIP_DTS="${SKIP_DTS:-1}"; }

[ "${SKIP_ROOTFS:-0}" = "1" ] || bash "$HERE/build-rootfs.sh"
[ "${SKIP_BOOT:-0}" = "1" ]   || bash "$HERE/prepare-boot.sh"
[ "${SKIP_DTS:-0}" = "1" ]    || bash "$HERE/build-dts.sh"
bash "$HERE/pack-image.sh"

log "完成，用时 $(( $(date +%s) - START_TS ))s"
log "产物目录 $OUTPUT_DIR:"
ls -lh "$OUTPUT_DIR"
