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
#   auto   （默认）otg 版 dtb：接 PC 跑 adb（device 模式）
#   device  强制 peripheral 版：接 PC 跑 adb（tcpm 异常时更稳）
#   host    host 版：Type-C 当主机用（U 盘/键鼠等），adb 不可用
#
# 两种生效方式：
#   持久：zt1-usb-role <角色> [--reboot]   覆盖 /boot 固定 dtb，重启后保持
#   立即：zt1-usb-role <角色> --now        写 dwc3 debugfs 的 mode，本次开机立即生效，
#                                          不改 dtb（重启后回到原角色）
#
# 原理备注：定制 u-boot 固定加载 /dtb/rockchip/rk3588-aiot3588a.dtb；
# dwc3 支持运行时改 mode（/sys/kernel/debug/usb/fc000000.usb/mode），已实测可用。
set -eu
DTB_DIR=/boot/dtb/rockchip
CUR=rk3588-aiot3588a.dtb
AUTO=rk3588-aiot3588a.dtb.otg
AUTO_LEGACY=rk3588-aiot3588a.dtb.host
HOST=rk3588-aiot3588a-host.dtb
DEV=rk3588-aiot3588a-usbdev.dtb
MODE_FILE=/sys/kernel/debug/usb/fc000000.usb/mode

same() { [ -f "$1" ] && [ -f "$DTB_DIR/$CUR" ] && cmp -s "$1" "$DTB_DIR/$CUR"; }

dtb_role() {
  [ -f "$DTB_DIR/$CUR" ] || { echo unknown; return; }
  if same "$DTB_DIR/$HOST"; then echo host
  elif same "$DTB_DIR/$DEV"; then echo device
  elif same "$DTB_DIR/$AUTO" || same "$DTB_DIR/$AUTO_LEGACY"; then echo auto
  else echo unknown; fi
}

rt_mode() { [ -r "$MODE_FILE" ] && cat "$MODE_FILE" || echo unknown; }

set_rt() {
  # $1 = host|device
  [ -w "$MODE_FILE" ] || { echo "无法写 $MODE_FILE（内核未开 dwc3 debug）" >&2; return 1; }
  echo "$1" > "$MODE_FILE"
  sync
  echo "已立即切到 $1 模式（本次开机生效；重启恢复 $2）"
}

[a="${1:-status}"]
case "$a" in
  status)
    echo "dtb 角色: $(dtb_role)    运行时 mode: $(rt_mode)"
    case "$(dtb_role)" in
      auto)   echo "  auto/otg（默认：接 PC 跑 adb）" ;;
      device) echo "  device（强制 peripheral，接 PC 跑 adb）" ;;
      host)   echo "  host（Type-C 当主机用，adb 不可用）" ;;
      *)      echo "  未知（$DTB_DIR/$CUR 缺失或无法识别）" ;;
    esac
    exit 0 ;;
  auto|otg) want=auto ;;
  device)   want=device ;;
  host)     want=host ;;
  -h|--help) echo "用法: zt1-usb-role [status|auto|device|host] [--reboot|--now]"; exit 0 ;;
  *) echo "用法: zt1-usb-role [status|auto|device|host] [--reboot|--now]" >&2; exit 2 ;;
esac
opt="${2:-}"

# --now：只切运行时（写 debugfs），不动 dtb；auto/device 都等价于 device 模式
if [ "$opt" = "--now" ]; then
  if [ "$want" = host ]; then set_rt host "$(dtb_role)"; else set_rt device "$(dtb_role)"; fi
  # 手动切换后 10 分钟内让 zt1-otg-autoswitch 不要自动干预
  touch /run/zt1-usb-role.manual 2>/dev/null || true
  exit 0
fi

case "$want" in
  auto)   src=${AUTO:-}; [ -f "$DTB_DIR/$src" ] || src=$AUTO_LEGACY ;;
  device) src=$DEV ;;
  host)   src=$HOST ;;
esac
[ -f "$DTB_DIR/$src" ] || { echo "缺少 $DTB_DIR/$src（请重刷镜像）" >&2; exit 1; }

if [ "$(dtb_role)" != "$want" ]; then
  cp -f "$DTB_DIR/$src" "$DTB_DIR/$CUR"
  sync
  echo "已切换为 $want（重启后生效；也可加 --now 立即生效）"
else
  echo "dtb 已经是 $want"
fi
[ "$opt" = "--reboot" ] && { sync; reboot; }
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
