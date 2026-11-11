#!/usr/bin/env bash
# 61-syscheck.sh —— 内置系统功能自检工具 zt1-check
#
# 安装 /usr/local/sbin/zt1-check：一次性扫描显示/音频/NPU/GPU/VPU/RGA/SD/USB/
# WiFi/蓝牙/风扇/温度/关键服务/内核同步/存储/resize guard，输出 PASS/WARN/FAIL
# 摘要并写 /var/log/zt1-check.log。板端可直接运行 `zt1-check`。
set -euo pipefail

ROOTFS="${1:?usage: $0 <rootfs-dir>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../scripts/lib-common.sh"

[ -n "$ROOTFS" ] || die "ROOTFS 未设置"
[ -d "$ROOTFS" ] || die "rootfs 不存在: $ROOTFS"

cat > "$ROOTFS/usr/local/sbin/zt1-check" << 'ZTC_EOF'
#!/bin/bash
# zt1-check —— zeroT1 / fnOS 系统功能自检（随镜像内置）
# 用法: zt1-check [--quiet]   输出到 stdout 与 /var/log/zt1-check.log
V="1.0"
QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1
LOG=/var/log/zt1-check.log
[ -w /var/log ] || LOG=/tmp/zt1-check.log
: > "$LOG" 2>/dev/null || LOG=/tmp/zt1-check.log
PASS=0; WARN=0; FAIL=0
out() { printf '%s\n' "$*" >>"$LOG"; [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }
ok()  { PASS=$((PASS+1)); [ "$QUIET" = 1 ] || out "  [PASS] $*"; }
warn(){ WARN=$((WARN+1)); out "  [WARN] $*"; }
bad() { FAIL=$((FAIL+1)); out "  [FAIL] $*"; }
sec() { [ "$QUIET" = 1 ] || out ""; out "== $* =="; }
has() { command -v "$1" >/dev/null 2>&1; }
rd()  { [ -r "$1" ] && cat "$1" 2>/dev/null | tr -d '\0' || echo ""; }

out "zeroT1 系统自检 v$V  时间: $(date '+%F %T')"
out "日志: $LOG"

sec "系统"
MODEL=$(rd /proc/device-tree/model); COMPAT=$(rd /proc/device-tree/compatible)
out "  型号: ${MODEL:-未知} (compatible: ${COMPAT:-?})"
out "  内核: $(uname -r)  运行时长: $(uptime -p 2>/dev/null || uptime)"
if [ -f /usr/trim/etc/version ]; then out "  fnOS 版本: $(cat /usr/trim/etc/version)"; fi
ROOTUSE=$(df -h / | awk 'NR==2{print $3"/"$2" ("$5")"}')
out "  rootfs: $ROOTUSE"
if [ -f /boot/Image ]; then
  IMG=$(readlink -f /boot/Image); out "  /boot/Image -> ${IMG#/boot/} ($(du -h "$IMG" 2>/dev/null | cut -f1))"
fi
if has modinfo; then
  if modinfo analogix_dp 2>/dev/null | grep -q '^parm:.*zt1_'; then
    ok "eDP 补丁模块已生效（analogix_dp 带 zt1_* 参数）"
  else
    bad "eDP 补丁模块未生效（analogix_dp 无 zt1_* 参数，换内核后需 zt1-kernel-sync）"
  fi
fi

sec "显示"
if [ -d /sys/class/drm ]; then
  found=0
  for d in /sys/class/drm/card[0-9]*-*; do
    [ -d "$d" ] || continue
    st=$(cat "$d/status" 2>/dev/null); nm=$(basename "$d")
    [ "$st" = "disconnected" ] && continue
    found=1
    en=$(cat "$d/enabled" 2>/dev/null); mode=$(head -1 "$d/modes" 2>/dev/null)
    case "$nm" in
      *eDP*) if [ "$en" = "enabled" ]; then ok "$nm 已点亮 $mode"; else bad "$nm 已连接但未启用"; fi ;;
      *HDMI*) if [ "$en" = "enabled" ]; then ok "$nm 已点亮 $mode"; else warn "$nm 已连接但未启用"; fi ;;
      *) out "  [INFO] $nm $st enabled=$en $mode" ;;
    esac
  done
  [ "$found" = 1 ] || warn "没有已连接的显示输出（eDP 排线/屏幕？）"
