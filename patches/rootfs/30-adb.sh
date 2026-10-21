#!/usr/bin/env bash
# 30-adb.sh —— 给 fnOS 装上 Linux 版 adb / adbd（方便调试）
#
# Debian 12 arm64 的包：android-tools-adb（含 adb），可选的 android-tools-adbd。
# 本脚本用 qemu-aarch64-static + chroot 在构建机上装（需要 root）。
#
# 用法: 30-adb.sh <rootfs-dir>
set -euo pipefail

ROOTFS="${1:?usage: $0 <rootfs-dir>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../scripts/lib-chroot.sh"

# 没有 qemu 就跳过（GitHub Actions 上有；本地没装时先构建出系统，后续再补）
if [ ! -x "$QEMU_BIN" ]; then
    echo "[30-adb] WARN: 未找到 $QEMU_BIN，跳过 adb 安装（apt install qemu-user-static 后可重跑）"
    exit 0
fi

chroot_mount "$ROOTFS"
trap 'chroot_umount "$ROOTFS"' EXIT

chroot_run "$ROOTFS" /bin/bash -c '
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
# adb 客户端 + adbd 服务端（不同 Debian 版本包名略有差异，逐个兜底）
apt-get install -y --no-install-recommends android-tools-adb || \
    apt-get install -y --no-install-recommends adb
apt-get install -y --no-install-recommends android-tools-adbd || true
command -v adb && adb version || echo "[30-adb] WARN: adb 未安装成功"
command -v adbd && echo "[30-adb] adbd 可用" || true
'

# adbd 服务默认不自动启动（避免和 USB gadget 冲突时反复重启），
# 需要 adb 调试时手动: systemctl start adbd
if [ -f "$ROOTFS/lib/systemd/system/adbd.service" ] || [ -f "$ROOTFS/usr/lib/systemd/system/adbd.service" ]; then
    mkdir -p "$ROOTFS/etc/systemd/system/multi-user.target.wants"
    ln -sf /lib/systemd/system/adbd.service \
        "$ROOTFS/etc/systemd/system/multi-user.target.wants/adbd.service" 2>/dev/null || true
    echo "[30-adb] adbd.service 已设为自启"
fi

echo "[30-adb] 完成"
