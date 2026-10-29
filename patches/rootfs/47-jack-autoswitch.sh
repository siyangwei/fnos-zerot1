#!/usr/bin/env bash
# 47-jack-autoswitch.sh —— 耳机插入自动切换（插入耳机时喇叭静音）
#
# 硬件：ES8388 两路输出 LOUT1/ROUT1=耳机、LOUT2/ROUT2=喇叭（外部功放 spk-con），
#       耳机检测是 SARADC 电压检测（Android 侧同一根脚 GPIO4_C2 / SARADC_IN3，
#       Android 用 1.8V 分压阈值的 adc-detect 实现；mainline 由 simple-audio-card
#       的 hp-det-gpios 驱动 "Headphones Jack" 控件）。
#
# mainline 的 simple-audio-card 只上报 jack 状态，不会自动把喇叭静音，所以这里
# 用一个常驻小服务轮询 "Headphones Jack" 控件：
#   插入 -> 把 Output 2 (喇叭) 音量拉到 0（-30dB，等效静音）
#   拔出 -> 恢复 Output 2 = 30（0dB）
# 只动 codec 音量，不碰 GPIO/功放，避免与 GPIO hog 冲突。
#
# 用法: 47-jack-autoswitch.sh <rootfs-dir>
set -euo pipefail
ROOTFS="${1:?usage: $0 <rootfs-dir>}"

log() { echo "[47-jack] $*"; }

install -d -m 755 "$ROOTFS/usr/local/sbin" "$ROOTFS/etc/systemd/system"

cat > "$ROOTFS/usr/local/sbin/zt1-jack.sh" <<'JS_EOF'
#!/bin/bash
# zeroT1 耳机自动切换：插入耳机 -> 静音喇叭输出(Output 2)，拔出 -> 恢复
LOG=/var/log/zt1-jack.log
LIMIT=64   # 单位 KB，超过就截断
log() { echo "$(date '+%F %T') $*" >>"$LOG"; }

find_card() {
    for c in /proc/asound/card*/id; do
        [ -r "$c" ] || continue
        case "$(cat "$c")" in *es8388*) echo "${c#/proc/asound/card}" | cut -d/ -f1; return 0;; esac
    done
    return 1
}
ctl_numid() {  # $1=card $2=控件名 -> numid
    amixer -c "$1" controls 2>/dev/null | awk -F'[,=]' -v n="$2" '$0 ~ n {print $2; exit}'
}
state=""
while :; do
    card=$(find_card) || { sleep 2; continue; }
    jack_id=$(ctl_numid "$card" "Headphones Jack"); jack_id=${jack_id:-1}
    out_id=$(ctl_numid "$card" "Output 2 Playback Volume")
    if amixer -c "$card" cget numid="$jack_id" 2>/dev/null | grep -q 'values=on'; then
        want=mute
    else
        want=on
    fi
    if [ "$want" != "$state" ]; then
        if [ -n "$out_id" ]; then
            if [ "$want" = mute ]; then
                amixer -c "$card" cset numid="$out_id" 0,0 >/dev/null 2>&1 || true
            else
                amixer -c "$card" cset numid="$out_id" 30,30 >/dev/null 2>&1 || true
            fi
            log "jack=$want card=$card out2_numid=$out_id applied"
        else
            log "jack=$want card=$card 未找到 Output 2 控件"
        fi
        state="$want"
    fi
    sleep 1
done
JS_EOF
chmod 755 "$ROOTFS/usr/local/sbin/zt1-jack.sh"

cat > "$ROOTFS/etc/systemd/system/zt1-jack.service" <<'UNIT_EOF'
[Unit]
Description=zeroT1 headphone jack auto switch (mute speaker when HP plugged)
After=sound.target
Wants=sound.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/zt1-jack.sh
Restart=always
RestartSec=2
Nice=5

[Install]
WantedBy=multi-user.target
UNIT_EOF

mkdir -p "$ROOTFS/etc/systemd/system/multi-user.target.wants"
ln -sfn /etc/systemd/system/zt1-jack.service \
    "$ROOTFS/etc/systemd/system/multi-user.target.wants/zt1-jack.service"
log "完成（zt1-jack.service 已 enable）"
