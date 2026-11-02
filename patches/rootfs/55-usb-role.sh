#!/bin/bash
# 55-usb-role.sh —— Type-C host/device 角色切换（命令 + 开机自愈）
#
# 背景：fnOS 的 vendor 6.18 内核里 usb-role-switch 一直 waiting_for_supplier，
# 用户态拿不到 /sys/class/usb_role/*/role，无法运行时切角色。
# 因此改成"两份 dtb + 覆盖 u-boot 固定加载的 dtb 文件名 + 重启"的方式：
#   rk3588-aiot3588a.dtb        → u-boot 实际加载的文件（host 或 device 版覆盖上去）
#   rk3588-aiot3588a.dtb.host   → host/otg 母本（打包时放入）
#   rk3588-aiot3588a-usbdev.dtb → Type-C 固定 device（接 PC 出 adb）
# 命令：zt1-usb-role status|device|host [--reboot]
set -e
ROOTFS="${1:?用法: 55-usb-role.sh <rootfs-dir>}"

log() { echo "[55-usb-role] $*"; }

install -d -m 0755 "$ROOTFS/usr/local/sbin"

cat > "$ROOTFS/usr/local/sbin/zt1-usb-role" <<'EOS'
#!/bin/sh
# zt1-usb-role —— 切换 zeroT1 的 Type-C 角色（device=接 PC 出 adb，host=当主机用）
#
# 注意：定制 u-boot 的 bootcmd 固定加载 /dtb/rockchip/rk3588-aiot3588a.dtb
# （直连引导，不走 extlinux/boot.scr），所以不能靠改 extlinux.conf 的 fdt 行切换，
# 只能把对应变体覆盖到那个固定文件名上；.dtb.host 是 host 版母本（打包时放入）。
set -eu
DTB_DIR=/boot/dtb/rockchip
HOST_DTB=rk3588-aiot3588a.dtb          # u-boot 实际加载的文件（会被覆盖）
HOST_MASTER=rk3588-aiot3588a.dtb.host  # host/otg 母本
DEV_DTB=rk3588-aiot3588a-usbdev.dtb    # device 变体（dr_mode=peripheral）

cur_role() {
  [ -f "$DTB_DIR/$HOST_DTB" ] || { echo unknown; return; }
  if cmp -s "$DTB_DIR/$HOST_MASTER" "$DTB_DIR/$HOST_DTB" 2>/dev/null; then
    echo host
  else
    echo device
  fi
}

case "${1:-status}" in
  status)
    case "$(cur_role)" in
      device) echo "Type-C 角色: device（接 PC 可 adb）" ;;
      host)   echo "Type-C 角色: host/otg（插 PC 自动切 device）" ;;
      *)      echo "Type-C 角色: 未知（缺少 $DTB_DIR/$HOST_DTB）" ;;
    esac
    exit 0
    ;;
  device) want=device ;;
  host)   want=host ;;
  -h|--help) echo "用法: zt1-usb-role [status|device|host] [--reboot]"; exit 0 ;;
  *) echo "用法: zt1-usb-role [status|device|host] [--reboot]" >&2; exit 2 ;;
esac

if [ "$(cur_role)" != "$want" ]; then
  if [ "$want" = device ]; then
    [ -f "$DTB_DIR/$DEV_DTB" ] || { echo "缺少 $DTB_DIR/$DEV_DTB" >&2; exit 1; }
    cp -f "$DTB_DIR/$DEV_DTB" "$DTB_DIR/$HOST_DTB"
  else
    [ -f "$DTB_DIR/$HOST_MASTER" ] || { echo "缺少 $DTB_DIR/$HOST_MASTER（请重刷镜像）" >&2; exit 1; }
    cp -f "$DTB_DIR/$HOST_MASTER" "$DTB_DIR/$HOST_DTB"
  fi
  sync
  echo "已切换为 $want（重启后生效）"
  [ "${2:-}" = "--reboot" ] && { sync; reboot; }
fi
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
