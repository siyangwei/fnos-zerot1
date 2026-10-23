#!/usr/bin/env bash
# patch-uboot.sh —— 给 u-boot 源码树打「本板适配」补丁
#
# 与 patch-kernel.sh 同构：按 u-boot 版本分目录 patches/uboot/<VERSION>/
# 友善 u-boot 是 2017.09（nanopi6-v2017.09 分支），目录名即 2017.09。
#
# 用法: ./scripts/patch-uboot.sh <uboot-src-dir> [--only <prefix>]
set -euo pipefail

UBOOT_DIR="${1:?usage: $0 <uboot-src-dir> [--only <prefix>]}"
ONLY=""
[ "${2:-}" = "--only" ] && ONLY="${3:?--only 需要前缀}"

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$(cd "$HERE/.." && pwd)"

log() { echo "[patch-uboot] $*"; }
die() { echo "[patch-uboot] ERROR: $*" >&2; exit 1; }

[ -f "$UBOOT_DIR/Makefile" ] || die "$UBOOT_DIR 不是 u-boot 源码树"

# u-boot 2017.09 的 Makefile 是 VERSION=2017 PATCHLEVEL=09 SUBLEVEL=（空）
UVER="$(awk '/^VERSION[[:space:]]*=/{v=$3} /^PATCHLEVEL[[:space:]]*=/{p=$3} /^SUBLEVEL[[:space:]]*=/{s=$3} END{ if (s=="") printf "%s.%s", v, p; else printf "%s.%s.%s", v, p, s }' "$UBOOT_DIR/Makefile")"
log "u-boot 版本: $UVER"

PATCH_DIR="$PROJECT/patches/uboot/$UVER"
if [ ! -d "$PATCH_DIR" ]; then
    log "没有针对 $UVER 的补丁目录（$PATCH_DIR），跳过"
    exit 0
fi

shopt -s nullglob
for p in "$PATCH_DIR"/*.patch; do
    base="$(basename "$p")"
    if [ -n "$ONLY" ] && [[ "$base" != "$ONLY"* ]]; then
        continue
    fi
    if patch -d "$UBOOT_DIR" -p1 --dry-run -f -s < "$p" >/dev/null 2>&1; then
        patch -d "$UBOOT_DIR" -p1 -f -s < "$p"
        log "应用: $base"
    elif patch -d "$UBOOT_DIR" -p1 --dry-run -R -f -s < "$p" >/dev/null 2>&1; then
        log "已应用: $base"
    else
        die "无法应用 $base（u-boot 版本不符或上下文冲突）"
    fi
done
shopt -u nullglob

log "完成（u-boot $UVER）"
