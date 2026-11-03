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
    libxcb-dri2-0 \
    dbus-x11 dbus-user-session policykit-1 \
    xfce4 xfce4-session xfce4-terminal xfce4-panel xfce4-settings \
    xfwm4 xfdesktop4 xfce4-power-manager \
    lightdm lightdm-gtk-greeter \
    pulseaudio pulseaudio-utils \
    network-manager-gnome blueman
' || echo "[40-xfce] WARN: 部分包安装失败（检查网络/源）"

if [ "$WITH_XRDP" = "--xrdp" ]; then
    chroot_run "$ROOTFS" /bin/bash -c '
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y --no-install-recommends xrdp xorgxrdp
    systemctl enable xrdp || true
    ' || echo "[40-xfce] WARN: xrdp 安装失败"
fi

# ---- Xorg 加速策略：关闭 glamor ----
# fnOS 应用中心的 Mali GPU Driver 会把 /usr/lib/aarch64-linux-gnu/mali 加进
# ld.so.conf 首位，此时 Xorg 的 modesetting 驱动会拿到 Mali 的 libgbm，
# 实测 glamor 初始化后 ScreenInit 失败、lightdm 起不来。
# 桌面本身用不到 GL，固定 AccelMethod=none 让 X 不依赖 glamor，桌面始终可用；
# 装着 libmali 的其它程序（OpenCL/Vulkan/EGL）仍可正常使用。
mkdir -p "$ROOTFS/etc/X11/xorg.conf.d"
cat > "$ROOTFS/etc/X11/xorg.conf.d/20-zt1-accel.conf" <<'XORGCONF'
Section "Device"
    Identifier "modeset"
    Driver "modesetting"
    Option "AccelMethod" "none"
EndSection
XORGCONF

# ---- lightdm 自动登录 root，进入 XFCE ----
mkdir -p "$ROOTFS/etc/lightdm/lightdm.conf.d"
# ---------------------------------------------------------------
# 登录方式：使用 lightdm-gtk-greeter 正常登录（**不启用 autologin**）
# ---------------------------------------------------------------
mkdir -p "$ROOTFS/etc/lightdm/lightdm.conf.d"
rm -f "$ROOTFS/etc/lightdm/lightdm.conf.d/50-autologin.conf"
cat > "$ROOTFS/etc/lightdm/lightdm.conf.d/60-greeter.conf" <<'EOF'
[Seat:*]
greeter-session=lightdm-gtk-greeter
user-session=xfce
autologin-user=
autologin-user-timeout=0
EOF

# ---------------------------------------------------------------
# ★ 不再预建普通用户（2026-10-29 修正）
#   fnOS 首屏向导会依次调用 user.add1000 → sysinfo.initHostName；
#   且 getHostName 会用"是否存在普通用户"来判断系统是否已初始化。
#   镜像里一旦预置 uid 1000 的用户（旧版预建的 zero），向导必然失败：
#     - add1000 报 uid 1000 已占用（前端「参数错误」）
#     - initHostName 报 "Host name had been inited!!"（前端「系统内部错误」）
#   管理员账号一律由 Web 向导注册时创建，见 41-wizard-firstboot.sh。
# ---------------------------------------------------------------
# 清理 ophub 打包残留的孤儿家目录（/home/anna 属 uid 1000，官方底稿遗留）
rm -rf "$ROOTFS/home/anna"

# lightdm 自身状态目录属主必须是 lightdm，否则 greeter 无法写 .Xauthority。
# ★ 2026-11-04 修正：不能写死 110:110 —— 不同构建里 lightdm 的编号并不固定
#   （CI 镜像实测 lightdm=111:122，写死 110:110 会让目录变成 pulse:rdma，
#     greeter 报 "Failed to open X authority: Permission denied"，lightdm 起不来）。
#   统一从镜像自己的 /etc/passwd 解析 uid/gid。
lm_uid="$(awk -F: '$1=="lightdm"{print $3}' "$ROOTFS/etc/passwd" 2>/dev/null || true)"
lm_gid="$(awk -F: '$1=="lightdm"{print $4}' "$ROOTFS/etc/passwd" 2>/dev/null || true)"
if [ -n "$lm_uid" ] && [ -n "$lm_gid" ]; then
    chown -R "$lm_uid:$lm_gid" "$ROOTFS/var/lib/lightdm" 2>/dev/null || true
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


# --- root 自动登录的两个必须修复（2026-10-28 实测） ---
# 1) lightdm 以 lightdm 用户写 /var/lib/lightdm/.Xauthority，镜像里该目录属主是 root
#    → greeter 报 "Failed to open X authority: Permission denied" → lightdm 反复失败
mkdir -p "$ROOTFS/var/lib/lightdm"
lm_uid="$(awk -F: '$1=="lightdm"{print $3}' "$ROOTFS/etc/passwd" 2>/dev/null || true)"
lm_gid="$(awk -F: '$1=="lightdm"{print $4}' "$ROOTFS/etc/passwd" 2>/dev/null || true)"
if [ -n "$lm_uid" ] && [ -n "$lm_gid" ]; then
    chown -R "$lm_uid:$lm_gid" "$ROOTFS/var/lib/lightdm" 2>/dev/null || true
fi
chmod 755 "$ROOTFS/var/lib/lightdm"

# 2) Debian 默认禁止 root 自动登录：注释掉 pam_succeed_if 那一行
if [ -f "$ROOTFS/etc/pam.d/lightdm-autologin" ]; then
    sed -i 's|^\(auth[[:space:]]*required[[:space:]]*pam_succeed_if.so user != root.*\)|#\1|' \
        "$ROOTFS/etc/pam.d/lightdm-autologin"
fi

echo "[40-xfce] 完成: XFCE + lightdm-gtk-greeter（无自动登录，用户 zero/weisiyang）"
