#!/usr/bin/env bash
# build-kernel.sh —— 编译友善 Linux 内核（含本项目补丁）并产出 Image + dtb + modules
#
# 产物：
#   $IMAGE_DIR/Image                              -> 放进 boot 分区
#   $IMAGE_DIR/dtb/rockchip/rk3588-aiot3588a.dtb  -> 放进 boot 分区
#   $ROOTFS/lib/modules/<ver>/                    -> modules_install 结果（供 pack 阶段用）
#
# 环境变量：
#   KERNEL_REPO / KERNEL_BRANCH / KERNEL_DEFCONFIG / CROSS_COMPILE
#   SKIP_KERNEL_CLONE=1  复用已有的 work/kernel-rockchip
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$HERE/.." && pwd)"
source "$HERE/lib-common.sh"

KERNEL_REPO="${KERNEL_REPO:-https://github.com/friendlyarm/kernel-rockchip}"
KERNEL_BRANCH="${KERNEL_BRANCH:-nanopi6-v6.1.y}"
KERNEL_DEFCONFIG="${KERNEL_DEFCONFIG:-nanopi6_linux_defconfig}"
KERNEL_DIR="${KERNEL_DIR:-$WORK_DIR/kernel-rockchip}"
JOBS="$(nproc)"

: "${ROOTFS:?ROOTFS 未设置}"
: "${IMAGE_DIR:?IMAGE_DIR 未设置}"

# ---- 工具链 ----
if [ -z "${CROSS_COMPILE:-}" ]; then
    if [ -n "${KERNEL_CROSS_COMPILE:-}" ]; then
        CROSS_COMPILE="$KERNEL_CROSS_COMPILE"
    elif [ -x "$PROJECT_DIR/prebuilts/gcc/linux-x86/aarch64/gcc-arm-10.2-2020.11-x86_64-aarch64-none-linux-gnu/bin/aarch64-none-linux-gnu-gcc" ]; then
        CROSS_COMPILE="$PROJECT_DIR/prebuilts/gcc/linux-x86/aarch64/gcc-arm-10.2-2020.11-x86_64-aarch64-none-linux-gnu/bin/aarch64-none-linux-gnu-"
    elif command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
        CROSS_COMPILE="aarch64-linux-gnu-"
    else
        die "找不到 aarch64 交叉工具链（设置 CROSS_COMPILE，或 apt install gcc-aarch64-linux-gnu）"
    fi
fi
log "使用交叉工具链: $CROSS_COMPILE"

# ---- 源码 ----
if [ ! -d "$KERNEL_DIR" ]; then
    log "clone 内核源码 $KERNEL_REPO ($KERNEL_BRANCH)"
    git clone --depth 1 -b "$KERNEL_BRANCH" "$KERNEL_REPO" "$KERNEL_DIR"
fi
cd "$KERNEL_DIR"

# ---- 应用本项目的内核补丁 + 板级 dts + 驱动源码 ----
log "应用内核补丁"
for p in "$PROJECT_DIR"/patches/kernel/*.patch; do
    [ -e "$p" ] || continue
    if git apply --check "$p" 2>/dev/null; then
        git apply "$p"
        log "  applied $(basename "$p")"
    else
        log "  skip (already applied?) $(basename "$p")"
    fi
done

# 驱动源码（patch 里只有 Kconfig/Makefile/defconfig，大文件单独拷）
if [ -d "$PROJECT_DIR/patches/kernel/files" ]; then
    cp -f "$PROJECT_DIR"/patches/kernel/files/* drivers/watchdog/ 2>/dev/null || true
fi

# 板级 dts
cp -f "$PROJECT_DIR/dts/rk3588-aiot3588a.dts" arch/arm64/boot/dts/rockchip/
# dts Makefile 注册（幂等）
if ! grep -q 'rk3588-aiot3588a.dtb' arch/arm64/boot/dts/rockchip/Makefile; then
    echo 'dtb-$(CONFIG_ARCH_ROCKCHIP) += rk3588-aiot3588a.dtb' >> arch/arm64/boot/dts/rockchip/Makefile
fi

# ---- 配置 ----
log "生成 .config ($KERNEL_DEFCONFIG)"
make -s ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" "$KERNEL_DEFCONFIG"

# ---- 编译 ----
log "编译 Image + modules (-j$JOBS)"
make -j"$JOBS" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" Image modules

# ---- 产物 ----
mkdir -p "$IMAGE_DIR/dtb/rockchip"
cp -f arch/arm64/boot/Image "$IMAGE_DIR/Image"
cp -f arch/arm64/boot/dts/rockchip/rk3588-aiot3588a.dtb "$IMAGE_DIR/dtb/rockchip/"

KVERSION="$(make -s ARCH=arm64 kernelrelease 2>/dev/null || true)"
if [ -n "$KVERSION" ]; then
    log "modules_install -> $ROOTFS/lib/modules/$KVERSION"
    make -s ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" INSTALL_MOD_PATH="$ROOTFS" modules_install
    # 清掉 fnOS 原镜像自带的旧内核模块目录（避免膨胀）
    for d in "$ROOTFS"/lib/modules/*; do
        [ -d "$d" ] || continue
        [ "$(basename "$d")" = "$KVERSION" ] && continue
        log "  删除旧模块目录: $d"
        rm -rf "$d"
    done
fi

log "内核产物: Image $(stat -c %s "$IMAGE_DIR/Image") B, dtb $(stat -c %s "$IMAGE_DIR/dtb/rockchip/rk3588-aiot3588a.dtb") B"
