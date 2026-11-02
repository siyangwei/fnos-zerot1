#!/usr/bin/env bash
# build-dts.sh —— 用上游 Linux 源码树编译板级设备树（dts/mainline-6.18/*.dts）
#
# 只需要内核源码里的 include/ 与 arch/arm64/boot/dts/（编译 dts 用），
# 不编译内核，也不需要交叉工具链（cpp + dtc 即可）。
#
# 输入：dts/mainline-6.18/rk3588-aiot3588a.dts（+ -usbdev.dts，用 #include 继承）
# 输出：$IMAGE_DIR/dtb/rockchip/*.dtb（pack-image.sh 会放进 boot 与 resource 分区）
#
# 用法：
#   ./scripts/build-dts.sh
#   KERNEL_DIR=/path/linux-6.18.18 ./scripts/build-dts.sh     # 复用现有源码树
#
# 环境变量：
#   KERNEL_DIR        Linux 源码树；默认 $WORK_DIR/linux-6.18.18（缺失则自动下载）
#   LINUX_SRC_URL     源码包地址（默认 kernel.org，失败自动换清华镜像）
#   LINUX_VERSION     内核版本，默认 6.18.18
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib-common.sh"

LINUX_VERSION="${LINUX_VERSION:-6.18.18}"
KERNEL_DIR="${KERNEL_DIR:-$WORK_DIR/linux-$LINUX_VERSION}"
SRC_URLS=(
    "${LINUX_SRC_URL:-https://cdn.kernel.org/pub/linux/kernel/v${LINUX_VERSION%%.*}.x/linux-$LINUX_VERSION.tar.xz}"
    "https://mirrors.tuna.tsinghua.edu.cn/kernel/v${LINUX_VERSION%%.*}.x/linux-$LINUX_VERSION.tar.xz"
)
DTS_SRC="$DTS_DIR/mainline-6.18"
OUT_DIR="$IMAGE_DIR/dtb/rockchip"

need_tree() {
    [ -f "$KERNEL_DIR/include/dt-bindings/gpio/gpio.h" ] &&
    [ -f "$KERNEL_DIR/arch/arm64/boot/dts/rockchip/rk3588.dtsi" ]
}

if ! need_tree; then
    TARBALL="$WORK_DIR/linux-$LINUX_VERSION.tar.xz"
    if [ ! -f "$TARBALL" ]; then
        mkdir -p "$WORK_DIR"
        for u in "${SRC_URLS[@]}"; do
            log "下载内核源码: $u"
            if curl -fL --retry 3 --retry-delay 2 -o "$TARBALL.part" "$u"; then
                mv "$TARBALL.part" "$TARBALL"; break
            fi
            warn "下载失败，尝试下一个镜像"
        done
        [ -f "$TARBALL" ] || die "内核源码下载失败，请用 KERNEL_DIR=... 指定源码树"
    fi
    log "只解出编译 dts 所需的目录（include/ arch/arm64/boot/dts/ scripts/dtc/）"
    mkdir -p "$WORK_DIR"
    tar -xJf "$TARBALL" -C "$WORK_DIR" \
        "linux-$LINUX_VERSION/include" \
        "linux-$LINUX_VERSION/arch/arm64/boot/dts" \
        "linux-$LINUX_VERSION/scripts/dtc"
    need_tree || die "源码树不完整: $KERNEL_DIR"
fi

mkdir -p "$OUT_DIR"
CPPFLAGS=(-nostdinc -undef -D__DTS__ -x assembler-with-cpp
          -I "$KERNEL_DIR/include"
          -I "$KERNEL_DIR/arch/arm64/boot/dts"
          -I "$KERNEL_DIR/arch/arm64/boot/dts/rockchip"
          -I "$KERNEL_DIR/scripts/dtc/include-prefixes")

shopt -s nullglob
DTS_FILES=("$DTS_SRC"/*.dts)
shopt -u nullglob
[ "${#DTS_FILES[@]}" -gt 0 ] || die "$DTS_SRC 下没有 .dts"

for dts in "${DTS_FILES[@]}"; do
    name="$(basename "$dts" .dts)"
    pre="$WORK_DIR/.$name.pre.dts"
    out="$OUT_DIR/$name.dtb"
    log "编译 $name.dtb"
    cpp "${CPPFLAGS[@]}" -o "$pre" "$dts"
    dtc -q -I dts -O dtb -o "$out" "$pre"
    rm -f "$pre"
    printf '  %s  %s B  md5 %s\n' "$out" "$(stat -c %s "$out")" \
        "$(md5sum "$out" | cut -d' ' -f1)"
done

log "dtb 产物目录: $OUT_DIR"
