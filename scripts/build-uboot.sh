#!/usr/bin/env bash
# build-uboot.sh —— （可选）重新编译友善 u-boot 并更新 assets/ 里的预编译产物
#
# 平时不需要跑：assets/uboot.img 与 assets/MiniLoaderAll.bin 已经是编译好的、
# 含 distro_bootcmd「扫描全部分区」补丁的产物（已验证能启动本板）。
# 只有要改 u-boot 时才需要。
#
# 依赖：aarch64-linux-gnu- 交叉工具链，以及 friendlyarm/rkbin（自动 clone）
#
# 用法：./scripts/build-uboot.sh [--update-assets]
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib-common.sh"

UBOOT_REPO="${UBOOT_REPO:-https://github.com/friendlyarm/uboot-rockchip}"
UBOOT_BRANCH="${UBOOT_BRANCH:-nanopi6-v2017.09}"
UBOOT_DIR="$WORK_DIR/uboot-rockchip"
RKBIN_DIR="$WORK_DIR/rkbin"

if [ -z "${CROSS_COMPILE:-}" ]; then
    if command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
        CROSS_COMPILE="aarch64-linux-gnu-"
    elif [ -x "$PROJECT_DIR/prebuilts/gcc/linux-x86/aarch64/gcc-linaro-6.3.1-2017.05-x86_64_aarch64-linux-gnu/bin/aarch64-linux-gnu-gcc" ]; then
        CROSS_COMPILE="$PROJECT_DIR/prebuilts/gcc/linux-x86/aarch64/gcc-linaro-6.3.1-2017.05-x86_64_aarch64-linux-gnu/bin/aarch64-linux-gnu-"
    else
        die "找不到 aarch64 交叉工具链"
    fi
fi
export CROSS_COMPILE

[ -d "$RKBIN_DIR" ] || git clone --depth 1 -b nanopi6 https://github.com/friendlyarm/rkbin "$RKBIN_DIR"
if [ ! -d "$UBOOT_DIR" ]; then
    git clone --depth 1 -b "$UBOOT_BRANCH" "$UBOOT_REPO" "$UBOOT_DIR"
fi

# make.sh 约定：源码目录的同级有 rkbin/（u-boot/../rkbin）
ln -sfn "$RKBIN_DIR" "$(dirname "$UBOOT_DIR")/rkbin"

cd "$UBOOT_DIR"
# 打本项目 u-boot 补丁（按版本自动选目录）
log "应用 u-boot 补丁（scripts/patch-uboot.sh）"
bash "$PROJECT_DIR/scripts/patch-uboot.sh" "$UBOOT_DIR"

log "编译 u-boot（make.sh nanopi6）"
./make.sh nanopi6

log "产物: uboot.img $(stat -c %s uboot.img) B"

if [ "${1:-}" = "--update-assets" ]; then
    cp -f uboot.img "$ASSETS_DIR/uboot.img"
    cp -f rk3588_spl_loader_v1.18.113.bin "$ASSETS_DIR/MiniLoaderAll.bin"
    log "已更新 assets/uboot.img 与 assets/MiniLoaderAll.bin"
fi
