#!/bin/bash
# 用上游 u-boot 的 idbloader.img 生成 Rockchip 旧式 LDR "MiniLoaderAll.bin"
#
# 背景：
#   upgrade_tool 的 `uf` 整包刷写只接受 LDR 格式的 loader（写 eMMC 0x40 当引导头）。
#   上游 u-boot 的 idbloader.img 是 `mkimage -T rksd` 生成的 RKNS 格式，直接塞进
#   update.img 会被校验拒绝（Loading loader failed / wrong hash of loader）。
#
# 做法：
#   1) 用 boot_merger unpack 拆开厂商 MiniLoaderAll.bin（LDR 容器），保留其
#      "USB 下载" 部分（UsbHead/rk3588_ddr/usbplug）——这段用于和 MaskROM 通信；
#   2) 把上游 idbloader.img 按 RKNS v2 头拆成 3 段：
#      header(2KB) + image0(ddr 训练固件) + image1(u-boot-spl)，
#      三段的拼接与原 idbloader.img 逐字节一致；
#   3) 用 boot_merger pack 把「厂商 USB 段 + 我们的 flash 三段」重新打成 LDR。
#   LDR 里 "loader entry" 三段会被 upgrade_tool 依次写到 eMMC 0x40，
#   其拼接就是一个完整的上游 idbloader.img，于是重启后直接进上游 SPL。
#
# 用法：
#   sudo bash scripts/make-ldr-loader.sh [idbloader.img] [输出 MiniLoaderAll.bin]
#
# 依赖：assets/tools/boot_merger（Rockchip 静态工具）、assets/MiniLoaderAll.bin（厂商模板）
set -euo pipefail

TOPDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IDB="${1:-$TOPDIR/assets/uboot-upstream/idbloader.img}"
OUT="${2:-$TOPDIR/assets/uboot-upstream/MiniLoaderAll.bin}"
TEMPLATE="${LDR_TEMPLATE:-$TOPDIR/assets/MiniLoaderAll.bin}"
BOOT_MERGER="${BOOT_MERGER:-$TOPDIR/assets/tools/boot_merger}"

log() { echo -e "\033[1;32m[ldr]\033[0m $*"; }
die() { echo -e "\033[1;31m[ldr] ERROR:\033[0m $*" >&2; exit 1; }

[[ -f $IDB ]]      || die "缺少 idbloader.img: $IDB（先跑 scripts/build-uboot-upstream.sh）"
[[ -f $TEMPLATE ]] || die "缺少厂商 LDR 模板: $TEMPLATE"
[[ -x $BOOT_MERGER ]] || die "缺少 boot_merger: $BOOT_MERGER"

TMP=$(mktemp -d /tmp/zt1-ldr-XXXXXX)
trap 'rm -rf "$TMP"' EXIT

log "拆开厂商 LDR 模板: $TEMPLATE"
mkdir -p "$TMP/vendor"
"$BOOT_MERGER" unpack -i "$TEMPLATE" -o "$TMP/vendor" >/dev/null
for f in UsbHead.bin rk3588_ddr_lp4_2112.bin rk3588_usbplug_v1.bin; do
    [[ -f "$TMP/vendor/$f" ]] || die "厂商 LDR 里缺少 $f（模板不是 RK3588 的？）"
done

log "按 RKNS v2 头拆分上游 idbloader: $IDB"
python3 - "$IDB" "$TMP" <<'PY'
import struct, sys
idb_path, outdir = sys.argv[1], sys.argv[2]
data = open(idb_path, 'rb').read()
magic = struct.unpack('<I', data[0:4])[0]
if magic != 0x534E4B52:
    sys.exit("idbloader magic 不是 RKNS v2: %08x" % magic)
size_and_nimage, boot_flag = struct.unpack('<II', data[8:16])
nimage = size_and_nimage >> 16
if nimage < 2:
    sys.exit("idbloader 只有 %d 个镜像，RK3588 需要 2 个（ddr + spl）" % nimage)
entry_sz = []
entry_off = []
for i in range(nimage):
    off = 0x78 + i * 88
    so, addr = struct.unpack('<II', data[off:off + 8])
    entry_off.append((so & 0xffff) * 512)
    entry_sz.append((so >> 16) * 512)
total_end = entry_off[-1] + entry_sz[-1]
if total_end != len(data):
    sys.exit("idbloader 解析结果 (%d) 与文件大小 (%d) 不一致" % (total_end, len(data)))
open(outdir + '/FlashHead.bin', 'wb').write(data[:2048])
open(outdir + '/FlashData.bin', 'wb').write(data[entry_off[0]:entry_off[0] + entry_sz[0]])
open(outdir + '/FlashBoot.bin', 'wb').write(data[entry_off[1]:entry_off[1] + entry_sz[1]])
print("  header=2048 image0=%d@%d image1=%d@%d" % (entry_sz[0], entry_off[0], entry_sz[1], entry_off[1]))
PY

log "重新打包 LDR（厂商 USB 段 + 我们的 flash 三段）"
mkdir -p "$TMP/pack"
cp "$TMP/vendor/UsbHead.bin" "$TMP/vendor/rk3588_ddr_lp4_2112.bin" \
   "$TMP/vendor/rk3588_usbplug_v1.bin" "$TMP/pack/"
cp "$TMP/FlashHead.bin" "$TMP/FlashData.bin" "$TMP/FlashBoot.bin" "$TMP/pack/"
"$BOOT_MERGER" pack -c -RK3588 -v 05.01 \
    -1 "$TMP/pack/UsbHead.bin" \
    -1 "$TMP/pack/rk3588_ddr_lp4_2112.bin" \
    -2 "$TMP/pack/rk3588_usbplug_v1.bin" \
    -3 "$TMP/pack/FlashHead.bin" \
    -3 "$TMP/pack/FlashData.bin" \
    -3 "$TMP/pack/FlashBoot.bin" \
    -o "$OUT" >/dev/null

# 回读校验：LDR 的 flash 三段拼起来必须等于原 idbloader.img
mkdir -p "$TMP/verify"
"$BOOT_MERGER" unpack -i "$OUT" -o "$TMP/verify" >/dev/null
cat "$TMP/verify/FlashHead.bin" "$TMP/verify/FlashData.bin" "$TMP/verify/FlashBoot.bin" \
    | sha256sum | awk '{print $1}' > "$TMP/a"
sha256sum "$IDB" | awk '{print $1}' > "$TMP/b"
if ! cmp -s "$TMP/a" "$TMP/b"; then
    die "生成校验失败：LDR flash 段拼接与 idbloader.img 不一致"
fi

log "生成完成: $OUT ($(stat -c %s "$OUT") 字节, md5 $(md5sum "$OUT" | awk '{print $1}'))"
log "已校验：LDR 写盘内容 == idbloader.img ($(md5sum "$IDB" | awk '{print $1}'))"
