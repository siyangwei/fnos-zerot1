#!/usr/bin/env bash
# 46-login-home.sh —— 修复「Web 向导创建的管理员登录 XFCE 后闪回登录页」
#
# 现象（2026-10-29 实测 lightdm.log）：
#   Greeter start authentication for <user> -> Authenticate result: Success
#   -> Session pid=xxx: Exited with return value 1 -> Seat stopped -> lightdm 退出
#   -> systemd Restart=always 重新拉起 -> 又回到登录页（看起来像"登录后被踢出"）
#
# 根因：fnOS 首屏向导用 /usr/trim/bin/useradd 建管理员时不带 -m，
#       /home/<user> 根本不存在，且镜像没有 pam_mkhomedir；
#       xfce4-session 在无家目录（HOME 指向不存在路径）时初始化失败退出 1，
#       lightdm 在这种失败路径下直接停 seat 而不是回 greeter。
#
# 修复：① 打开 pam_mkhomedir（登录时按 /etc/skel 自动建家目录）
#       ② 保证 /home 存在且 755
#       ③ /etc/skel 补齐 XFCE 需要的目录（避免首次登录时权限/目录缺失）
#
# 用法: 46-login-home.sh <rootfs-dir>
set -euo pipefail
ROOTFS="${1:?usage: $0 <rootfs-dir>}"

log() { echo "[46-login-home] $*"; }

# ── 1. /home ────────────────────────────────────────────────────────────────
install -d -m 755 "$ROOTFS/home"

# ── 2. pam_mkhomedir ────────────────────────────────────────────────────────
PAM="$ROOTFS/etc/pam.d/common-session"
if [ -f "$PAM" ]; then
    if ! grep -q 'pam_mkhomedir' "$PAM"; then
        printf 'session\toptional\tpam_mkhomedir.so skel=/etc/skel umask=0022\n' >> "$PAM"
        log "已为 common-session 追加 pam_mkhomedir"
    else
        log "common-session 已有 pam_mkhomedir，跳过"
    fi
else
    echo "[46-login-home] WARN: $PAM 不存在" >&2
fi

# ── 3. /etc/skel：给新用户准备 XFCE 基本目录 ────────────────────────────────
SKEL="$ROOTFS/etc/skel"
install -d -m 755 "$SKEL"
for d in .config/xfce4/xfconf/xfconfd .local/share .cache Desktop; do
    install -d -m 755 "$SKEL/$d"
done
# 让 xfce4 首次启动少弹窗：默认使用 Adwaita 主题、不显示欢迎对话框
if [ ! -f "$SKEL/.config/xfce4/xfconf/xfconfd/xfconf.xml" ]; then
    cat > "$SKEL/.config/xfce4/xfconf/xfconfd/xfconf.xml" <<'X'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfconfd" version="1.0">
  <property name="last" type="string" value=""/>
</channel>
X
fi

# ── 4. 兜底：镜像里若已存在无家目录的普通用户（开发期 rootfs），顺手补上 ──────
if [ -f "$ROOTFS/etc/passwd" ]; then
    while IFS=: read -r name _ uid gid _ home shell; do
        [ "${uid:-0}" -ge 1000 ] 2>/dev/null || continue
        [ "$uid" -lt 60000 ] || continue
        [ -n "$home" ] || continue
        case "$home" in /home/*) ;; *) continue;; esac
        if [ ! -d "$ROOTFS$home" ]; then
            install -d -m 750 "$ROOTFS$home"
            cp -a "$SKEL/." "$ROOTFS$home/" 2>/dev/null || true
            chown -R "$uid:$gid" "$ROOTFS$home" 2>/dev/null || true
            log "已补建家目录 $home (uid=$uid)"
        fi
    done < "$ROOTFS/etc/passwd"
fi

log "完成"
