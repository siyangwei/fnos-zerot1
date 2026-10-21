#!/usr/bin/env bash
# build-all.sh —— 一键构建 fnOS for AIOT-3588A 的 update.img
#
# 阶段：
#   1) build-rootfs.sh  下载/复用 fnOS 底稿 → 提取 rootfs → 打补丁（fstab/固件/adb/xfce/watchdog）
#   2) build-kernel.sh  克隆友善内核 → 打补丁（看门狗）→ 编 Image + dtb + modules_install
#   3) pack-image.sh    组装 boot/rootfs/resource/misc → mkupdate.sh 打 update.img
#
# u-boot 与 loader 默认直接复用 assets/ 里的预编译产物（已验证可启动）；
# 需要改 u-boot 时跑 scripts/build-uboot.sh 重新生成。
#
# 用法：sudo ./scripts/build-all.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib-common.sh"

START_TS=$(date +%s)
need_root

[ "${SKIP_ROOTFS:-0}" = "1" ] || bash "$HERE/build-rootfs.sh"
[ "${SKIP_KERNEL:-0}" = "1" ] || bash "$HERE/build-kernel.sh"
bash "$HERE/pack-image.sh"

log "完成，用时 $(( $(date +%s) - START_TS ))s"
log "产物目录 $OUTPUT_DIR:"
ls -lh "$OUTPUT_DIR"
