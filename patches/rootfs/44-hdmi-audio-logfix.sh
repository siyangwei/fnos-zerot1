#!/usr/bin/env bash
# 44-hdmi-audio-logfix.sh —— HDMI 音频与日志刷屏的折中方案
#
# 背景：为了能用 HDMI 音频，DT 里 &hdmi1_sound = okay，声卡 card0(hdmi1) 一直在。
# 但没有显示器时 ELD 无效，PulseAudio 启动会去探测这张卡，hdmi-codec 的
# snd_soc_dai_prepare() 返回 -19，内核 ASoC 打印一片：
#   hdmi-audio-codec ...: ASoC error (-19): at snd_soc_dai_prepare() on i2s-hifi
# 实测每次启动（PA 拉起时）一次性约 240 行，之后不再刷。
#
# 方案（不牺牲 HDMI 音频）：
#   1) udev 给 HDMI 声卡加 PULSE_IGNORE 属性：没有 HDMI 显示器时 =1（PA 不探测，日志归零）；
#      有显示器时 =0（PA 正常接管，HDMI 音频可用）。
#   2) DRM HDMI 热插拔时重新触发 sound 子系统 add 事件，让上面的属性和 PA 状态刷新。
#
# 已验证：无显示器时加 PULSE_IGNORE=1 后重启 PA，ASoC -19 错误 0 条。
# 用法: 44-hdmi-audio-logfix.sh <rootfs-dir>
set -euo pipefail

ROOTFS="${1:?usage: $0 <rootfs-dir>}"
echo "[44-hdmi-audio-logfix] rootfs=$ROOTFS"

install -d -m 755 "$ROOTFS/usr/local/sbin"
install -d -m 755 "$ROOTFS/etc/udev/rules.d"

# ── 1. 判断 HDMI 是否连接（供 udev IMPORT{program} 使用，输出 KEY=VALUE）──────
cat > "$ROOTFS/usr/local/sbin/zt1-hdmi-pulse-ignore.sh" <<'EOS'
#!/bin/sh
# 无 HDMI 显示器连接时让 PulseAudio 忽略 HDMI 声卡，避免 ASoC prepare 报错刷日志。
# 输出给 udev：PULSE_IGNORE=1（忽略）/ PULSE_IGNORE=0（交给 PA）
st="disconnected"
for f in /sys/class/drm/card*-HDMI-A-1/status; do
    [ -r "$f" ] && st=$(head -1 "$f")
done
if [ "$st" = "connected" ]; then
    echo "PULSE_IGNORE=0"
else
    echo "PULSE_IGNORE=1"
fi
EOS
chmod 755 "$ROOTFS/usr/local/sbin/zt1-hdmi-pulse-ignore.sh"

# ── 2. HDMI 热插拔：重新触发 sound add 事件（刷新 PULSE_IGNORE 与 PA 声卡）────
cat > "$ROOTFS/usr/local/sbin/zt1-hdmi-hotplug.sh" <<'EOS'
#!/bin/sh
# HDMI 显示器插拔后，让 udev 重新发一次 sound 卡的 add 事件，
# 使 zt1-hdmi-pulse-ignore.sh 重新计算 PULSE_IGNORE，PulseAudio 据此增删 HDMI 声卡。
[ -x /usr/bin/udevadm ] || exit 0
sleep 2
/usr/bin/udevadm trigger --subsystem-match=sound --action=add 2>/dev/null || true
EOS
chmod 755 "$ROOTFS/usr/local/sbin/zt1-hdmi-hotplug.sh"

# ── 3. udev 规则 ────────────────────────────────────────────────────────────
cat > "$ROOTFS/etc/udev/rules.d/90-zt1-hdmi-audio.rules" <<'EOS'
# HDMI 音频日志治理（zeroT1）：
#  - 声卡 add 时按 HDMI 是否连接设置 PULSE_IGNORE（无显示器时 PA 不探测，日志干净）
#  - HDMI 插拔时重新触发 sound add（有显示器则 PA 自动接管，HDMI 音频可用）
SUBSYSTEM=="sound", KERNEL=="card[0-9]*", ATTRS{id}=="hdmi1", IMPORT{program}="/usr/local/sbin/zt1-hdmi-pulse-ignore.sh"
SUBSYSTEM=="drm", ACTION=="change", KERNEL=="card0-HDMI-A-1", RUN+="/usr/local/sbin/zt1-hdmi-hotplug.sh"
EOS

echo "[44-hdmi-audio-logfix] 已写入 udev 规则与两个辅助脚本"
