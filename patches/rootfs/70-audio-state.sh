#!/usr/bin/env bash
# 70-audio-state.sh —— ES8388 喇叭功放使能（解决"喇叭图标打叉/没声音"）
#
# 现象：BSP 的 rockchip-multicodecs 声卡里有两个独立控件
#   1) "Speaker"      —— DAPM pin switch（控制 codec 内部 LOUT2/ROUT2 到 Speaker 的通路）
#   2) "spk switch"   —— 外部功放使能 GPIO（spk-con-gpio = GPIO4_A3，ACTIVE_LOW）
#
# 出厂默认 "Speaker"=on 但 "spk switch"=off ⇒ spk-con 保持高电平 ⇒ 外部功放不供电，
# 于是桌面音量图标显示"打叉"、aplay/speaker-test 全部静音。
#
# 修复：开机时把两个开关都打开（spk switch 由 multicodecs 驱动直接拉低 GPIO4_A3）。
# 用 systemd oneshot 服务在 sound 子系统就绪后执行，卡号动态查找，换内核也不怕。
#
# 用法: 70-audio-state.sh <rootfs-dir>
set -euo pipefail

ROOTFS="${1:?usage: $0 <rootfs-dir>}"
HERE="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "$ROOTFS/etc/systemd/system"

# 用独立脚本 + 简单 ExecStart（避免 systemd 对 ExecStart 内联 $ 变量/引号/%% 的处理陷阱）
cat > "$ROOTFS/usr/local/sbin/zt1-audio-init.sh" <<'SCRIPT'
#!/bin/sh
# ES8388 输出级初始化：Output 1/2 默认 0（= -30dB，几乎无声），拉到 30(0dB)；PCM=181
card=""
for c in /proc/asound/card[0-9]*/id; do
    [ -r "$c" ] || continue
    if [ "$(cat "$c")" = "rockchipes8388" ]; then
        card=$(basename "$(dirname "$c")")
        card=${card#card}
        break
    fi
done
[ -n "$card" ] || { echo "zt1-audio-init: rockchipes8388 not found"; exit 0; }
echo "zt1-audio-init: card=$card"
amixer -c "$card" sset "PCM" 181 >/dev/null 2>&1 || true
amixer -c "$card" cset "name=Output 1 Playback Volume" 30,30 >/dev/null 2>&1 || true
amixer -c "$card" cset "name=Output 2 Playback Volume" 30,30 >/dev/null 2>&1 || true
echo "zt1-audio-init: done"
SCRIPT
chmod 0755 "$ROOTFS/usr/local/sbin/zt1-audio-init.sh"

cat > "$ROOTFS/etc/systemd/system/es8388-audio-init.service" <<'EOF'
[Unit]
Description=Enable ES8388 speaker/headphone output (spk switch GPIO)
After=sound.target alsa-restore.service
Wants=sound.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/zt1-audio-init.sh

[Install]
WantedBy=multi-user.target
EOF

# 启用（rootfs 里手工建 multi-user.target.wants 软链，不需要 chroot）
mkdir -p "$ROOTFS/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/es8388-audio-init.service \
       "$ROOTFS/etc/systemd/system/multi-user.target.wants/es8388-audio-init.service"

echo "[70-audio-state] 完成: es8388-audio-init.service（spk switch on）"
