#!/usr/bin/env bash
# 90-rootfs-resize.sh —— 关闭 fnOS 首次启动的自动扩容（改用 Web 管理界面扩容）
#
# 背景：飞牛自带 /usr/sbin/fnnas-tf（由 resize-rootfs.service 驱动）会按
#   /etc/fnnas.conf 的 rootfs_limit_gib / rootfs_resize 把根分区扩到指定大小。
#   ophub 出厂镜像默认 rootfs_resize="no"；我们之前的版本把它打开过，
#   但实测它会去动分区表（内核日志报 "Can't have overlapping partitions"），
#   而飞牛的正确做法是：进 Web 管理界面 → 存储空间 里扩容/建存储池。
#   因此这里明确关掉它，并把 service mask 掉，避免开机自动改分区。
#
# 用法: 90-rootfs-resize.sh <rootfs-dir>
set -euo pipefail
ROOTFS="${1:?用法: $0 <rootfs-dir>}"
CONF="$ROOTFS/etc/fnnas.conf"

if [ -f "$CONF" ]; then
    grep -q '^rootfs_resize=' "$CONF" \
        && sed -i 's|^rootfs_resize=.*|rootfs_resize="no"|' "$CONF" \
        || echo 'rootfs_resize="no"' >> "$CONF"
    grep -q '^rootfs_limit_gib=' "$CONF" || echo 'rootfs_limit_gib="16"' >> "$CONF"
else
    printf 'rootfs_limit_gib="16"\nrootfs_resize="no"\n' > "$CONF"
fi

mkdir -p "$ROOTFS/etc/systemd/system"
ln -sf /dev/null "$ROOTFS/etc/systemd/system/resize-rootfs.service"

echo "[90-rootfs-resize] 已关闭自动扩容（rootfs_resize=no，resize-rootfs.service -> /dev/null）"
echo "[90-rootfs-resize] 扩容请进 fnOS Web 管理界面 → 存储空间 操作"
