#!/usr/bin/env bash
# =====================================================================
#  scripts/build-uboot-upstream.sh
#  构建上游 u-boot（v2026.10）用于 zeroT1(Shimeta AIOT-3588A)
#
#  用法:
#    bash scripts/build-uboot-upstream.sh [源码目录]
#  环境变量:
#    UB_SRC_URL   源码 tarball URL（默认 GitHub archive v2026.10）
#    BL31         BL31 路径（默认 assets/rkbin 官方 v1.56）
#    ROCKCHIP_TPL DDR TPL（默认 assets/rkbin 官方 2112MHz/2400MHz v1.24）
#    CROSS_COMPILE aarch64 交叉编译器前缀（默认 Android prebuilts gcc10.2）
#    UB_BUILD_DIR 源码/构建目录（默认 $WORK_DIR/u-boot-v2026.10）
#
#  产物:
#    assets/uboot-upstream/{idbloader.img,u-boot.itb,u-boot-rockchip.bin,MD5SUMS}
#
#  说明:
#   - 我们新增 (1) configs/zerot1-rk3588_defconfig  (2) 板级 dts
#     dts/upstream/src/arm64/rockchip/rk3588-aiot3588a.dts
#     (3) arch/arm/dts/rk3588-aiot3588a-u-boot.dtsi
#     三者源文件放在 assets/uboot-upstream/src/，每次构建前覆盖进源码树。
#   - 本机没有 swig，pylibfdt 用系统 python-libfdt 代替（若系统有）；
#     binman 需要 pyelftools（pip install --user pyelftools）。
# =====================================================================
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib-common.sh"

UB_VER="${UB_VER:-v2026.10}"
UB_SRC_URL="${UB_SRC_URL:-https://github.com/u-boot/u-boot/archive/refs/tags/${UB_VER}.tar.gz}"
UB_BUILD_DIR="${UB_BUILD_DIR:-$WORK_DIR/u-boot-${UB_VER#v}}"
BL31="${BL31:-$HERE/../assets/rkbin/bin/rk35/rk3588_bl31_v1.56.elf}"
ROCKCHIP_TPL="${ROCKCHIP_TPL:-$HERE/../assets/rkbin/bin/rk35/rk3588_ddr_lp4_2112MHz_lp5_2400MHz_v1.24.bin}"
# 交叉编译器：优先 CROSS_COMPILE 环境变量 → 系统 aarch64-linux-gnu- → Android prebuilts gcc10.2
if [ -z "${CROSS_COMPILE:-}" ]; then
    if command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
        CROSS_COMPILE="aarch64-linux-gnu-"
    elif [ -x "/home/zero/work/rk35xx-android14/prebuilts/gcc/linux-x86/aarch64/gcc-arm-10.2-2020.11-x86_64-aarch64-none-linux-gnu/bin/aarch64-none-linux-gnu-gcc" ]; then
        CROSS_COMPILE="/home/zero/work/rk35xx-android14/prebuilts/gcc/linux-x86/aarch64/gcc-arm-10.2-2020.11-x86_64-aarch64-none-linux-gnu/bin/aarch64-none-linux-gnu-"
    else
        die "找不到 aarch64 交叉编译器，请设置 CROSS_COMPILE"
    fi
fi
export CROSS_COMPILE
SRC_DIR="$HERE/../assets/uboot-upstream/src"
OUT_DIR="$HERE/../assets/uboot-upstream"

log "u-boot 源码: $UB_BUILD_DIR (${UB_VER})"
if [ ! -f "$UB_BUILD_DIR/Makefile" ]; then
    mkdir -p "$WORK_DIR"
    tarball="$WORK_DIR/u-boot-${UB_VER}.tar.gz"
    [ -f "$tarball" ] || { log "下载 $UB_SRC_URL"; curl -L --retry 3 -o "$tarball" "$UB_SRC_URL"; }
    log "解压 $tarball"
    tar -xzf "$tarball" -C "$WORK_DIR"
    got="$WORK_DIR/u-boot-${UB_VER#v}"
    [ -d "$got" ] || die "解压后目录不存在: $got"
    [ "$got" = "$UB_BUILD_DIR" ] || mv "$got" "$UB_BUILD_DIR"
fi

