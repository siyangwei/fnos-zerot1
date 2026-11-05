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
# zt1-otg-autoswitch —— Type-C(OTG) 口角色自适应（device/host，事件驱动）
#
# 背景：本板唯一 Type-C 口的 CC/PD 由 fusb302 管理。fnOS 内核的 tcpm 能识别
# partner（PC 插上时 data_role 会显示 device），但 dwc3 的 usb_role_switch 在
# sysfs 里没有可写 role 入口（/sys/class/usb_role/fc000000.usb-role-switch/
# 只有 waiting_for_supplier），内核不会自动切 dwc3 角色，故用用户态兜底写
# debugfs 的 mode。
#
# 事件驱动：主循环用 shell 内建读取（无 fork），每 1s 只读 /proc/interrupts 的
# fsc_interrupt_int_n 计数；计数变化才读一次 fusb302 STATUS0 判断 sink；每 5s
# 一次低频兜底读防 IRQ 丢失。空闲 CPU 约 0，插入设备到切 host 约 1~2s。
#
# 判据（实测，i2c-6 0x22 STATUS0 0x40）：
#   device 模式：空座 = 0x83/0xa3；插入 sink 设备(U盘/PC) = 0x80/0x81/0x82
#   host   模式：看 xhci(挂在 fc000000.usb 下) 是否有设备，拔除即无
set -u
CONF=/etc/zerot1/otg.conf
AUTOSWITCH=1
POLL_MS=200
[ -r "$CONF" ] && . "$CONF"
[ "$AUTOSWITCH" = "1" ] || exit 0

MODE_FILE=/sys/kernel/debug/usb/fc000000.usb/mode
UDC_STATE=/sys/class/udc/fc000000.usb/state
ROLE_TOOL=/usr/local/sbin/zt1-usb-role
STAMP=/run/zt1-usb-role.manual
I2C_BUS=6
I2C_ADDR=0x22
LOG=/var/log/zt1-otg.log
IRQ_NAME=fsc_interrupt_int_n
TICK=1
FALLBACK=5
dtb_cache=""     # 缓存的 dtb 角色
dtb_ticks=0
log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

# 读 /proc/uptime 的整数秒（内建 read，无 fork）
uptime_s() { read t _ < /proc/uptime; t=${t%.*}; }
# 读 /proc/interrupts 里 fusb302 中断的计数（纯 shell 循环，无 fork）
irq_read() {
  cur_irq=0
  while IFS= read -r line; do
    case "$line" in
      *"$IRQ_NAME"*)
        set -- $line
        cur_irq=$2
        break
        ;;
    esac
  done < /proc/interrupts
}

VBUS_DR=0xfec50000
vbus_cycle() {
  # Type-C VBUS 使能脚（GPIO4_A1）真断电复位；等价于用户手拔插一次
  dr=$(busybox devmem "$VBUS_DR" 32 2>/dev/null) || return 0
  bits=$(( dr & 0xffff ))
  low=$(printf '0x%08x' $(( (0x0002 << 16) | (bits & ~0x2) )))
  high=$(printf '0x%08x' $(( (0x0002 << 16) | bits )))
  log "VBUS 断电复位（GPIO4_A1, dr=0x$(printf %04x "$bits")）"
  busybox devmem "$VBUS_DR" 32 "$low" 2>/dev/null || return 0
  sleep 0.4
  busybox devmem "$VBUS_DR" 32 "$high" 2>/dev/null || true
}

host_dev_count() {
  ls -d /sys/devices/platform/fc000000.usb/xhci-hcd.*/usb*/[0-9]*-[0-9]* 2>/dev/null | grep -vc ":"
}

dtb_role() {
  [ -x "$ROLE_TOOL" ] || { echo unknown; return; }
  "$ROLE_TOOL" status 2>/dev/null | sed -n 's/^dtb 角色:[[:space:]]*\([a-z]*\).*/\1/p' | head -1
}

gadget_bound() { [ -s /sys/kernel/config/usb_gadget/zt1/UDC ]; }
rebind_adbd() {
  i=0
  [ $(( $(date +%s) - last_rebind )) -lt 5 ] && return 0
  last_rebind=$(date +%s)
  log "adbd gadget 未绑定，重启 adbd 重新绑定"
  systemctl restart adbd >/dev/null 2>&1 || true
  while [ "$i" -lt 30 ]; do
    gadget_bound && break
    sleep 0.2; i=$((i + 1))
  done
}

