#!/usr/bin/env bash
# 52-ssh-guard.sh —— ssh 守护（每 60s 检查：systemd 拉起失败则直接起 sshd 二进制）
# 背景：2026-10-30 新镜像烧录后 ssh 22 端口不通（RST），adb 也不通，且无串口无法取证。
# fnOS 的 security_service（BPF 防火墙）会管控 ssh（strings 含 /etc/ssh/sshd_config、
# SSHD_PORT_CONF、"ssh service"、/usr/sbin/sshd），可能把 ssh 停掉/掩蔽。
# 本补丁保证：即使 ssh 被停掉、掩蔽或启动瞬态失败，也能自动恢复（含直接起 sshd 二进制），
# 并把 systemctl status/journal/sshd_config/监听端口写入 /var/log/zt1-ssh-guard.log。
set -euo pipefail
ROOTFS="${1:?用法: 52-ssh-guard.sh <rootfs>}"
log() { echo "[52-ssh-guard] $*"; }
install -d -m 0755 "$ROOTFS/usr/local/sbin"

cat > "$ROOTFS/usr/local/sbin/zt1-ssh-guard.sh" <<'EOF_GUARD'
#!/bin/bash
# ssh 守护：未运行就拉起（先走 systemd，失败则直接起 sshd 二进制），并把失败原因写日志
LOG=/var/log/zt1-ssh-guard.log
mkdir -p /var/log
if systemctl is-active --quiet ssh; then
  exit 0
fi
{
  echo "===== $(date '+%F %T') ssh not active, trying start ====="
  # fnOS security_service 可能把 ssh 掩蔽（masked→/dev/null）或 disabled
  systemctl is-enabled --quiet ssh 2>/dev/null; echo "is-enabled rc=$?"
  ls -l /etc/systemd/system/ssh.service 2>&1 | head -2
  systemctl unmask ssh 2>&1 | tail -2
  systemctl enable ssh 2>&1 | tail -2
  mkdir -p /run/sshd
  systemctl start ssh 2>&1 | tail -5
} >> "$LOG" 2>&1
sleep 2
if systemctl is-active --quiet ssh; then
  echo "$(date '+%F %T') ssh started OK via systemd" >> "$LOG"
  exit 0
fi
{
  echo "$(date '+%F %T') ssh start FAILED via systemd, fallback direct sshd"
  echo "--- systemctl status ssh:"; systemctl status ssh --no-pager -l 2>&1 | tail -25
  echo "--- journalctl -u ssh:"; journalctl -u ssh -n 60 --no-pager 2>&1
  echo "--- journal -p3 tail:"; journalctl -b -p 3 --no-pager 2>&1 | tail -30
  echo "--- sshd -t:"; /usr/sbin/sshd -t 2>&1
  echo "--- sshd_config.d:"; ls -l /etc/ssh/sshd_config.d/ 2>&1; cat /etc/ssh/sshd_config.d/*.conf 2>&1 | head -40
  echo "--- port/listen:"; ss -ltnp 2>&1 | head -20
} >> "$LOG" 2>&1
# 直接起 sshd 二进制作为兜底（不走 systemd）
mkdir -p /run/sshd
/usr/sbin/sshd 2>> "$LOG" || true
sleep 1
if pgrep -x sshd >/dev/null 2>&1; then
  echo "$(date '+%F %T') sshd started directly (fallback), listening: $(ss -ltn 2>/dev/null | grep -c ':22 ')" >> "$LOG"
else
  echo "$(date '+%F %T') fallback sshd also failed" >> "$LOG"
fi
# 只留最近 400KB
tail -c 400000 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
exit 0
EOF_GUARD
chmod 0755 "$ROOTFS/usr/local/sbin/zt1-ssh-guard.sh"

cat > "$ROOTFS/etc/systemd/system/zt1-ssh-guard.service" <<'UNIT'
[Unit]
Description=zeroT1 ssh guard (ensure sshd running, log failures)
After=multi-user.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/zt1-ssh-guard.sh
UNIT

cat > "$ROOTFS/etc/systemd/system/zt1-ssh-guard.timer" <<'UNIT'
[Unit]
Description=zeroT1 ssh guard timer
[Timer]
OnBootSec=45s
OnUnitActiveSec=60s
AccuracySec=5s
[Install]
WantedBy=timers.target
UNIT

systemctl --root="$ROOTFS" enable zt1-ssh-guard.timer >/dev/null 2>&1 || {
  install -d -m 0755 "$ROOTFS/etc/systemd/system/timers.target.wants"
  ln -sf /etc/systemd/system/zt1-ssh-guard.timer "$ROOTFS/etc/systemd/system/timers.target.wants/zt1-ssh-guard.timer"
}
log "已安装 zt1-ssh-guard.timer（60s 巡检 + 直接起 sshd 兜底，日志 /var/log/zt1-ssh-guard.log）"
