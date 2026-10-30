#!/bin/bash
# 55-usb-role.sh —— Type-C host/device 角色切换（命令 + 开机自愈）
#
# 背景：fnOS 的 vendor 6.18 内核里 usb-role-switch 一直 waiting_for_supplier，
# 用户态拿不到 /sys/class/usb_role/*/role，无法运行时切角色。
# 因此改成"两份 dtb + 改 extlinux.conf 的 fdt 行 + 重启"的方式：
#   rk3588-aiot3588a.dtb        → Type-C OTG/host
#   rk3588-aiot3588a-usbdev.dtb → Type-C 固定 device（接 PC 出 adb）
# 命令：zt1-usb-role status|device|host [--reboot]
set -e
ROOTFS="${1:?用法: 55-usb-role.sh <rootfs-dir>}"

log() { echo "[55-usb-role] $*"; }

install -d -m 0755 "$ROOTFS/usr/local/sbin"

cat > "$ROOTFS/usr/local/sbin/zt1-usb-role" <<'EOS'
#!/bin/sh
# zt1-usb-role —— 切换 zeroT1 的 Type-C 角色（device=接 PC 出 adb，host=当主机用）
set -eu
CONF=/boot/extlinux/extlinux.conf
DTB_DIR=/boot/dtb/rockchip
HOST_DTB=rk3588-aiot3588a.dtb
DEV_DTB=rk3588-aiot3588a-usbdev.dtb

cur_dtb() { [ -f "$CONF" ] && sed -n 's#^[[:space:]]*fdt[[:space:]][^/]*##p' "$CONF" | sed 's#.*/##' | head -1; }

case "${1:-status}" in
  status)
    d=$(cur_dtb); printf '当前 dtb: %s\n' "${d:-未知}"
    case "$d" in
      "$DEV_DTB") echo "Type-C 角色: device（接 PC 可 adb）" ;;
      "$HOST_DTB") echo "Type-C 角色: host/otg" ;;
      *) echo "Type-C 角色: 未知" ;;
    esac
    ;;
  device) want="$DEV_DTB" ;;
  host)   want="$HOST_DTB" ;;
  -h|--help) echo "用法: zt1-usb-role [status|device|host] [--reboot]"; exit 0 ;;
  *) echo "用法: zt1-usb-role [status|device|host] [--reboot]" >&2; exit 2 ;;
esac

[ "$(cur_dtb)" = "$want" ] || {
  [ -f "$DTB_DIR/$want" ] || { echo "缺少 $DTB_DIR/$want" >&2; exit 1; }
  [ -f "$CONF.origtmp" ] || cp -p "$CONF" "$CONF.origtmp"
  sed -i "s#^[[:space:]]*fdt .*#    fdt /dtb/rockchip/$want#" "$CONF" || {
    echo "改写 $CONF 失败" >&2; exit 1; }
  echo "已切换为 $want（重启后生效）"
  [ "${2:-}" = "--reboot" ] && { sync; reboot; }
}
EOS
chmod 0755 "$ROOTFS/usr/local/sbin/zt1-usb-role"

# 开机自愈：adb gadget 在 dr_mode=device 下要等 UDC 就绪/线插上，重复绑定直到 configured
cat > "$ROOTFS/usr/local/sbin/zt1-adb-watch.sh" <<'EOS'
#!/bin/sh
# 每 10s 检查一次：gadget 没绑 UDC 就绑，adbd 没起来就拉起；最多重试 90 次
G=/sys/kernel/config/usb_gadget/zt1
UDC_NAME=fc000000.usb
i=0
while [ $i -lt 90 ]; do
    i=$((i+1))
    if [ -d "$G" ] && [ -e "/sys/class/udc/$UDC_NAME" ]; then
        cur=$(cat "$G/UDC" 2>/dev/null || true)
        [ "$cur" = "$UDC_NAME" ] || echo "$UDC_NAME" > "$G/UDC" 2>/dev/null || true
    fi
    case "$(cat /sys/class/udc/$UDC_NAME/state 2>/dev/null)" in
        configured) systemctl is-active --quiet adbd || systemctl start adbd ;;
    esac
    sleep 10
done
EOS
chmod 0755 "$ROOTFS/usr/local/sbin/zt1-adb-watch.sh"

cat > "$ROOTFS/etc/systemd/system/zt1-adb-watch.service" <<'EOS'
[Unit]
Description=zeroT1 adb gadget watchdog
After=adbd.service zt1-adbd-gadget.service
Wants=adbd.service

[Service]
Type=simple
ExecStart=/usr/local/sbin/zt1-adb-watch.sh
Restart=no

[Install]
WantedBy=multi-user.target
EOS

install -d -m 0755 "$ROOTFS/etc/systemd/system/multi-user.target.wants"
ln -sf ../zt1-adb-watch.service \
    "$ROOTFS/etc/systemd/system/multi-user.target.wants/zt1-adb-watch.service"
log "已安装 zt1-usb-role 命令与 adb 守护"