log "autoswitch 启动（事件驱动）"
irq_read; last_irq=$cur_irq
last_fallback=$(date +%s)
last_rebind=0
device_since=0
host_since=0
sink_streak=0
empty_streak=0
retry_done=0
armed=1
pending_check=0
has_sink=-1
st0=""
if [ -e "$MODE_FILE" ] && read mode < "$MODE_FILE" && [ "$mode" = "device" ] && ! gadget_bound; then
  rebind_adbd; device_since=$(date +%s)
fi
while :; do
  if [ -f "$STAMP" ]; then
    age=$(( $(date +%s) - $(stat -c %Y "$STAMP" 2>/dev/null || echo 0) ))
    if [ "$age" -lt 600 ]; then sleep "$TICK"; continue; fi
    rm -f "$STAMP"
  fi
  # dtb 角色只每 60s 查一次（子进程开销大且几乎不变）
  dtb_ticks=$((dtb_ticks + 1))
  if [ "$dtb_ticks" -eq 1 ] || [ $((dtb_ticks % 60)) -eq 0 ]; then
    dtb_cache=$(dtb_role)
  fi
  [ "$dtb_cache" = "auto" ] || { sleep 2; continue; }

  read mode < "$MODE_FILE" 2>/dev/null || mode=unknown
  read udc < "$UDC_STATE" 2>/dev/null || udc=unknown
  uptime_s
  t=$t
  irq_read
  event=0
  [ "$cur_irq" != "$last_irq" ] && { event=1; last_irq=$cur_irq; }

  if [ "$mode" = "device" ]; then
    case "$udc" in
      configured|addressed) sleep "$TICK"; continue ;;
    esac
    do_read=0
    if [ "$event" -eq 1 ]; then do_read=1
    elif [ $(( t - last_fallback )) -ge "$FALLBACK" ]; then do_read=1; last_fallback=$t
    elif [ "$pending_check" -ne 0 ] && [ "$t" -ge "$pending_check" ]; then do_read=1; pending_check=0
    fi
    host_since=0
    [ "$device_since" -eq 0 ] && device_since=$t
    gadget_bound || rebind_adbd
    if [ "$do_read" -eq 1 ]; then
      st0=$(i2cget -f -y "$I2C_BUS" "$I2C_ADDR" 0x40 2>/dev/null || echo "")
      case "$st0" in
        0x83|0xA3|0xa3) has_sink=0 ;;
        "")             has_sink=-1 ;;
        *)              has_sink=1 ;;
      esac
      if [ "$has_sink" = 0 ]; then
        armed=1; sink_streak=0; pending_check=0
      elif [ "$has_sink" = 1 ]; then
        sink_streak=$((sink_streak + 1))
        if [ "$armed" -eq 0 ] && [ "$sink_streak" -eq 1 ]; then
          pending_check=$(( t + 2 )); log "见 sink（armed=0），2s 后确认"
        fi
        [ "$armed" -eq 0 ] && [ "$sink_streak" -ge 2 ] && armed=1
      fi
      log "device 采样 STATUS0=$st0 has_sink=$has_sink armed=$armed"
    fi
    need=1; [ "$armed" -eq 0 ] && need=2
    if [ "$has_sink" = 1 ] && [ "$sink_streak" -ge "$need" ] && [ $(( t - device_since )) -ge 2 ]; then
      sink_streak=0
      if echo host > "$MODE_FILE" 2>/dev/null; then
        host_since=$t; device_since=0; retry_done=0; has_sink=-1; log "device→host（STATUS0=${st0:-?}）"
      fi
    fi
  elif [ "$mode" = "host" ]; then
    sink_streak=0; device_since=0; pending_check=0; has_sink=-1
    [ "$host_since" -eq 0 ] && host_since=$t
    n=$(host_dev_count)
    elapsed=$(( t - host_since ))
    if [ "$n" -eq 0 ] && [ "$elapsed" -ge 4 ] && [ "$retry_done" -eq 0 ]; then
      retry_done=1
      log "host 无设备 ${elapsed}s，VBUS 断电复位重试"
      vbus_cycle
      host_since=$(date +%s)
    elif [ "$n" -eq 0 ] && [ "$elapsed" -ge 8 ]; then
      empty_streak=$((empty_streak + 1))
    else
      empty_streak=0
    fi
    if [ "$empty_streak" -ge 2 ]; then
      empty_streak=0; host_since=0; retry_done=0
      if echo device > "$MODE_FILE" 2>/dev/null; then
        device_since=$(date +%s); armed=0; log "host→device（无设备）"
        gadget_bound || rebind_adbd
      fi
    fi
  fi
  sleep "$TICK"
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
POLL_MS=200
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
