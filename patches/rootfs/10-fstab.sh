#!/usr/bin/env bash
# 10-fstab.sh —— 修正 fnOS rootfs 的 /etc/fstab
#
# 背景：fnOS 官方 nanopc-t6 镜像的 fstab 里有一行
#   UUID=3b489e95-... /boot ext4 ...
# 本项目 boot 分区改成 FAT32（由 u-boot 读 extlinux.conf），
# 内核运行时不需要挂载 /boot，所以删掉该行，避免 systemd 启动时
# 等待一个不存在的 ext4 分区（90s 超时 / degraded）。
#
# 用法: 10-fstab.sh <rootfs-dir>
set -euo pipefail

ROOTFS="${1:?usage: $0 <rootfs-dir>}"
FSTAB="$ROOTFS/etc/fstab"

[ -f "$FSTAB" ] || { echo "[10-fstab] ERROR: $FSTAB 不存在"; exit 1; }

# 备份一次（幂等）
[ -f "$FSTAB.orig" ] || cp "$FSTAB" "$FSTAB.orig"

# 删除 /boot 挂载行
sed -i -E '/^[^#].*[[:space:]]\/boot[[:space:]]/d' "$FSTAB"

# 兜底：确保根分区行存在
if ! grep -q '^[^#].*[[:space:]]/[[:space:]]' "$FSTAB"; then
    echo 'UUID=357e9eb7-73ea-4367-b981-6296a97687e0 / btrfs defaults,noatime,compress=zstd:1 0 1' >> "$FSTAB"
fi

echo "[10-fstab] 完成，当前生效内容:"
grep -vE '^\s*#' "$FSTAB" | grep -vE '^\s*$'
