#!/usr/bin/env bash
# 60-desktop-apps.sh —— XFCE 桌面常用图形应用
#
# 补齐桌面上"看不见但用户会期待"的应用：
#   network-manager-gnome  → nm-applet（右上角网络图标，可点击连 WiFi/有线）
#   blueman                → blueman-applet（右上角蓝牙图标，可扫描/配对）
#   chromium               → 浏览器（桌面"飞牛管理界面"快捷方式用它打开 Web UI）
#   alsa-utils             → amixer/aplay/speaker-test（声卡调试与状态初始化）
#   x11-xserver-utils      → xrandr/xset 等
#
# 用法: 60-desktop-apps.sh <rootfs-dir>
set -euo pipefail

ROOTFS="${1:?usage: $0 <rootfs-dir>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../scripts/lib-chroot.sh"

if ! command -v qemu-aarch64-static >/dev/null 2>&1 && [ ! -e "$QEMU_BIN" ]; then
    echo "[60-desktop-apps] 未找到 qemu-aarch64-static，跳过（CI 上会自动注册 binfmt）"
    exit 0
fi

chroot_mount "$ROOTFS"
trap 'chroot_umount "$ROOTFS"' EXIT

chroot_run "$ROOTFS" /bin/bash -c '
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq

# 网络 / 蓝牙托盘图标
apt-get install -y --no-install-recommends \
    network-manager-gnome blueman dbus-x11 \
    || echo "[60] WARN: 部分桌面包安装失败"

# 声卡工具（amixer 用于初始化 ES8388 的 spk switch）
apt-get install -y --no-install-recommends alsa-utils x11-xserver-utils \
    || echo "[60] WARN: alsa-utils 安装失败"

# 浏览器（体积较大，失败不致命）
apt-get install -y --no-install-recommends chromium \
    || echo "[60] WARN: chromium 安装失败"

# 视频播放器（45-desktop-apps.sh 写了 mpv.desktop；不装二进制会显示成"感叹号"死图标）
apt-get install -y --no-install-recommends mpv \
    || echo "[60] WARN: mpv 安装失败"

apt-get clean
rm -rf /var/lib/apt/lists/*
'

chroot_umount "$ROOTFS"
trap - EXIT

# 托盘小程序自启动：用 XDG autostart，两个 applet 都在 root 会话里拉起
mkdir -p "$ROOTFS/etc/xdg/autostart"
cat > "$ROOTFS/etc/xdg/autostart/nm-applet.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Network Manager Applet
Exec=nm-applet --sm-disable
Icon=network-workgroup
Terminal=false
Categories=Network;
X-GNOME-Autostart-enabled=true
OnlyShowIn=XFCE;
EOF

cat > "$ROOTFS/etc/xdg/autostart/blueman-applet.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Bluetooth Manager Applet
Exec=blueman-applet
Icon=bluetooth
Terminal=false
Categories=System;
X-GNOME-Autostart-enabled=true
OnlyShowIn=XFCE;
EOF

echo "[60-desktop-apps] 完成: nm-applet / blueman / chromium / alsa-utils + autostart"
