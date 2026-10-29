#!/usr/bin/env bash
# 49-debug-net.sh —— 给有线网口加一个「调试用」静态 IP（config.env 驱动）
#
# 为什么需要：
#   我们的镜像目前没有 adbd，板子起不来/连不上 WiFi 时只能靠串口（用户反馈串口很卡）。
#   板子网口直连主机是最稳的调试通道：配一个静态 IP，开机就有 SSH。
#
# config.env 变量：
#   DEBUG_ETH_IP="192.168.1.100/24"   空 = 不启用
#   DEBUG_ETH_IFACE="eth0"            默认 eth0
#
# 生成 NetworkManager keyfile（autoconnect-priority 高，优先于默认「有线连接」），
# 并设 never-default=true（不抢默认路由，避免 WiFi 的网关被覆盖）。
#
# 用法: 49-debug-net.sh <rootfs-dir>
set -euo pipefail

ROOTFS="${1:?usage: $0 <rootfs-dir>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../scripts/lib-common.sh"

IP="${DEBUG_ETH_IP:-}"
IFACE="${DEBUG_ETH_IFACE:-eth0}"
if [ -z "$IP" ]; then
    log "[49-debug-net] DEBUG_ETH_IP 为空，跳过（不配置静态 IP）"
    exit 0
fi
case "$IP" in
    */*) ;;
    *) IP="$IP/24" ;;
esac

CONN_DIR="$ROOTFS/etc/NetworkManager/system-connections"
mkdir -p "$CONN_DIR"
CONN="$CONN_DIR/zt1-eth0-debug.nmconnection"
cat > "$CONN" <<EOF
# zeroT1 调试用有线静态 IP（由 config.env 的 DEBUG_ETH_IP 生成）
[connection]
id=zt1-eth0-debug
uuid=$(uuidgen 2>/dev/null || echo 9f1c2d3e-4a5b-6c7d-8e9f-0a1b2c3d4e5f)
type=ethernet
interface-name=$IFACE
autoconnect=true
autoconnect-priority=80
autoconnect-retries=0

[ethernet]
mac-address-blacklist=

[ipv4]
method=manual
address1=$IP
never-default=true
may-fail=false

[ipv6]
method=disabled

[proxy]
EOF
chmod 0600 "$CONN"
log "[49-debug-net] 已生成 $IFACE 静态 IP $IP（NM: zt1-eth0-debug，never-default）"
log "[49-debug-net] 完成：网线直连主机后即可 ssh root@${IP%%/*}"
