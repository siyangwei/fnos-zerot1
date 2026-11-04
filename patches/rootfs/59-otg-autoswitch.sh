#!/bin/bash
# 59-otg-autoswitch.sh —— Type-C(OTG) 口 device/host 自动切换
#
# 背景：本板唯一 Type-C 口的 CC/PD 由 fusb302 管理，但 fnOS 内核的 typec/tcpm
# 不工作（无 partner、无状态机日志、不会自动切 dwc3 角色），因此默认只能手动
# 切。本补丁用用户态轮询 fusb302 STATUS0 + xhci 设备表，配合 dwc3 debugfs 的
# mode 实现「插入 U 盘自动切 host、拔掉自动回 device」。
#
# 依赖：i2c-tools（读取 fusb302）、/sys/kernel/debug/usb/fc000000.usb/mode
# 停用：/etc/zerot1/otg.conf 里 AUTOSWITCH=0，或 systemctl disable zt1-otg-autoswitch
set -euo pipefail
ROOTFS="${1:?用法: 59-otg-autoswitch.sh <rootfs-dir>}"
HERE="$(cd "$(dirname "$0")" && pwd)"

log() { echo "[59-otg-autoswitch] $*"; }
need_root() { [ "$(id -u)" = "0" ] || { echo "需要 root" >&2; exit 1; }; }

log "rootfs: $ROOTFS"
need_root

install -d -m755 "$ROOTFS/usr/local/sbin" "$ROOTFS/etc/zerot1" "$ROOTFS/etc/systemd/system"

cat > "$ROOTFS/usr/local/sbin/zt1-otg-autoswitch" <<'EOS'
#!/bin/sh
# zt1-otg-autoswitch —— Type-C(OTG) 口角色自适应（device/host）
#
# 背景：本板唯一 Type-C 口的 CC/PD 由 fusb302 管理，但 fnOS 内核的 typec/tcpm
# 未真正工作（无 partner、无状态机日志、不会自动切 dwc3 角色）。这里用用户态
# 轮询 fusb302 STATUS0 + xhci 设备表，写 dwc3 debugfs 的 mode 完成自适应。
#
# 判据（实测，i2c-6 0x22 STATUS0 0x40，按当前 mode 区分）：
#   device 模式：空座 = 0x83/0xa3（bit0=1）；插入 sink 设备(U盘) = 0x82（bit0=0）
#   host   模式：看 xhci(挂在 fc000000.usb 下) 是否有设备，拔除即无
# 安全：
#   - 仅当 dtb 角色为 auto（默认）时工作，显式 host/device 的 dtb 不干预；
#   - device→host 仅在 UDC 未 attached（没连主机）时进行；
#   - 切到 host 后 6s 内没有任何 USB 设备出现 → 自动切回 device（防误切）；
#   - 用户手动 `zt1-usb-role ... --now` 后 10 分钟内不自动干预（/run 时间戳）。
set -u
CONF=/etc/zerot1/otg.conf
AUTOSWITCH=1
POLL_MS=500
[ -r "$CONF" ] && . "$CONF"
[ "$AUTOSWITCH" = "1" ] || exit 0

MODE_FILE=/sys/kernel/debug/usb/fc000000.usb/mode
UDC_STATE=/sys/class/udc/fc000000.usb/state
ROLE_TOOL=/usr/local/sbin/zt1-usb-role
STAMP=/run/zt1-usb-role.manual
I2C_BUS=6
I2C_ADDR=0x22
LOG=/var/log/zt1-otg.log
SLEEP=$(awk "BEGIN{printf \"%.3f\", $POLL_MS/1000}")
sink_streak=0
empty_streak=0
host_since=0
now() { date +%s; }
log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

host_dev_count() {
  # 只统计真正接入的设备（排除每个总线自带的 root hub 接口条目 9-0:1.0）
  ls -d /sys/devices/platform/fc000000.usb/xhci-hcd.*/usb*/[0-9]*-[0-9]* 2>/dev/null | grep -vc ":"
}

dtb_role() {
  [ -x "$ROLE_TOOL" ] || { echo unknown; return; }
  "$ROLE_TOOL" status 2>/dev/null | sed -n 's/^dtb 角色:[[:space:]]*\([a-z]*\).*/\1/p' | head -1
}

