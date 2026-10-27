#!/usr/bin/env bash
# 构建 zeroT1 专用的 analogix_dp.ko（fnOS 6.18.18-trim 内核）
#
# 背景：fnOS 官方内核 6.18.18-trim 的 eDP 在本板上第一次 modeset 不生效，
#       且 DPCD max_link_rate 首次读回 0；见
#       patches/kernel/6.18.18/0001-analogix-dp-rockchip-edp-bringup.patch
#
# 用法:
#   utils: 需先准备内核源码树并 modules_prepare（见 docs/BUILD.md）
#   KERNEL_SRC=/path/to/linux-6.18.18 scripts/build-analogix-dp.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KERNEL_SRC="${KERNEL_SRC:-$ROOT/work/linux-6.18.18}"
SRC_DIR="$ROOT/kernel-modules/analogix-dp-6.18.18"
BUILD_DIR="${BUILD_DIR:-/tmp/adp-build}"
CROSS="${CROSS_COMPILE:-/home/zero/work/rk35xx-android14/prebuilts/gcc/linux-x86/aarch64/gcc-arm-10.2-2020.11-x86_64-aarch64-none-linux-gnu/bin/aarch64-none-linux-gnu-}"
STRIP="${CROSS}strip"

[ -d "$KERNEL_SRC" ] || { echo "缺少内核树: $KERNEL_SRC"; exit 1; }
[ -f "$KERNEL_SRC/Module.symvers" ] || echo "警告: $KERNEL_SRC/Module.symvers 不存在，modpost 会报 undefined"

rm -rf "$BUILD_DIR"; mkdir -p "$BUILD_DIR"
cp "$SRC_DIR"/* "$BUILD_DIR"/

export PATH=/usr/bin:/bin:$PATH      # 避免 ~/.kimi-code/bin 里的 bc 桩
make -C "$KERNEL_SRC" M="$BUILD_DIR" ARCH=arm64 CROSS_COMPILE="$CROSS" modules

"$STRIP" --strip-debug "$BUILD_DIR/analogix_dp.ko" -o "$BUILD_DIR/analogix_dp.stripped.ko"
ls -l "$BUILD_DIR"/analogix_dp*.ko
echo "产物: $BUILD_DIR/analogix_dp.ko (strip 后: analogix_dp.stripped.ko)"
