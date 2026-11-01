#!/bin/bash
# 57-display-primary.sh —— 双屏主副屏自动切换（2026-11-02）
#
# 需求（用户 m23865）：HDMI 未插入时 eDP 为主屏；HDMI 插入时 HDMI 为主屏、eDP 为副屏。
# 实现：
#   - /usr/local/bin/zt1-display-primary.sh：轮询 DRM 的 HDMI 热插拔状态，用 xrandr 应用布局；
#   - zt1-display-primary.service（systemd，以 root 运行，After=lightdm）常驻；
#   - 布局：HDMI --auto（EDID 首选/最高分辨率，默认 2560x1440）+ primary，eDP 原生
#     1920x1080 放在 HDMI 正下方（rockchipdrm 最大画布 4096x4096，2560+1920 横向放不下，
#     纵向排列可以不缩放、两屏都清晰）。
set -e
ROOTFS="${1:?用法: 57-display-primary.sh <rootfs-dir>}"
log() { echo "[57-display-primary] $*"; }

install -d -m 0755 "$ROOTFS/usr/local/bin"
cat > "$ROOTFS/usr/local/bin/zt1-display-primary.sh" <<'EOS'
#!/bin/bash
# zeroT1 双屏主副屏自动切换（2026-11-02 定稿：上下排列、全原生分辨率）
#  - HDMI 未插入：eDP 为主屏
#  - HDMI 已插入：HDMI 为主屏（--auto 取 EDID 首选/最高分辨率，默认 2560x1440），
#                  eDP 作为副屏放在 HDMI 正下方（不缩放）。
export DISPLAY="${DISPLAY:-:0}"
export XAUTHORITY="${XAUTHORITY:-/var/run/lightdm/root/:0}"

out_of() { xrandr --query 2>/dev/null | awk -v pat="$1" '$0 ~ pat && / connected/ {print $1; exit}'; }
geom() { xrandr --query 2>/dev/null | awk -v o="$1" '$1 == o {for(i=1;i<=NF;i++) if ($i ~ /^[0-9]+x[0-9]+\+/) {print $i; exit}}'; }

apply_layout() {
    command -v xrandr >/dev/null 2>&1 || return 0
    local edp hdmi g eh
    edp=$(out_of "eDP"); hdmi=$(out_of "HDMI")
    [ -z "$edp" ] && return 0
    if [ -n "$hdmi" ]; then
        xrandr --output "$hdmi" --auto --scale 1x1 --primary --pos 0x0 2>/dev/null
        g=$(geom "$hdmi"); eh=$(echo "$g" | awk -F'[x+]' '{print $2}')
        [ -z "$eh" ] && eh=1440
        xrandr --output "$edp" --auto --scale 1x1 --pos 0x"$eh" 2>/dev/null
        logger -t zt1-display "HDMI=$hdmi primary 0x0 ($g), eDP=$edp secondary 0x$eh"
    else
        xrandr --output "$edp" --auto --scale 1x1 --primary --pos 0x0 2>/dev/null
        logger -t zt1-display "eDP=$edp primary (no HDMI)"
    fi
}

for i in $(seq 1 30); do xrandr --query >/dev/null 2>&1 && break; sleep 1; done

last=""
while true; do
    cur=""
    for f in /sys/class/drm/card*-HDMI-A-*/status; do
        [ -e "$f" ] || continue
        cur="$cur$(basename "$(dirname "$f")")=$(cat "$f") "
    done
    if [ "$cur" != "$last" ]; then
        last="$cur"
        apply_layout
        sleep 3
        apply_layout
    fi
    sleep 2
done
EOS
chmod 0755 "$ROOTFS/usr/local/bin/zt1-display-primary.sh"

cat > "$ROOTFS/etc/systemd/system/zt1-display-primary.service" <<'EOS'
[Unit]
Description=zeroT1 dual display primary switcher (HDMI primary when plugged, eDP otherwise)
After=lightdm.service graphical.target
Wants=lightdm.service

[Service]
Type=simple
# 注意：必须以 root 运行——首次开机向导会删除预置用户、管理员用户名由用户自选，
# 写死 User=zero 在全新镜像上会启动失败；root 用 lightdm 的 XAUTHORITY 同样能操作 :0。
Environment=DISPLAY=:0
Environment=XAUTHORITY=/var/run/lightdm/root/:0
ExecStart=/usr/local/bin/zt1-display-primary.sh
Restart=always
RestartSec=5

[Install]
WantedBy=graphical.target
EOS
install -d -m 0755 "$ROOTFS/etc/systemd/system/graphical.target.wants"
ln -sf /etc/systemd/system/zt1-display-primary.service \
       "$ROOTFS/etc/systemd/system/graphical.target.wants/zt1-display-primary.service"
# 清理早期用 XDG autostart 的实现，避免跑两份
rm -f "$ROOTFS/etc/xdg/autostart/zt1-display-primary.desktop"
log "已安装 zt1-display-primary（自动主副屏切换）"
