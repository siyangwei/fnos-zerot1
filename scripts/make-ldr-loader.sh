#!/bin/bash
# 生成 Rockchip LDR 格式的 MiniLoaderAll.bin（供 upgrade_tool uf 整包刷写的 loader 槽使用）
#
# 背景（2026-11-09 实证）：
#   - `uf` 的 loader 槽必须是 "LDR " 容器；用 boot_merger 的 `pack -1/-2/-3` 直接拼，
#     会产出 "BOOT" 魔术的容器（download boot 阶段失败）。
#   - 正确做法是走厂商 ini 流水线：NEWIDB=true + CODE471=DDR + CODE472=usbplug +
#     LOADER=ddr/spl，boot_merger 会生成 "LDR " 容器并把 FlashHead(RKNS 头) 自动生成。
#
# 输入：
#   SPL   = 上游 u-boot 的 spl/u-boot-spl.bin（binman 产出的 SPL）
#   DDR   = rk3588_ddr_lp4_2112MHz_lp5_2400MHz_v1.24.bin（官方 rockchip-linux/rkbin master）
#   USBPLUG = rk3588_usbplug_v1.11.bin（rkbin）
#
# 用法：
#   bash scripts/make-ldr-loader.sh [spl.bin] [输出文件] [idbloader.img]
#   - 第 3 个参数（idbloader.img）用于强校验：LDR 的 flash 段
#     （FlashHead+FlashData+FlashBoot）截断后必须与 idbloader.img 逐字节一致
set -euo pipefail

TOPDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${WORK_DIR:-$TOPDIR/work}"
UBOOT_SRC_DIR="${UBOOT_SRC_DIR:-$WORK_DIR/u-boot-2026.10}"
RKBIN="${RKBIN:-$TOPDIR/assets/rkbin/bin/rk35}"

SPL="${1:-$UBOOT_SRC_DIR/spl/u-boot-spl.bin}"
OUT="${2:-$TOPDIR/assets/uboot-upstream/MiniLoaderAll.bin}"
IDB="${3:-}"
DDR="${DDR:-$RKBIN/rk3588_ddr_lp4_2112MHz_lp5_2400MHz_v1.24.bin}"
USBPLUG="${USBPLUG:-$RKBIN/rk3588_usbplug_v1.11.bin}"
BOOT_MERGER="${BOOT_MERGER:-$TOPDIR/assets/tools/boot_merger}"

log() { echo -e "\033[1;32m[ldr]\033[0m $*"; }
die() { echo -e "\033[1;31m[ldr] ERROR:\033[0m $*" >&2; exit 1; }

[[ -f $SPL ]]      || die "缺少 SPL: $SPL（先跑 scripts/build-uboot-upstream.sh）"
[[ -f $DDR ]]      || die "缺少 DDR 固件: $DDR"
[[ -f $USBPLUG ]]  || die "缺少 usbplug: $USBPLUG"
[[ -x $BOOT_MERGER ]] || die "缺少 boot_merger: $BOOT_MERGER"

TMP=$(mktemp -d /tmp/zt1-ldr-XXXXXX)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin/rk35"
cp "$DDR" "$TMP/bin/rk35/ddr.bin"
cp "$USBPLUG" "$TMP/bin/rk35/usbplug.bin"
cp "$SPL" "$TMP/bin/rk35/u-boot-spl.bin"

cat > "$TMP/RK3588MINIALL.ini" <<'EOF'
[CHIP_NAME]
NAME=RK3588
[VERSION]
MAJOR=1
MINOR=11
[CODE471_OPTION]
NUM=1
Path1=bin/rk35/ddr.bin
Sleep=1
[CODE472_OPTION]
NUM=1
Path1=bin/rk35/usbplug.bin
[LOADER_OPTION]
NUM=2
LOADER1=FlashData
LOADER2=FlashBoot
FlashData=bin/rk35/ddr.bin
FlashBoot=bin/rk35/u-boot-spl.bin
[OUTPUT]
PATH=MiniLoaderAll.bin
[SYSTEM]
NEWIDB=true
[FLAG]
471_RC4_OFF=true
RC4_OFF=true
EOF