# pylibfdt 无 swig 的兜底（仅当系统有 python-libfdt 时）
if ! command -v swig >/dev/null 2>&1; then
    mk="$(ls /usr/lib/python3*/site-packages/libfdt.py 2>/dev/null | head -1 || true)"
    so="$(ls /usr/lib/python3*/site-packages/_libfdt*.so 2>/dev/null | head -1 || true)"
    if [ -n "$mk" ] && [ -n "$so" ]; then
        log "无 swig，使用系统 pylibfdt 代替"
        python3 - "$UB_BUILD_DIR" <<'PY'
import pathlib,sys
root=pathlib.Path(sys.argv[1]); p=root/'scripts/dtc/pylibfdt/Makefile'
s=p.read_text()
if '[zt1 hack]' not in s:
    start=s.index('rebuild:')
    end=s.index('$(obj)/_libfdt.so $(obj)/libfdt.py &: rebuild')
    new='''[zt1 hack] 本机无 swig：用系统 python-libfdt 模块
rebuild: $(src)/setup.py $(PYLIBFDT_srcs) FORCE
\t@cp -f $(firstword $(wildcard /usr/lib/python3*/site-packages/libfdt.py)) $(obj)/libfdt.py && \\
\t cp -f $(firstword $(wildcard /usr/lib/python3*/site-packages/_libfdt*.so)) $(obj)/_libfdt.so && \\
\t echo "[zt1 hack] 使用系统 pylibfdt"

'''.replace('\\t','\t')
    s=s[:start]+new+s[end:]
    p.write_text(s)
PY
    else
        warn "无 swig 且无系统 pylibfdt：pylibfdt 编译可能失败（请安装 swig）"
    fi
fi

python3 -c "import elftools" 2>/dev/null || warn "缺少 pyelftools（binman 需要）：python3 -m pip install --user pyelftools"

# 覆盖我们新增的 board/defconfig 文件
mkdir -p "$UB_BUILD_DIR/dts/upstream/src/arm64/rockchip"
cp -f "$SRC_DIR/zerot1-rk3588_defconfig" "$UB_BUILD_DIR/configs/"
cp -f "$SRC_DIR/rk3588-aiot3588a.dts" "$UB_BUILD_DIR/dts/upstream/src/arm64/rockchip/"
cp -f "$SRC_DIR/rk3588-aiot3588a-u-boot.dtsi" "$UB_BUILD_DIR/arch/arm/dts/"

# 补丁：bootflow scan 默认只扫 legacy-bootable 分区，Rockchip parameter 生成的 GPT
# 没有该标记，会导致 boot 分区被跳过（scan 出 0 bootflows）
for pf in "$SRC_DIR"/*.patch; do
    [ -f "$pf" ] || continue
    if grep -q "zt1: Rockchip parameter 生成的 GPT" "$UB_BUILD_DIR/cmd/bootflow.c" 2>/dev/null; then
        log "bootflow 补丁已存在，跳过: $(basename "$pf")"
    else
        log "应用补丁: $(basename "$pf")"
        patch -p1 -d "$UB_BUILD_DIR" < "$pf"
    fi
done

[ -f "$BL31" ] || die "缺少 BL31: $BL31"
[ -f "$ROCKCHIP_TPL" ] || die "缺少 ROCKCHIP_TPL: $ROCKCHIP_TPL"
export BL31 ROCKCHIP_TPL

log "构建 u-boot（zerot1-rk3588_defconfig, CROSS_COMPILE=$(basename "$CROSS_COMPILE")）"
make -C "$UB_BUILD_DIR" ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" zerot1-rk3588_defconfig
make -C "$UB_BUILD_DIR" ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" -j"$(nproc)"

mkdir -p "$OUT_DIR"
for f in idbloader.img u-boot.itb u-boot-rockchip.bin; do
    cp -f "$UB_BUILD_DIR/$f" "$OUT_DIR/$f"
done
( cd "$OUT_DIR" && md5sum idbloader.img u-boot.itb u-boot-rockchip.bin > MD5SUMS )
log "u-boot 产物已更新到 $OUT_DIR"

# 生成 upgrade_tool uf 可用的 LDR loader（flash 段 == idbloader.img）
log "生成 LDR loader（assets/uboot-upstream/MiniLoaderAll.bin）"
bash "$(dirname "${BASH_SOURCE[0]}")/make-ldr-loader.sh" "$UB_BUILD_DIR/spl/u-boot-spl.bin" "$OUT_DIR/MiniLoaderAll.bin" "$OUT_DIR/idbloader.img"
( cd "$OUT_DIR" && md5sum idbloader.img u-boot.itb u-boot-rockchip.bin MiniLoaderAll.bin > MD5SUMS )
ls -l "$OUT_DIR"