fi
if [ -d /sys/class/backlight ]; then
  for b in /sys/class/backlight/*; do
    [ -d "$b" ] || continue
    cur=$(cat "$b/brightness" 2>/dev/null); mx=$(cat "$b/max_brightness" 2>/dev/null)
    if [ "${cur:-0}" -gt 0 ]; then ok "背光 $(basename "$b") = $cur/$mx"; else warn "背光 $(basename "$b") = 0（黑屏）"; fi
  done
fi
if systemctl is-active --quiet lightdm; then ok "lightdm active"; else bad "lightdm 未运行（桌面起不来）"; fi
if pgrep -x Xorg >/dev/null 2>&1; then ok "Xorg 进程存在"; else warn "Xorg 未运行"; fi
if command -v mpv >/dev/null 2>&1; then ok "mpv 播放器 $(mpv --version 2>/dev/null | head -1 | awk '{print $2}')"; else warn "mpv 未安装（桌面 mpv 图标会是感叹号）"; fi

sec "音频"
NCARD=$(grep -cE '^\s*[0-9]+ \[' /proc/asound/cards 2>/dev/null || echo 0)
if [ "$NCARD" -ge 2 ]; then ok "声卡 $NCARD 张"; else warn "声卡只有 $NCARD 张（期望 eDP 声卡 + ES8388）"; fi
if grep -qi 'es8388' /proc/asound/cards 2>/dev/null; then ok "ES8388 声卡在"; else bad "找不到 ES8388 声卡"; fi
if systemctl is-active --quiet zt1-audio-mclk 2>/dev/null; then ok "MCLK 修复服务 active"; else warn "zt1-audio-mclk 未激活（无声风险）"; fi

sec "加速器"
if [ -d /sys/kernel/debug/rknpu ] && [ -r /sys/kernel/debug/rknpu/version ]; then
  ok "NPU: $(tr -d '\0' < /sys/kernel/debug/rknpu/version 2>/dev/null | tr -s ' ')"
elif [ -d /sys/class/devfreq/fdab0000.npu ]; then
  ok "NPU devfreq 在: $(cat /sys/class/devfreq/fdab0000.npu/cur_freq 2>/dev/null) Hz"
else
  warn "NPU 未启用（/sys/kernel/debug/rknpu 不存在）"
fi
if grep -q "^panthor " /proc/modules 2>/dev/null; then
  ok "GPU panthor 开源驱动已加载（Mesa panfrost）"
elif [ -e /dev/mali0 ]; then
  ok "GPU /dev/mali0 在（闭源 kbase）"; else warn "GPU: panthor 未加载且 /dev/mali0 不存在"; fi
if [ -e /dev/mpp_service ]; then
  ok "VPU /dev/mpp_service 在（$(grep -c DEVICE /proc/mpp_service/supports-device 2>/dev/null || echo 0) 个设备）"
else warn "VPU /dev/mpp_service 不存在"; fi
if [ -e /dev/rga ]; then ok "RGA /dev/rga 在"; else warn "RGA /dev/rga 不存在"; fi

sec "存储"
if ls /dev/mmcblk1 >/dev/null 2>&1; then
  ok "SD/TF 卡在: $(blockdev --getsize64 /dev/mmcblk1 2>/dev/null | awk '{printf "%.1fG", $1/1073741824}')"
  [ -r /sys/kernel/debug/mmc1/ios ] && out "  MMC 频率: $(grep clock /sys/kernel/debug/mmc1/ios | tr -d '\t')"
else
  warn "SD/TF 卡未识别或未插入（/dev/mmcblk1 不存在）"
fi
echo "  eMMC: $(cat /sys/block/mmcblk0/device/name 2>/dev/null || echo -) $(blockdev --getsize64 /dev/mmcblk0 2>/dev/null | awk '{printf "%.1fG", $1/1073741824}')"
FS=$(df -h /fs 2>/dev/null | awk 'NR==2{print $3"/"$2}')
if mount 2>/dev/null | grep -q " on /fs type trimafs"; then
  ok "fnOS trimafs /fs 已挂载"
elif [ -n "$FS" ] && [ "${FS%%/*}" != "0" ]; then ok "fnOS 存储空间 /fs: $FS"
else warn "fnOS 存储空间 /fs 未创建（Web 建好后才能用 Docker/影视）"; fi
VOL1=$(df -h /vol1 2>/dev/null | awk 'NR==2{print $3"/"$2}')
[ -n "$VOL1" ] && out "  存储池 /vol1: $VOL1"
if systemctl is-active --quiet docker 2>/dev/null; then ok "Docker active ($(docker info 2>/dev/null | awk '/Storage Driver/{print $3}'))"; else warn "Docker 未运行（先建存储空间）"; fi
if systemctl is-active --quiet resize-rootfs 2>/dev/null; then bad "resize-rootfs 在运行（自动扩容未被禁用）"; else ok "resize-rootfs 未运行（guard 正常）"; fi

sec "USB / 网络 / 蓝牙"
GUDC=$(cat /sys/kernel/config/usb_gadget/*/UDC 2>/dev/null | head -1)
if [ -n "$GUDC" ] && [ -d "/sys/class/udc/$GUDC" ]; then
  sp=$(cat "/sys/class/udc/$GUDC/current_speed" 2>/dev/null); st=$(cat "/sys/class/udc/$GUDC/state" 2>/dev/null)
  if [ "$sp" = "super-speed" ]; then ok "USB gadget $GUDC $sp/$st"; else warn "USB gadget $GUDC $sp/$st"; fi
