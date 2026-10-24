#!/usr/bin/env bash
# 32-serial-autologin.sh —— 调试串口 ttyS2 自动登录
#
# 串口是这块板唯一的本地调试口（1500000 8N1）。给 serial-getty@ttyS2
# 加 --autologin root 免密码进 shell，便于现场排障（登录后自己改回即可）。
#
# 用法: 32-serial-autologin.sh <rootfs-dir>
set -euo pipefail
ROOTFS="${1:?usage: $0 <rootfs-dir>}"

mkdir -p "$ROOTFS/etc/systemd/system/serial-getty@ttyS2.service.d"
cat > "$ROOTFS/etc/systemd/system/serial-getty@ttyS2.service.d/autologin.conf" <<'CONF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --keep-baud 1500000,115200,57600,38400,9600 %I $TERM
CONF

echo "  已配置 serial-getty@ttyS2 自动登录 root"
