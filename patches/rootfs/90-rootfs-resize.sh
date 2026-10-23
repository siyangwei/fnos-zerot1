#!/usr/bin/env bash
# 90-rootfs-resize.sh —— 让 fnOS 首次启动时把 rootfs 扩到 16GiB
#
# 背景：飞牛自带 /usr/sbin/fnnas-tf 在首次启动时按 /etc/fnnas.conf 的
#   rootfs_limit_gib（上限）与 rootfs_resize（是否扩容）来扩分区。
#   出厂的 nanopc-t6 镜像里 rootfs_resize="no"，导致板子上根分区永远是 5.5G。
#
# 本脚本把两个值改成：
#   rootfs_limit_gib="16"   ← 扩到 16GiB（eMMC 59G 够用；剩余留给飞牛建存储池）
#   rootfs_resize="yes"
#
# 配套改动在 scripts/pack-image.sh：parameter.txt 不再划 userdata 分区，
# 让 rootfs 后面是空闲空间，fnnas-tf 才有地方扩。
#
# 用法: 90-rootfs-resize.sh <rootfs-dir>
set -euo pipefail

ROOTFS="${1:?usage: $0 <rootfs-dir>}"
CONF="$ROOTFS/etc/fnnas.conf"

if [ ! -f "$CONF" ]; then
    echo "[90-rootfs-resize] WARN: $CONF 不存在（跳过）"
    exit 0
fi

# 用 sed 就地替换（保留其它配置项）
sed -i 's/^rootfs_limit_gib=.*/rootfs_limit_gib="16"/' "$CONF"
sed -i 's/^rootfs_resize=.*/rootfs_resize="yes"/' "$CONF"

echo "[90-rootfs-resize] 完成:"
grep -E '^rootfs_(limit_gib|resize)=' "$CONF" | sed 's/^/    /'