else
  TMODE=$(cat /sys/kernel/debug/usb/fc000000.usb/mode 2>/dev/null)
  if [ "$TMODE" = "host" ]; then
    out "  [INFO] Type-C 当前 host 模式（接了 U 盘/设备时正常；此时 adb 不可用，拔掉后自动回 device）"
  else
    warn "未发现 USB gadget UDC（Type-C 无连接时正常）"
  fi
fi
pgrep -x adbd >/dev/null 2>&1 && ok "adbd 进程存在" || warn "adbd 未运行"
if has nmcli; then
  WSTATE=$(nmcli -t -f DEVICE,STATE device 2>/dev/null | awk -F: '$1=="wlan0"{print $2}')
  if [ "$WSTATE" = "connected" ]; then
    SSID=$(iw dev wlan0 link 2>/dev/null | awk -F': ' '/SSID/{print $2}')
    FREQ=$(iw dev wlan0 link 2>/dev/null | awk -F': ' '/freq/{print $2}')
    ok "WiFi 已连接: ${SSID:-?} @${FREQ:-?}MHz"
  else warn "WiFi 未连接 (wlan0: ${WSTATE:-unknown})"; fi
fi
if has iw; then
  REG=$(iw reg get 2>/dev/null | grep -m1 '^country'); out "  法规域: ${REG:-未知}"
fi
if [ -d /sys/class/bluetooth ]; then
  for h in /sys/class/bluetooth/hci*; do
    [ -d "$h" ] || continue
    a=$(cat "$h/address" 2>/dev/null); ok "蓝牙 $(basename "$h") $a"
  done
else warn "无蓝牙设备"; fi

sec "风扇 / 温度"
for cd in /sys/class/thermal/cooling_device*; do
  [ -d "$cd" ] || continue
  t=$(cat "$cd/type" 2>/dev/null)
  case "$t" in *fan*|*pwm*) ok "风扇 $t cur_state=$(cat "$cd/cur_state" 2>/dev/null)" ;; esac
done
for hw in /sys/class/hwmon/hwmon*; do
  [ -r "$hw/pwm1" ] || continue
  out "  $(cat "$hw/name" 2>/dev/null) pwm1=$(cat "$hw/pwm1" 2>/dev/null)"
done
TMAX=0
for z in /sys/class/thermal/thermal_zone*; do
  [ -r "$z/temp" ] || continue
  t=$(cat "$z/temp" 2>/dev/null); [ "${t:-0}" -gt "$TMAX" ] && TMAX=$t
done
if [ "$TMAX" -gt 0 ]; then
  TC=$((TMAX/1000))
  if [ "$TC" -ge 85 ]; then warn "最高温度 ${TC}℃（偏高）"; else ok "最高温度 ${TC}℃"; fi
fi

sec "服务"
FAILED=$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | tr '\n' ' ')
if [ -z "$FAILED" ]; then ok "无 failed 单元"; else warn "failed 单元: $FAILED"; fi
for s in NetworkManager wpa_supplicant zt1-wifi-regdom zt1-rootfs-guard zt1-kernel-sync.path eventlogger_service; do
  if systemctl is-active --quiet "$s" 2>/dev/null; then ok "$s active"
  else warn "$s 未激活"; fi
done
TRIMN=$(systemctl list-units 'trim_*.service' --state=active --no-legend 2>/dev/null | wc -l)
ok "trim 服务 active: $TRIMN 个"

sec "总结"
out ""
out "  PASS=$PASS  WARN=$WARN  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then out "  结论: 有 $FAIL 项失败，需排查"; elif [ "$WARN" -gt 0 ]; then out "  结论: 基本正常（$WARN 项提示）"; else out "  结论: 全部正常"; fi
out "  详细日志: $LOG"
exit 0
ZTC_EOF

chmod 755 "$ROOTFS/usr/local/sbin/zt1-check"
ln -sfn ../sbin/zt1-check "$ROOTFS/usr/local/bin/zt1-check" 2>/dev/null || true

log "[61-syscheck] 已安装 /usr/local/sbin/zt1-check（系统功能自检）"