log "用厂商 ini 流水线生成 LDR（NEWIDB=true，DDR + 上游 SPL）"
( cd "$TMP" && "$BOOT_MERGER" RK3588MINIALL.ini >/dev/null )
[[ -f "$TMP/MiniLoaderAll.bin" ]] || die "boot_merger 未产出 MiniLoaderAll.bin"

# 结构校验：magic 必须是 "LDR "，且 unpack 出来的 FlashData/FlashBoot 等于输入
python3 - "$TMP/MiniLoaderAll.bin" "$TMP" <<'PY'
import pathlib, sys
p, tmp = sys.argv[1], sys.argv[2]
d = pathlib.Path(p).read_bytes()
if d[:4] != b'LDR ':
    sys.exit('生成物 magic 不是 LDR: %r' % d[:4])
print('  LDR magic ok, size=%d' % len(d))
PY
mkdir -p "$TMP/verify"
"$BOOT_MERGER" unpack -i "$TMP/MiniLoaderAll.bin" -o "$TMP/verify" >/dev/null 2>&1 || true
[[ -f "$TMP/verify/FlashBoot.bin" ]] || die "LDR 里没有 FlashBoot 段"
# boot_merger 会把载入的段按扇区补齐，故先比对真实长度部分
cmp -n "$(stat -c %s "$DDR")" "$TMP/verify/FlashData.bin" "$DDR" || die "FlashData 与 DDR 内容不一致"
cmp -n "$(stat -c %s "$SPL")" "$TMP/verify/FlashBoot.bin" "$SPL" || die "FlashBoot 与 SPL 内容不一致（请确认第 1 个参数是 spl/u-boot-spl.bin，而不是 idbloader.img）"
log "校验通过：FlashData==DDR(前 $(stat -c %s "$DDR")B)，FlashBoot==SPL(前 $(stat -c %s "$SPL")B)"

# 说明：不再与 binman 的 idbloader.img 做逐字节比对 —— binman 的 rksd 会在 SPL 数据区
# 末尾追加 "BSYM" 调试符号表（mkimage -T rksd 的附加物），而 make.sh/kernel 的 loader
# 直接用裸 spl/u-boot-spl.bin，两者数据区必然不同（已实证：上板可正常引导）。
# 这里只做“loader 结构必须正确”的校验：
#   - LDR magic 必须是 "LDR "
#   - 解包出来的 FlashData 前缀 == DDR 文件、FlashBoot 前缀 == SPL 文件
#   - FlashData/FlashBoot 长度必须等于 512B 对齐后的长度
python3 - "$TMP/MiniLoaderAll.bin" "$TMP/verify/FlashData.bin" "$TMP/verify/FlashBoot.bin" "$DDR" "$SPL" <<'PYCHECK'
import sys, os
ldr, fd, fb, ddr, spl = sys.argv[1:6]
def pad512(n): return (n + 511) // 512 * 512
d = open(ldr,'rb').read()
assert d[:4] == b'LDR ', 'magic 不是 LDR: %r' % d[:4]
fd_d, fb_d, ddr_d, spl_d = (open(x,'rb').read() for x in (fd, fb, ddr, spl))
assert len(fd_d) == pad512(len(ddr_d)), 'FlashData 长度 %d != 512 对齐 DDR %d' % (len(fd_d), pad512(len(ddr_d)))
assert len(fb_d) == pad512(len(spl_d)), 'FlashBoot 长度 %d != 512 对齐 SPL %d' % (len(fb_d), pad512(len(spl_d)))
assert fd_d[:len(ddr_d)] == ddr_d, 'FlashData 内容与 DDR 不一致'
assert fb_d[:len(spl_d)] == spl_d, 'FlashBoot 内容与 SPL 不一致'
print('  structure ok: FlashData=%d B (DDR %d), FlashBoot=%d B (SPL %d)' % (len(fd_d), len(ddr_d), len(fb_d), len(spl_d)))
PYCHECK
log "校验通过（结构 + 内容前缀）"

mkdir -p "$(dirname "$OUT")"
cp "$TMP/MiniLoaderAll.bin" "$OUT"
log "生成完成: $OUT ($(stat -c %s "$OUT") 字节, md5 $(md5sum "$OUT" | awk '{print $1}'))"
