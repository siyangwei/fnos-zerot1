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
#   DDR   = rk3588_ddr_lp4_2112MHz_lp5_2400MHz_v1.20.bin（rkbin）
#   USBPLUG = rk3588_usbplug_v1.11.bin（rkbin）
#
# 用法：
#   bash scripts/make-ldr-loader.sh [spl.bin] [输出文件]
set -euo pipefail

TOPDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${WORK_DIR:-$TOPDIR/work}"
UBOOT_SRC_DIR="${UBOOT_SRC_DIR:-$WORK_DIR/u-boot-2026.10}"
RKBIN="${RKBIN:-$(cd "$TOPDIR/.." && pwd)/uboot-fa/rkbin/bin/rk35}"

SPL="${1:-$UBOOT_SRC_DIR/spl/u-boot-spl.bin}"
OUT="${2:-$TOPDIR/assets/uboot-upstream/MiniLoaderAll.bin}"
DDR="${DDR:-$RKBIN/rk3588_ddr_lp4_2112MHz_lp5_2400MHz_v1.20.bin}"
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
if [[ -f "$TMP/verify/FlashBoot.bin" ]]; then
    # boot_merger 会把载入的段按扇区补齐，故只比对真实长度部分
    cmp -n "$(stat -c %s "$DDR")" "$TMP/verify/FlashData.bin" "$DDR" || die "FlashData 与 DDR 内容不一致"
    cmp -n "$(stat -c %s "$SPL")" "$TMP/verify/FlashBoot.bin" "$SPL" || die "FlashBoot 与 SPL 内容不一致"
    log "校验通过：FlashData==DDR(前 $(stat -c %s "$DDR")B)，FlashBoot==SPL(前 $(stat -c %s "$SPL")B)"
fi

mkdir -p "$(dirname "$OUT")"
cp "$TMP/MiniLoaderAll.bin" "$OUT"
log "生成完成: $OUT ($(stat -c %s "$OUT") 字节, md5 $(md5sum "$OUT" | awk '{print $1}'))"
