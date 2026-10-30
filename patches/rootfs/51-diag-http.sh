#!/usr/bin/env bash
# 51-diag-http.sh —— 开机自检日志 + 8080 只读 HTTP 日志服务器（无串口时的远程诊断通道）
# 背景：2026-10-30 新镜像烧录后 ssh/adb 都不通、只剩 web(5666)，无法取证。
# 本补丁让镜像自带：
#   /usr/local/sbin/zt1-boot-diag.sh   开机 45s 后采集 systemd 状态/journal 到 /var/log/zt1-boot-diag.log
#   /usr/local/sbin/zt1-diag-http.sh   python3 -m http.server 监听 8080，只读目录 /var/log
# 于是浏览器/curl 就能看 http://<ip>:8080/zt1-boot-diag.log、zt1-adbd.log、zt1-wifi-connect.log。
set -euo pipefail
ROOTFS="${1:?用法: 51-diag-http.sh <rootfs>}"
log() { echo "[51-diag] $*"; }

install -d -m 0755 "$ROOTFS/usr/local/sbin"

cat > "$ROOTFS/usr/local/sbin/zt1-boot-diag.sh" <<'DIAG'
#!/bin/bash
# zeroT1 开机自检：把关键服务状态与错误日志落到 /var/log/zt1-boot-diag.log
set -u
OUT=/var/log/zt1-boot-diag.log
mkdir -p /var/log
{
  echo "==================== $(date '+%F %T') boot diag ===================="
  echo "kernel: $(uname -r)"
  echo "cmdline: $(cat /proc/cmdline)"
  echo "--- failed units:"; systemctl --failed --no-pager || true
  for u in ssh adbd postgresql@15-main trim_main trim_init accountsrv sysinfo_service rpc_broker \
           zt1-wifi-connect zt1-jack zt1-diag-http zt1-audio-mclk lightdm; do
    printf '%-24s active=%-10s enabled=%s\n' "$u" "$(systemctl is-active "$u" 2>/dev/null)" "$(systemctl is-enabled "$u" 2>/dev/null)"
  done
  echo "--- listen:"; ss -ltnp 2>/dev/null | head -25
  echo "--- key owners:"; stat -c '%U:%G %a %n' /etc/passwd /etc/shadow /etc/ssh/sshd_config \
      /var/lib/postgresql/15/main /usr/bin/adbd /usr/local/sbin/zt1-wifi-connect.sh 2>/dev/null
  echo "--- pg cluster:"; ls -ld /var/lib/postgresql/15/main 2>/dev/null; ls /var/lib/postgresql/15/main 2>/dev/null | head -5
  echo "--- journal -b -p3 (tail 120):"; journalctl -b -p 3 --no-pager 2>/dev/null | tail -120
  echo "--- sshd -t:"; /usr/sbin/sshd -t 2>&1 || true
  echo "--- adbd log:"; tail -40 /var/log/zt1-adbd.log 2>/dev/null || true
  echo "--- wifi log:"; tail -40 /var/log/zt1-wifi-connect.log 2>/dev/null || true
  echo "--- eth0:"; ip -br addr show eth0 2>/dev/null || true
  for f in carrier speed duplex operstate; do
    printf 'eth0/%s=%s ' "$f" "$(cat /sys/class/net/eth0/$f 2>/dev/null)"
  done; echo
  echo "--- ethtool eth0 (link/speed/wol):"
  ethtool eth0 2>/dev/null | grep -Ei 'link detected|speed|duplex|wake-on|supports wake-on|advertised link modes' || echo "(ethtool 无输出)"
  echo "--- phy:"; ls -l /sys/class/mdio_bus/*/ 2>/dev/null | head -20
  for p in /sys/class/mdio_bus/*/*/; do
    [ -f "$p/phy_id" ] || continue
    echo "phy $p id=$(cat "$p/phy_id" 2>/dev/null) driver=$(basename "$(readlink -f "$p/driver" 2>/dev/null)" 2>/dev/null)"
  done
  echo "--- nmcli devices:"; nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device status 2>/dev/null | head -10
  echo "--- ethernet dmesg:"; dmesg 2>/dev/null | grep -iE 'gmac|stmmac|motorcomm|yt85|eth0' | tail -40 || true
  echo "--- firewall (fnOS security_service 可能拦 eth0):"
  nft list ruleset 2>/dev/null | head -80 || true
  iptables -S 2>/dev/null | head -40 || true
  systemctl is-active security_service 2>/dev/null || true
} >> "$OUT" 2>&1
# 只保留最近 3 次
[ -f "$OUT" ] && tail -c 400000 "$OUT" > "$OUT.tmp" 2>/dev/null && mv "$OUT.tmp" "$OUT"
DIAG
chmod 0755 "$ROOTFS/usr/local/sbin/zt1-boot-diag.sh"

cat > "$ROOTFS/usr/local/sbin/zt1-diag-http.sh" <<'HTTP'
#!/bin/bash
# 只读 HTTP 日志服务（8080），供无串口时诊断
exec python3 -m http.server 8080 --bind 0.0.0.0 --directory /var/log
HTTP
chmod 0755 "$ROOTFS/usr/local/sbin/zt1-diag-http.sh"

cat > "$ROOTFS/etc/systemd/system/zt1-boot-diag.service" <<'UNIT'
[Unit]
Description=zeroT1 boot self-diagnostic (writes /var/log/zt1-boot-diag.log)
After=multi-user.target network.target
[Service]
Type=oneshot
ExecStartPre=/bin/sleep 45
ExecStart=/usr/local/sbin/zt1-boot-diag.sh
[Install]
WantedBy=multi-user.target
UNIT

cat > "$ROOTFS/etc/systemd/system/zt1-diag-http.service" <<'UNIT'
[Unit]
Description=zeroT1 read-only log HTTP server on :8080 (diagnostics)
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/sbin/zt1-diag-http.sh
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
UNIT

systemctl --root="$ROOTFS" enable zt1-boot-diag.service zt1-diag-http.service >/dev/null 2>&1 || {
  install -d -m 0755 "$ROOTFS/etc/systemd/system/multi-user.target.wants"
  ln -sf /etc/systemd/system/zt1-boot-diag.service "$ROOTFS/etc/systemd/system/multi-user.target.wants/zt1-boot-diag.service"
  ln -sf /etc/systemd/system/zt1-diag-http.service "$ROOTFS/etc/systemd/system/multi-user.target.wants/zt1-diag-http.service"
}
log "已安装 boot-diag / diag-http(:8080)"
