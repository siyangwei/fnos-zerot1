#!/usr/bin/env bash
# patch-kernel.sh —— 给指定内核源码树打「本板适配」补丁
#
# 设计目标（按用户要求解耦）：
#   · 补丁按内核版本分目录：patches/kernel/<MAJOR.MINOR.PATCH>/
#   · 换内核版本时只需新建对应目录，老版本补丁原样保留
#   · 每个 .patch 只做一件事，可单独增删
#   · files/ 子目录放"新增文件"（如驱动源码），不塞进 .patch
#   · 板级 DTS 放在项目根的 dts/（不是 patch，是新增文件）
#
# 用法:
#   ./scripts/patch-kernel.sh <kernel-src-dir>
#   ./scripts/patch-kernel.sh <kernel-src-dir> --only 0002  # 只打指定编号
#
# 幂等：已应用的 patch 会用 git apply --reverse --check 检测并跳过。
set -euo pipefail

KERNEL_DIR="${1:?usage: $0 <kernel-src-dir> [--only <prefix>]}"
ONLY=""
[ "${2:-}" = "--only" ] && ONLY="${3:?--only 需要前缀，例如 0002}"

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$(cd "$HERE/.." && pwd)"

log() { echo "[patch-kernel] $*"; }
die() { echo "[patch-kernel] ERROR: $*" >&2; exit 1; }

[ -f "$KERNEL_DIR/Makefile" ] || die "$KERNEL_DIR 不是内核源码树"

# 内核版本：优先 make kernelversion（最准），失败再解析 Makefile
KVER="$(make -s -C "$KERNEL_DIR" kernelversion 2>/dev/null || true)"
if [ -z "$KVER" ]; then
    KVER="$(awk '/^VERSION[[:space:]]*=/{v=$3} /^PATCHLEVEL[[:space:]]*=/{p=$3} /^SUBLEVEL[[:space:]]*=/{s=$3} END{printf "%s.%s.%s", v, p, s}' "$KERNEL_DIR/Makefile")"
fi
log "内核版本: $KVER"

PATCH_DIR="$PROJECT/patches/kernel/$KVER"
if [ ! -d "$PATCH_DIR" ]; then
    log "没有针对 $KVER 的补丁目录（$PATCH_DIR），跳过"
    exit 0
fi
log "补丁目录: $PATCH_DIR"

# ---------- 1. files/ 新增文件 ----------
if [ -d "$PATCH_DIR/files" ]; then
    while IFS= read -r rel; do
        [ -z "$rel" ] && continue
        # files/ 内约定：<目标相对路径>（例如 drivers/watchdog/smdt_mcu_wdt.c）
        src="$PATCH_DIR/files/$rel"
        dst="$KERNEL_DIR/$rel"
        mkdir -p "$(dirname "$dst")"
        if cmp -s "$src" "$dst"; then
            log "已存在: $rel"
        else
            cp "$src" "$dst"
            log "拷贝: $rel"
        fi
    done < <(cd "$PATCH_DIR/files" && find . -type f -printf '%P\n' | sort)
fi

# ---------- 2. .patch 补丁 ----------
shopt -s nullglob
for p in "$PATCH_DIR"/*.patch; do
    base="$(basename "$p")"
    if [ -n "$ONLY" ] && [[ "$base" != "$ONLY"* ]]; then
        continue
    fi
    if git -C "$KERNEL_DIR" apply --check "$p" 2>/dev/null; then
        git -C "$KERNEL_DIR" apply "$p"
        log "应用: $base"
    elif git -C "$KERNEL_DIR" apply --reverse --check "$p" 2>/dev/null; then
        log "已应用: $base"
    else
        die "无法应用 $base（内核版本不符或上下文冲突，请检查 $p）"
    fi
done
shopt -u nullglob

# ---------- 3. 板级 DTS（新增文件，不放进 .patch） ----------
DTS_SRC="$PROJECT/dts/rk3588-aiot3588a.dts"
DTS_DIR="$KERNEL_DIR/arch/arm64/boot/dts/rockchip"
if [ -f "$DTS_SRC" ] && [ -d "$DTS_DIR" ]; then
    if cmp -s "$DTS_SRC" "$DTS_DIR/rk3588-aiot3588a.dts"; then
        log "已存在: rk3588-aiot3588a.dts"
    else
        cp "$DTS_SRC" "$DTS_DIR/rk3588-aiot3588a.dts"
        log "拷贝: dts/rk3588-aiot3588a.dts"
    fi
    MK="$DTS_DIR/Makefile"
    if [ -f "$MK" ] && ! grep -q 'rk3588-aiot3588a\.dtb' "$MK"; then
        echo 'dtb-$(CONFIG_ARCH_ROCKCHIP) += rk3588-aiot3588a.dtb' >> "$MK"
        log "注册: rk3588-aiot3588a.dtb → Makefile"
    fi
fi

log "完成（内核 $KVER）"
