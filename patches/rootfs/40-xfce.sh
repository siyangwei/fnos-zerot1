#!/usr/bin/env bash
# 40-xfce.sh —— 给 fnOS 安装 XFCE 桌面（eDP 本地显示 + 可选 XRDP 远程）
#
# 参考 https://github.com/zhangyada/fnos-elf3588 的
# scripts/vendor/FnOS_Install_Desktop.sh，做成本项目可复用的 chroot 脚本。
#
# 用法: 40-xfce.sh <rootfs-dir> [--xrdp]
set -euo pipefail

ROOTFS="${1:?usage: $0 <rootfs-dir> [--xrdp]}"
WITH_XRDP="${2:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../scripts/lib-chroot.sh"

# 没有 qemu 就跳过（GitHub Actions 上有 qemu-user-static）
if [ ! -x "$QEMU_BIN" ]; then
    echo "[40-xfce] WARN: 未找到 $QEMU_BIN，跳过 XFCE 安装"
    exit 0
fi

chroot_mount "$ROOTFS"
trap 'chroot_umount "$ROOTFS"' EXIT

chroot_run "$ROOTFS" /bin/bash -c '
set -e
export DEBIAN_FRONTEND=noninteractive

apt-get update -qq

# 中文环境
apt-get install -y --no-install-recommends locales fonts-noto-cjk fonts-wqy-zenhei
sed -i "s/^# *zh_CN.UTF-8 UTF-8/zh_CN.UTF-8 UTF-8/" /etc/locale.gen
locale-gen
update-locale LANG=zh_CN.UTF-8

# X + XFCE 本体
apt-get install -y --no-install-recommends \
    xorg xserver-xorg-video-fbdev xserver-xorg-video-modesetting \
    xserver-xorg-input-libinput \
    dbus-x11 dbus-user-session policykit-1 \
    xfce4 xfce4-session xfce4-terminal xfce4-panel xfce4-settings \
    xfwm4 xfdesktop4 xfce4-power-manager \
    lightdm lightdm-gtk-greeter
' || echo "[40-xfce] WARN: 部分包安装失败（检查网络/源）"

if [ "$WITH_XRDP" = "--xrdp" ]; then
    chroot_run "$ROOTFS" /bin/bash -c '
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y --no-install-recommends xrdp xorgxrdp
    systemctl enable xrdp || true
    ' || echo "[40-xfce] WARN: xrdp 安装失败"
fi

# ---- lightdm 自动登录 root，进入 XFCE ----
mkdir -p "$ROOTFS/etc/lightdm/lightdm.conf.d"
cat > "$ROOTFS/etc/lightdm/lightdm.conf.d/50-autologin.conf" <<'EOF'
[Seat:*]
autologin-user=root
autologin-user-timeout=0
user-session=xfce
greeter-session=lightdm-gtk-greeter
EOF

# 修复 Debian lightdm PAM 默认禁止 root 自动登录（否则 autologin root 会失败）
if [ -f "$ROOTFS/etc/pam.d/lightdm-autologin" ]; then
    sed -i 's/^auth.*pam_succeed_if.*user != root.*$/auth required pam_succeed_if.so quiet_success/' \
        "$ROOTFS/etc/pam.d/lightdm-autologin" || true
fi
# fnOS 精简系统没有 /run/utmp，lightdm 会报 "Failed to write utmpx"
touch "$ROOTFS/run/utmp" 2>/dev/null || true
mkdir -p "$ROOTFS/var/run" 2>/dev/null || true

# root 的 xsession
cat > "$ROOTFS/root/.xsession" <<'EOF'
#!/bin/sh
exec dbus-launch --exit-with-session xfce4-session
EOF
chmod +x "$ROOTFS/root/.xsession"
cat > "$ROOTFS/root/.xinitrc" <<'EOF'
#!/bin/sh
exec startxfce4
EOF
chmod +x "$ROOTFS/root/.xinitrc"

# 让 lightdm 自启
chroot_run "$ROOTFS" /bin/bash -c 'systemctl enable lightdm' || true

echo "[40-xfce] 完成: XFCE + lightdm(autologin root)"
