#!/usr/bin/env bash
# 55-adb-watch.sh —— adb gadget 开机自愈（从原 55-usb-role.sh 拆出）
#
# 背景：主线内核 + 本板 DTS 修复后，Type-C 角色切换由 tcpm 原生驱动
# （fusb302 + usb-role-switch，DTS 已把 role_sw 端点挂到 connector 的 port@2，
# 并删掉了 usbdp_phy1 误绑的 phy-supply），不再需要用户态 zt1-usb-role /
# zt1-otg-autoswitch 守护。两者分别归档到 archive/rootfs/55-usb-role.sh、
# archive/rootfs/59-otg-autoswitch.sh.disabled。
#
# 本补丁只保留独立功能：adb gadget 自愈。
#   - gadget 已由 48-adb-gadget.sh 创建（/sys/kernel/config/usb_gadget/zt1 + ffs.adb）
#   - 挂 PC 后角色切到 device 时，UDC 就绪/线插上有先后，adbd 可能起不来；
#     这里每 10s 检查一次：gadget 没绑 UDC 就绑，adbd 没起来就拉起，最多 90 次（15 分钟）。
#   - 该服务与角色切换无关，插 U 盘（host 模式占用 UDC）时 adbd 绑不上属正常现象，
#     adbd.service 会反复失败但拔掉外设后自动恢复。
set -e
ROOTFS="${1:?用法: 55-adb-watch.sh <rootfs-dir>}"

log() { echo "[55-adb-watch] $*"; }

install -d -m 0755 "$ROOTFS/usr/local/sbin"

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
After=adbd.service
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
log "已安装 adb gadget 自愈（zt1-adb-watch）"
