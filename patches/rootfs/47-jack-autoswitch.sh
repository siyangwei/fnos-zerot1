#!/usr/bin/env bash
# 47-jack-autoswitch.sh —— 耳机插入自动切换（插入耳机时喇叭静音）
#
# 硬件：ES8388 两路输出 LOUT1/ROUT1=耳机、LOUT2/ROUT2=喇叭（外部功放 spk-con），
#       耳机检测是 SARADC 电压检测（Android 同款：SARADC ch3，未插 ~85/37mV，
#       插入 ~4070/1788mV，阈值 1000）。实测 mainline 的 "Headphones Jack" 控件
#       在插拔时不会变化（恒 off），所以以 SARADC 为主、控件为备用。
#
# 用一个常驻小服务轮询：
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
# zeroT1 耳机自动切换（持续纠偏版）
#   * 耳机检测：SARADC ch3 电压（插入 ~4070、未插 ~85，阈值 1000）；
#     备选：codec 的 "Headphones Jack"（实测 mainline 下恒 off，仅兜底）。
#   * 插入耳机：把喇叭那一路 Output 2 音量拉 0（-30dB，等效静音），
#     同时确保耳机那一路 Output 1 保持 30（0dB，否则听不到）。
#   * 拔出耳机：Output 2 恢复 30（0dB）。
#   * 每秒纠偏一次：PulseAudio / 其它服务可能改写 mixer，仅"变化时写"会丢状态。
LOG=/var/log/zt1-jack.log
ADC_CH=3
ADC_MIN=1000
OUT1_DB=30     # 耳机输出（LOUT1/ROUT1）
OUT2_DB=30     # 喇叭输出（LOUT2/ROUT2）正常值
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
ctl_vals() {   # $1=card $2=numid -> "v1,v2"
    amixer -c "$1" cget numid="$2" 2>/dev/null | grep -o 'values=[0-9,]*' | cut -d= -f2
}
jack_plugged() {
    local raw
    raw=$(cat /sys/bus/iio/devices/iio:device0/in_voltage${ADC_CH}_raw 2>/dev/null)
    if [ -n "$raw" ] && [ "$raw" -gt 0 ]; then
        [ "$raw" -ge "$ADC_MIN" ] && return 0 || return 1
    fi
    local card id
    card=$(find_card) || return 1
    id=$(ctl_numid "$card" "Headphones Jack"); id=${id:-1}
    amixer -c "$card" cget numid="$id" 2>/dev/null | grep -q 'values=on'
}
state=""
while :; do
    card=$(find_card) || { sleep 2; continue; }
    o1=$(ctl_numid "$card" "Output 1 Playback Volume")
    o2=$(ctl_numid "$card" "Output 2 Playback Volume")
    if jack_plugged; then want=mute; else want=on; fi
    want2=0; [ "$want" = on ] && want2=$OUT2_DB
    if [ -n "$o1" ] && [ "$(ctl_vals "$card" "$o1")" != "$OUT1_DB,$OUT1_DB" ]; then
        amixer -c "$card" cset numid="$o1" "$OUT1_DB,$OUT1_DB" >/dev/null 2>&1 || true
        log "fix out1=$OUT1_DB (was $(ctl_vals "$card" "$o1"))"
    fi
    if [ -n "$o2" ] && [ "$(ctl_vals "$card" "$o2")" != "$want2,$want2" ]; then
        amixer -c "$card" cset numid="$o2" "$want2,$want2" >/dev/null 2>&1 || true
        log "fix out2=$want2 jack=$want adc=$(cat /sys/bus/iio/devices/iio:device0/in_voltage${ADC_CH}_raw 2>/dev/null)"
    fi
    if [ "$want" != "$state" ]; then
        state="$want"
        log "jack=$want（插入耳机 => 喇叭静音；拔出 => 喇叭恢复）"
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
