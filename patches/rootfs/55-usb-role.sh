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
# zt1-usb-role —— 切换 zeroT1 唯一 Type-C 口的角色
#
#   auto   （默认）otg 版 dtb：接 PC 自动进 device 模式（adb 可用）
#   device  强制 peripheral 版：接 PC 出 adb（与 auto 效果接近，tcpm 异常时更稳）
#   host    host 版：Type-C 当主机用（U 盘/键鼠等），此时 adb 不可用
#
# 原理：定制 u-boot 的 bootcmd 固定加载 /dtb/rockchip/rk3588-aiot3588a.dtb
# （直连引导，不走 extlinux/boot.scr），所以把对应变体覆盖到固定文件名即可。
# 注意：切换后需要重启才生效（--reboot 可自动重启）。
set -eu
DTB_DIR=/boot/dtb/rockchip
CUR=rk3588-aiot3588a.dtb
AUTO=rk3588-aiot3588a.dtb.otg          # auto 母本
AUTO_LEGACY=rk3588-aiot3588a.dtb.host  # 旧镜像里的 auto 母本名（内容同 otg）
HOST=rk3588-aiot3588a-host.dtb          # host 变体
DEV=rk3588-aiot3588a-usbdev.dtb         # device 变体

same() { [ -f "$1" ] && [ -f "$DTB_DIR/$CUR" ] && cmp -s "$1" "$DTB_DIR/$CUR"; }

cur_role() {
  [ -f "$DTB_DIR/$CUR" ] || { echo unknown; return; }
  if same "$DTB_DIR/$HOST"; then echo host
  elif same "$DTB_DIR/$DEV"; then echo device
  elif same "$DTB_DIR/$AUTO" || same "$DTB_DIR/$AUTO_LEGACY"; then echo auto
  else echo unknown; fi
}

reboot_now() { [ "${1:-}" = "--reboot" ] && { sync; reboot; }; }

case "${1:-status}" in
  status)
    r=$(cur_role)
    case "$r" in
      auto)   echo "Type-C 角色: auto/otg（接 PC: adb 设备模式；默认）" ;;
      device) echo "Type-C 角色: device（接 PC: adb 设备模式，强制 peripheral）" ;;
      host)   echo "Type-C 角色: host（Type-C 当主机用，adb 不可用）" ;;
      *)      echo "Type-C 角色: 未知（$DTB_DIR/$CUR 缺失或无法识别）" ;;
    esac
    exit 0 ;;
  auto|otg)
    if [ -f "$DTB_DIR/$AUTO" ]; then src="$DTB_DIR/$AUTO"
    elif [ -f "$DTB_DIR/$AUTO_LEGACY" ]; then src="$DTB_DIR/$AUTO_LEGACY"
    else echo "缺少 auto 母本 dtb（请重刷镜像）" >&2; exit 1; fi
    want=auto ;;
  device) src="$DTB_DIR/$DEV";  want=device ;;
  host)   src="$DTB_DIR/$HOST"; want=host ;;
  -h|--help)
    echo "用法: zt1-usb-role [status|auto|device|host] [--reboot]"; exit 0 ;;
  *)
    echo "用法: zt1-usb-role [status|auto|device|host] [--reboot]" >&2; exit 2 ;;
esac

[ -f "$src" ] || { echo "缺少 $src（请重刷镜像）" >&2; exit 1; }
if [ "$(cur_role)" != "$want" ]; then
  cp -f "$src" "$DTB_DIR/$CUR"
  sync
  echo "已切换为 $want（重启后生效）"
else
  echo "当前已经是 $want，无需切换"
fi
reboot_now "${2:-}"
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
