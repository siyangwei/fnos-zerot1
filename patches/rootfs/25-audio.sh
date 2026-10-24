#!/bin/bash
# ============================================================================
# 25-audio.sh - ES8388(es8323 驱动) 喇叭输出初始化
#
# 背景：Linux 用 sound/soc/codecs/es8323.c 驱动跑 ES8388 芯片。该驱动的
#       输出路径是：
#           I2S IN -> DAC -> Mixer -> Left/Right Out 2 -> OUT2(SWITCH) -> LOUT2/ROUT2
#       `OUT2` 这个 DAPM switch 默认是 **off**，导致 LOUT2/ROUT2（喇叭）没有信号，
#       即使 PulseAudio sink 正常、PCM 音量 94%、spk-con GPIO 已使能，也完全无声。
#       Android 下由 HAL 设置，Linux 需要显式打开。
#       另需打开：spk switch（外部功放 GPIO4_A3）、Speaker（DAPM pin）。
# ============================================================================
set -e

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../../scripts/lib-common.sh"

[ -n "$ROOTFS" ] || die "ROOTFS 未设置"
[ -d "$ROOTFS" ] || die "rootfs 不存在: $ROOTFS"

# 开机初始化脚本
mkdir -p "$ROOTFS/usr/local/sbin"
cat > "$ROOTFS/usr/local/sbin/fnnas-audio-init.sh" << 'SCRIPT'
#!/bin/bash
# ES8388 喇叭输出初始化（es8323 驱动）
# 等声卡就绪
for i in $(seq 1 30); do
    [ -d /sys/class/sound/card1 ] && break
    sleep 0.2
done
for c in OUT2 "spk switch" "Speaker" "hp switch"; do
    amixer -c 1 sset "$c" on 2>/dev/null || true
done
# 默认音量
amixer -c 1 sset PCM 181 2>/dev/null || true
amixer -c 1 sset Headphone on 2>/dev/null || true
exit 0
SCRIPT
chmod +x "$ROOTFS/usr/local/sbin/fnnas-audio-init.sh"

# systemd 服务（在 multi-user 阶段、声卡就绪后执行）
cat > "$ROOTFS/etc/systemd/system/fnnas-audio-init.service" << 'UNIT'
[Unit]
Description=Fix ES8388 speaker output (OUT2 DAPM switch off by default)
After=sound.target alsa-restore.service
Wants=sound.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/fnnas-audio-init.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

# 启用服务
ln -sf /etc/systemd/system/fnnas-audio-init.service \
       "$ROOTFS/etc/systemd/system/multi-user.target.wants/fnnas-audio-init.service" 2>/dev/null || true

log "[25-audio] ES8388 喇叭初始化脚本 + systemd 服务已安装（OUT2/spk switch/Speaker 开机 on）"
