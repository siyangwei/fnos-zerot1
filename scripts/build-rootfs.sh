#!/usr/bin/env bash
# build-rootfs.sh —— 准备 fnOS rootfs：下载底稿镜像 → 解压 → 提取根分区 → 打补丁
#
# 底稿：ophub/fnnas 的 fnnas_rockchip_nanopc-t6_k6.18.18_*.img.gz
#   只用它的 rootfs（Debian 12 + 飞牛 fnOS 服务）；内核/uboot 全部换成友善构建的。
#   ROOTFS 分区位于 GPT 第 2 分区（LBA 1081344，offset = 1081344*512）。
#
# 用法：sudo ./scripts/build-rootfs.sh
#   环境变量 SKIP_FNOS_DOWNLOAD=1 复用已下载/解压的镜像
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib-common.sh"

need_root

BOOT_OFFSET=$((32768 * 512))       # fnOS 底稿 GPT 第 1 分区（boot，ext4，仅供识别）
ROOTFS_OFFSET=$((1081344 * 512))   # fnOS 底稿 GPT 第 2 分区（rootfs，btrfs）

# ---- 1. 下载 + 解压底稿镜像 ----
# 兼容已有的其他命名（比如手动下载的 fnnas_rockchip_nanopc-t6_*.img）
if [ ! -f "$FNOS_IMG" ]; then
    _found="$(ls -1 "$WORK_DIR"/fnnas_rockchip_*.img 2>/dev/null | head -1 || true)"
    if [ -n "$_found" ]; then
        FNOS_IMG="$_found"
        log "复用已有底稿镜像: $FNOS_IMG"
    fi
fi

if [ ! -f "$FNOS_IMG" ]; then
    if [ ! -f "$FNOS_IMG_GZ" ]; then
        [ "${SKIP_FNOS_DOWNLOAD:-0}" = "1" ] && die "SKIP_FNOS_DOWNLOAD=1 但 $FNOS_IMG_GZ 不存在"
        log "下载 fnOS 底稿镜像（1.75GB，GitHub 单连接限速，用 8 线程分段下载）"
        mkdir -p "$(dirname "$FNOS_IMG_GZ")"
        # 分段并行下载：GitHub release 对单连接限速，多段可提速
        total=$(( $(curl -sIL "$FNOS_IMG_URL" | awk 'tolower($1)=="content-length:"{print $2}' | tr -d '\r' | tail -1) ))
        [ -n "$total" ] && [ "$total" -gt 0 ] || total=1838038235
        chunks=8
        seg=$(( (total + chunks - 1) / chunks ))
        tmpdir="$(mktemp -d)"
        for i in $(seq 0 $((chunks-1))); do
            start=$(( i * seg ))
            end=$(( start + seg - 1 ))
            [ "$end" -ge "$total" ] && end=$(( total - 1 ))
            ( curl -sL -r "$start-$end" -o "$tmpdir/part$i" "$FNOS_IMG_URL" ) &
        done
        wait
        cat "$tmpdir"/part* > "$FNOS_IMG_GZ"
        rm -rf "$tmpdir"
        log "下载完成: $(stat -c %s "$FNOS_IMG_GZ") B"
    fi
    log "解压 $(basename "$FNOS_IMG_GZ") ..."
    gunzip -c "$FNOS_IMG_GZ" > "$FNOS_IMG"
fi

# ---- 1.5 可选：跳过提取，直接复用现有 rootfs 只打补丁 ----
if [ "${SKIP_ROOTFS_EXTRACT:-0}" = "1" ] && [ -d "$ROOTFS/etc" ]; then
    log "SKIP_ROOTFS_EXTRACT=1：复用现有 rootfs ($(du -sh "$ROOTFS" | cut -f1))，只应用补丁"
    for s in "$PATCHES_DIR"/rootfs/*.sh; do
        [ -e "$s" ] || continue
        log "应用 rootfs 补丁: $(basename "$s")"
        bash "$s" "$ROOTFS" "$ASSETS_DIR" || warn "补丁失败（继续）: $(basename "$s")"
    done
    log "rootfs 准备完成: $(du -sh "$ROOTFS" | cut -f1)"
    exit 0
fi

# ---- 2. 挂载 rootfs 分区并提取 ----
log "提取 rootfs 分区（offset=$ROOTFS_OFFSET）→ $ROOTFS"
if mountpoint -q "$ROOTFS" 2>/dev/null; then umount "$ROOTFS" 2>/dev/null || true; fi
mkdir -p "$ROOTFS"

_loop="$(losetup -f)"
losetup -o "$ROOTFS_OFFSET" --sizelimit $((6 * 1024 * 1024 * 1024)) "$_loop" "$FNOS_IMG" 2>/dev/null || \
    losetup -o "$ROOTFS_OFFSET" "$_loop" "$FNOS_IMG"
trap 'umount "$ROOTFS" 2>/dev/null || true; losetup -d "$_loop" 2>/dev/null || true' EXIT

mount -t btrfs -o ro "$_loop" "$ROOTFS"
log "rsync 提取（保留属主/ACL/xattr）"
if command -v rsync >/dev/null 2>&1; then
    rsync -aHAX --numeric-ids --info=progress2 "$ROOTFS/" "$ROOTFS.new/" 2>/dev/null || true
else
    die "需要 rsync"
fi
umount "$ROOTFS"
losetup -d "$_loop"
trap - EXIT
rm -rf "$ROOTFS"
mv "$ROOTFS.new" "$ROOTFS"
log "rootfs 提取完成: $(du -sh "$ROOTFS" | cut -f1)"

# ---- 3. 应用 rootfs 补丁（按文件名顺序） ----
for s in "$PATCHES_DIR"/rootfs/*.sh; do
    [ -e "$s" ] || continue
    name="$(basename "$s")"
    case "$name" in
        *qemu*|*chroot*) : ;;  # 占位，避免误执行非补丁脚本
    esac
    log "应用 rootfs 补丁: $name"
    bash "$s" "$ROOTFS" "$ASSETS_DIR" || die "补丁失败: $name"
done

log "rootfs 准备完成: $(du -sh "$ROOTFS" | cut -f1)"