log "autoswitch 启动（POLL_MS=$POLL_MS）"
while :; do
  # 用户刚手动切过 → 10 分钟内不自动干预
  if [ -f "$STAMP" ]; then
    age=$(( $(now) - $(stat -c %Y "$STAMP" 2>/dev/null || echo 0) ))
    if [ "$age" -lt 600 ]; then sleep "$SLEEP"; continue; fi
    rm -f "$STAMP"
  fi
  # 只在 auto 模式下工作
  if [ "$(dtb_role)" != "auto" ]; then sleep 2; continue; fi

  mode=$(cat "$MODE_FILE" 2>/dev/null || echo unknown)
  udc=$(cat "$UDC_STATE" 2>/dev/null || echo unknown)
  st0=$(i2cget -f -y "$I2C_BUS" "$I2C_ADDR" 0x40 2>/dev/null || echo "")
  case "$st0" in
    0x82|0xA2|0xa2) has_sink=1 ;;   # BC_LVL 低位为 0：CC 上挂着 sink（U盘等）
    *)              has_sink=0 ;;
  esac
  if [ "$mode" = "device" ]; then
    host_since=0
    if [ "$udc" = "not attached" ] && [ "$has_sink" = 1 ]; then
      sink_streak=$((sink_streak + 1))
    else
      sink_streak=0
    fi
    if [ "$sink_streak" -ge 3 ]; then
      sink_streak=0
      if echo host > "$MODE_FILE" 2>/dev/null; then
        host_since=$(now); log "device→host（STATUS0=$st0）"
      fi
    fi
  elif [ "$mode" = "host" ]; then
    sink_streak=0
    [ "$host_since" -eq 0 ] && host_since=$(now)
    n=$(host_dev_count)
    if [ "$n" -eq 0 ] && [ $(( $(now) - host_since )) -ge 6 ]; then
      empty_streak=$((empty_streak + 1))
    else
      empty_streak=0
    fi
    if [ "$empty_streak" -ge 4 ]; then
      empty_streak=0; host_since=0
      if echo device > "$MODE_FILE" 2>/dev/null; then
        log "host→device（无设备，STATUS0=$st0）"
      fi
    fi
  fi
  sleep "$SLEEP"
done
EOS

cat > "$ROOTFS/etc/systemd/system/zt1-otg-autoswitch.service" <<'EOS'
[Unit]
Description=zeroT1 Type-C(OTG) role auto-switch (device/host)
After=local-fs.target
Wants=local-fs.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/zt1-otg-autoswitch
Restart=always
RestartSec=2
Nice=-5

[Install]
WantedBy=multi-user.target
EOS

cat > "$ROOTFS/etc/zerot1/otg.conf" <<'EOS'
# zeroT1 Type-C(OTG) 自动角色切换
# 1 = 启用（默认）：插设备自动切 host，拔出自动切回 device（adb 可用）
AUTOSWITCH=1
# 轮询间隔（毫秒）
POLL_MS=500
EOS
chmod 755 "$ROOTFS/usr/local/sbin/zt1-otg-autoswitch"
chmod 644 "$ROOTFS/etc/systemd/system/zt1-otg-autoswitch.service" "$ROOTFS/etc/zerot1/otg.conf"

mkdir -p "$ROOTFS/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/zt1-otg-autoswitch.service \
       "$ROOTFS/etc/systemd/system/multi-user.target.wants/zt1-otg-autoswitch.service"

# i2c-tools 是运行时依赖（i2cget 读 fusb302；没有它自动切换会失效）
if [ ! -x "$ROOTFS/usr/sbin/i2cget" ] && [ ! -x "$ROOTFS/usr/bin/i2cget" ]; then
  # shellcheck source=../../scripts/lib-chroot.sh
  source "$HERE/../../scripts/lib-chroot.sh"
  if [ -e "$QEMU_BIN" ]; then
    chroot_mount "$ROOTFS"
    chroot_run "$ROOTFS" /bin/bash -c '
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq || true
      apt-get install -y --no-install-recommends i2c-tools || echo "[59] WARN: i2c-tools 安装失败"
      apt-get clean
      rm -rf /var/lib/apt/lists/*
    ' || true
    chroot_umount "$ROOTFS"
  else
    log "警告：缺少 qemu-aarch64-static，未能安装 i2c-tools"
  fi
fi
if [ ! -x "$ROOTFS/usr/sbin/i2cget" ] && [ ! -x "$ROOTFS/usr/bin/i2cget" ]; then
  log "警告：rootfs 内缺少 i2cget（i2c-tools），自动切换会失效"
fi
log "59-otg-autoswitch 完成"
