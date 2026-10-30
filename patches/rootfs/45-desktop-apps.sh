#!/bin/bash
# ============================================================================
# 45-desktop-apps.sh - 桌面应用适配（Chromium / mpv / fnOS 管理入口）
#
# 1. Chromium：root 用户运行必须 --no-sandbox（否则点了无反应）
# 2. VLC：二进制硬编码拒绝 root（"VLC is not supposed to be run as root"），
#    无法绕过 ⇒ 装 mpv 作为默认播放器
# 3. fnOS 管理界面是 Web UI（nginx 80 端口 302 跳转），桌面加一个快捷方式
# ============================================================================
set -e

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../../scripts/lib-common.sh"

[ -n "$ROOTFS" ] || die "ROOTFS 未设置"
[ -d "$ROOTFS" ] || die "rootfs 不存在: $ROOTFS"

# ---------- 1. Chromium root 沙箱 ----------
mkdir -p "$ROOTFS/etc/chromium.d"
cat > "$ROOTFS/etc/chromium.d/root-sandbox" << 'CHROME'
# root 用户运行 Chromium 必须关闭沙箱，否则启动失败
export CHROMIUM_FLAGS="$CHROMIUM_FLAGS --no-sandbox"
CHROME

if [ -f "$ROOTFS/usr/share/applications/chromium.desktop" ]; then
    sed -i 's|^Exec=/usr/bin/chromium %U$|Exec=/usr/bin/chromium --no-sandbox %U|' \
        "$ROOTFS/usr/share/applications/chromium.desktop" || true
    log "[45-desktop] chromium.desktop Exec 已加 --no-sandbox"
fi

# ---------- 2. mpv 作为默认播放器 ----------
cat > "$ROOTFS/usr/share/applications/mpv.desktop" << 'MPVDESK'
[Desktop Entry]
Type=Application
Name=mpv Media Player
Comment=Play movies and songs
Exec=mpv --player-operation-mode=pseudo-gui -- %U
Terminal=false
Icon=mpv
Categories=AudioVideo;Video;Audio;Player;
MimeType=video/mp4;video/x-matroska;video/quicktime;video/webm;audio/mpeg;audio/flac;audio/ogg;audio/wav;audio/x-wav;audio/mp4;video/x-msvideo;
MPVDESK
chmod +x "$ROOTFS/usr/share/applications/mpv.desktop"

# ---------- 3. fnOS 管理界面快捷方式 ----------
mkdir -p "$ROOTFS/root/桌面" "$ROOTFS/usr/share/applications"
cat > "$ROOTFS/usr/share/applications/fnos-manager.desktop" << 'FNOS'
[Desktop Entry]
Type=Application
Name=fnOS 管理界面
Comment=打开飞牛 NAS 管理后台（Web UI）
Exec=/usr/bin/chromium --no-sandbox http://localhost
Icon=chromium
Terminal=false
Categories=System;
FNOS
chmod +x "$ROOTFS/usr/share/applications/fnos-manager.desktop"
# 入口放三处：
#  1) /usr/share/applications —— 所有用户的应用菜单里都能看到
#  2) /etc/skel/Desktop + /etc/skel/桌面 —— 向导新建的管理员用户登录 XFCE 后桌面就有图标
#     （XFCE 中文环境的桌面目录是「桌面」，英文是 Desktop，两个都放）
#  3) /root/桌面 —— root 桌面
mkdir -p "$ROOTFS/etc/skel/Desktop" "$ROOTFS/etc/skel/桌面" "$ROOTFS/root/桌面"
for d in "$ROOTFS/etc/skel/Desktop" "$ROOTFS/etc/skel/桌面" "$ROOTFS/root/桌面"; do
    cp "$ROOTFS/usr/share/applications/fnos-manager.desktop" "$d/fnOS管理.desktop"
    chmod +x "$d/fnOS管理.desktop"
done

log "[45-desktop] Chromium --no-sandbox / mpv / fnOS 管理入口 已配置"
