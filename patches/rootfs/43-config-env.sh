#!/bin/bash
# ============================================================================
# 43-config-env.sh - config.env 落盘 + 首启连 WiFi + SSH 可登录
#
# 读取仓库根目录的 config.env（由 scripts/lib-common.sh 加载，外部环境变量优先），
# 把配置写进镜像：
#   /etc/zerot1/config.env                构建配置副本（root 600，供开机脚本读取）
#   /usr/local/sbin/zt1-wifi-connect.sh   首启连 WiFi 脚本（读 /etc/zerot1/config.env）
#   /etc/systemd/system/zt1-wifi-connect.service  开机执行上面脚本（WiFi 唯一实现）
#   /etc/ssh/sshd_config.d/00-zerot1.conf root 可密码登录（ENABLE_SSH=1 时）
#
# config.env 里可用的变量见仓库根 config.env 注释；以后新增变量（开关某个服务、
# 控制 Actions 构建步骤等）只要在本脚本或运行期脚本里读即可，无需改其它地方。
# ============================================================================
set -e

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../../scripts/lib-common.sh"

ROOTFS="${1:-$ROOTFS}"
[ -n "$ROOTFS" ] || die "ROOTFS 未设置"
[ -d "$ROOTFS" ] || die "rootfs 不存在: $ROOTFS"

WIFI_SSID="${WIFI_SSID:-}"
WIFI_PASSWORD="${WIFI_PASSWORD:-}"
WIFI_FALLBACK_SSID="${WIFI_FALLBACK_SSID:-}"
WIFI_FALLBACK_PASSWORD="${WIFI_FALLBACK_PASSWORD:-${WIFI_PASSWORD}}"
WIFI_HIDDEN="${WIFI_HIDDEN:-0}"
WIFI_COUNTRY="${WIFI_COUNTRY:-CN}"
ENABLE_WIFI="${ENABLE_WIFI:-1}"
ENABLE_SSH="${ENABLE_SSH:-1}"
ROOT_PASSWORD="${ROOT_PASSWORD:-}"
DEVICE_HOSTNAME="${DEVICE_HOSTNAME:-}"

ETH_ZEROT1="$ROOTFS/etc/zerot1"
mkdir -p "$ETH_ZEROT1"

# ── 1. 把 config.env 原样拷进镜像 ───────────────────────────────────────────
if [ -f "$CONFIG_ENV" ]; then
    install -m 600 -o root -g root "$CONFIG_ENV" "$ETH_ZEROT1/config.env"
    log "[43-config-env] 已写入 /etc/zerot1/config.env"
else
    warn "[43-config-env] 未找到 $CONFIG_ENV，镜像内不写配置（WiFi 首启将跳过）"
fi

# ── 2. 首启连 WiFi 脚本 ─────────────────────────────────────────────────────
install -d -m 755 "$ROOTFS/usr/local/sbin"
cat > "$ROOTFS/usr/local/sbin/zt1-wifi-connect.sh" <<'WIFI_EOF'
#!/bin/bash
# zeroT1 首启自动连 WiFi —— 唯一实现，全部参数来自 /etc/zerot1/config.env。
# 规则：
#   1) 只读配置，不写死任何 SSID/密码；
#   2) 幂等：已连上目标 SSID 直接退出；
#   3) 主 SSID 最多扫 3 轮（每轮 8s），扫不到才用备用 SSID；
#   4) **不主动断开**已有连接、不做法规域来回切换（旧实现这样干过，会让 5G 每 ~60s 掉线）。
set -u
TAG="zt1-wifi"
LOG=/var/log/zt1-wifi-connect.log
ENV_FILE=/etc/zerot1/config.env
log() { echo "$(date '+%F %T') [$TAG] $*" >>"$LOG"; }

[ -r "$ENV_FILE" ] || { echo "$(date '+%F %T') [$TAG] 缺少 $ENV_FILE，跳过" >>"$LOG"; exit 0; }
# shellcheck disable=SC1090
. "$ENV_FILE"

[ "${ENABLE_WIFI:-1}" = "1" ] || { log "ENABLE_WIFI=0，跳过"; exit 0; }
[ -n "${WIFI_SSID:-}" ] || { log "WIFI_SSID 为空，跳过"; exit 0; }
command -v nmcli >/dev/null 2>&1 || { log "nmcli 不存在，跳过"; exit 0; }

# 日志限长（保留最后 2000 行）
if [ -f "$LOG" ] && [ "$(wc -c <"$LOG" 2>/dev/null || echo 0)" -gt 262144 ]; then
    tail -n 2000 "$LOG" >"$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi

# 法规域：只设置一次（brcmfmac 需要一次「变更」才会把 country 下发给固件）
if [ -n "${WIFI_COUNTRY:-}" ] && command -v iw >/dev/null 2>&1; then
    iw reg set "$WIFI_COUNTRY" 2>/dev/null || true
    log "法规域：$(iw reg get 2>/dev/null | sed -n '2p')"
fi

# 等 NetworkManager 与 wlan0 就绪
for _ in $(seq 1 60); do nmcli -t general status >/dev/null 2>&1 && break; sleep 1; done
for _ in $(seq 1 30); do
    nmcli -t -f DEVICE,TYPE device status 2>/dev/null | grep -q '^wlan0:wifi$' && break
    sleep 1
done

name_of() { printf '%s' "${1//[^A-Za-z0-9_.-]/_}"; }
cur_ssid() { iw dev wlan0 link 2>/dev/null | awk '/SSID:/{print $2; exit}'; }
seen() { nmcli -t -f SSID device wifi list --rescan yes 2>/dev/null | grep -Fxq -- "$1"; }

connect() {   # $1=ssid $2=pass $3=hidden
    local ssid="$1" pass="$2" hidden="${3:-0}" name out rc
    name="$(name_of "$ssid")-zt1"
    if nmcli -t -f NAME connection show 2>/dev/null | grep -Fxq -- "$name"; then
        out=$(nmcli connection up "$name" 2>&1) && { log "已连上：$ssid"; return 0; }
        log "拉起已保存 profile 失败：$ssid（$(printf '%s' "$out" | tail -n 1)）"
        nmcli connection delete "$name" >/dev/null 2>&1 || true
    fi
    if [ "$hidden" = "1" ]; then
        out=$(nmcli device wifi connect "$ssid" password "$pass" name "$name" hidden yes 2>&1); rc=$?
    else
        out=$(nmcli device wifi connect "$ssid" password "$pass" name "$name" 2>&1); rc=$?
    fi
    if [ "$rc" -eq 0 ]; then
        nmcli connection modify "$name" connection.autoconnect yes >/dev/null 2>&1 || true
        log "连接成功：$ssid"
        return 0
    fi
    log "连接失败：$ssid（$(printf '%s' "$out" | tail -n 1)）"
    return 1
}

# 已连上主 SSID 就直接退出（幂等）
if [ "$(cur_ssid)" = "$WIFI_SSID" ]; then log "已在 $WIFI_SSID，跳过"; exit 0; fi

ok=0
if seen "$WIFI_SSID"; then
    connect "$WIFI_SSID" "$WIFI_PASSWORD" "$WIFI_HIDDEN" && ok=1
else
    for i in 1 2 3; do
        log "第 ${i} 轮未扫到主 SSID $WIFI_SSID，8s 后重扫"
        sleep 8
        if seen "$WIFI_SSID"; then
            connect "$WIFI_SSID" "$WIFI_PASSWORD" "$WIFI_HIDDEN" && { ok=1; break; }
        fi
    done
fi

# 主 SSID 连不上才用备用
if [ "$ok" -eq 0 ] && [ -n "${WIFI_FALLBACK_SSID:-}" ]; then
    log "主 SSID 不可用，尝试备用：$WIFI_FALLBACK_SSID"
    connect "$WIFI_FALLBACK_SSID" "$WIFI_FALLBACK_PASSWORD" 0 && ok=1
fi

# 优先级：NM 断线时优先回主 SSID（不遍历改写其它 profile）
if [ "$ok" -eq 1 ]; then
    nmcli connection modify "$(name_of "$WIFI_SSID")-zt1" connection.autoconnect-priority 20 >/dev/null 2>&1 || true
    if [ -n "${WIFI_FALLBACK_SSID:-}" ]; then
        nmcli connection modify "$(name_of "$WIFI_FALLBACK_SSID")-zt1" connection.autoconnect-priority 10 >/dev/null 2>&1 || true
    fi
    _ip=$(ip -4 addr show wlan0 2>/dev/null | awk '/inet /{print $2; exit}')
    log "wlan0 IP：${_ip:-无}"
fi

if [ "${ENABLE_SSH:-0}" = "1" ]; then
    systemctl start ssh 2>/dev/null || systemctl start sshd 2>/dev/null || true
fi
[ "$ok" -eq 0 ] && log "未能连接任何 WiFi（NM 会继续按 profile 自愈）"
exit 0
WIFI_EOF
chmod 755 "$ROOTFS/usr/local/sbin/zt1-wifi-connect.sh"
log "[43-config-env] 已安装 /usr/local/sbin/zt1-wifi-connect.sh"

# ── 3. systemd 服务 ─────────────────────────────────────────────────────────
cat > "$ROOTFS/etc/systemd/system/zt1-wifi-connect.service" <<'UNIT_EOF'
[Unit]
Description=zeroT1 first-boot WiFi auto connect (config: /etc/zerot1/config.env)
Documentation=file:///etc/zerot1/config.env
After=NetworkManager.service network-pre.target
Wants=NetworkManager.service
ConditionPathExists=/etc/zerot1/config.env

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/zt1-wifi-connect.sh
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
UNIT_EOF
mkdir -p "$ROOTFS/etc/systemd/system/multi-user.target.wants"
ln -sfn /etc/systemd/system/zt1-wifi-connect.service \
    "$ROOTFS/etc/systemd/system/multi-user.target.wants/zt1-wifi-connect.service"
log "[43-config-env] 已启用 zt1-wifi-connect.service"

# ── 3b. 清理旧版自动连 WiFi 代码（历史遗留）────────────────────────────────
# 早期镜像里有「5G 优先升级」脚本 + timer：每 2 分钟 nmcli disconnect 一次再重连，
# 是「5G 时有时无」的直接原因。现在 WiFi 只由 zt1-wifi-connect.sh 在首启一次连好，
# 这里把旧单元/脚本从 rootfs 里彻底删掉（升级镜像也干净）。
rm -f "$ROOTFS/usr/local/sbin/zt1-wifi-5g-upgrade.sh" \
      "$ROOTFS/etc/systemd/system/zt1-wifi-5g-upgrade.service" \
      "$ROOTFS/etc/systemd/system/zt1-wifi-5g-upgrade.timer" \
      "$ROOTFS/var/lib/zt1-wifi5g-attempts"
for _w in multi-user.target.wants timers.target.wants network-online.target.wants; do
    rm -f "$ROOTFS/etc/systemd/system/$_w/zt1-wifi-5g-upgrade.timer" \
          "$ROOTFS/etc/systemd/system/$_w/zt1-wifi-5g-upgrade.service"
done
log "[43-config-env] 已清理旧版 5G 升级单元（只保留 zt1-wifi-connect.service）"

# ── 4. SSH：root 可密码登录 ────────────────────────────────────────────────
if [ "$ENABLE_SSH" = "1" ]; then
    install -d -m 755 "$ROOTFS/etc/ssh/sshd_config.d"
    cat > "$ROOTFS/etc/ssh/sshd_config.d/00-zerot1.conf" <<'SSHD_EOF'
# zeroT1：允许 root 密码登录（首启没有普通用户，串口/WiFi 起来后要能 ssh 进来）
PermitRootLogin yes
PasswordAuthentication yes
UseDNS no
SSHD_EOF
    ln -sfn /lib/systemd/system/ssh.service \
        "$ROOTFS/etc/systemd/system/multi-user.target.wants/ssh.service"
    log "[43-config-env] sshd 已 enable（root 可密码登录）"
fi

# ── 5. root 密码 / 可选固定主机名 ──────────────────────────────────────────
if [ -n "$ROOT_PASSWORD" ] && [ -f "$ROOTFS/etc/shadow" ]; then
    if command -v openssl >/dev/null 2>&1; then
        HASH=$(openssl passwd -6 "$ROOT_PASSWORD")
    else
        HASH=$(python3 -c 'import crypt,sys; print(crypt.crypt(sys.argv[1], crypt.mksalt(crypt.METHOD_SHA512)))' "$ROOT_PASSWORD")
    fi
    awk -v h="$HASH" 'BEGIN{FS=OFS=":"} $1=="root"{$2=h} {print}' \
        "$ROOTFS/etc/shadow" > "$ROOTFS/etc/shadow.zt1tmp"
    mv "$ROOTFS/etc/shadow.zt1tmp" "$ROOTFS/etc/shadow"
    chmod 640 "$ROOTFS/etc/shadow"
    chown root:shadow "$ROOTFS/etc/shadow" 2>/dev/null || chown root:root "$ROOTFS/etc/shadow"
    log "[43-config-env] root 密码已按 config.env 设置"
fi

if [ -n "$DEVICE_HOSTNAME" ]; then
    echo "$DEVICE_HOSTNAME" > "$ROOTFS/etc/hostname"
    if [ -f "$ROOTFS/etc/hosts" ]; then
        sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$DEVICE_HOSTNAME/" "$ROOTFS/etc/hosts"
    fi
    log "[43-config-env] 固定主机名：$DEVICE_HOSTNAME"
fi

# ── 6. NetworkManager：关闭扫描随机 MAC（brcmfmac 设置随机 MAC 会报 -52，且易掉线）──
install -d -m 755 "$ROOTFS/etc/NetworkManager/conf.d"
cat > "$ROOTFS/etc/NetworkManager/conf.d/99-zt1.conf" <<'NM_EOF'
# zeroT1：扫描时不随机化 MAC（BCM43455 固件对 set_cur_etheraddr 返回 -52，且随机 MAC
# 会让 AP 侧会话/漫游判断变差）。连接时也不做 MAC 随机化。
[device]
wifi.scan-rand-mac-address=no

[connection]
wifi.cloned-mac-address=preserve
NM_EOF
log "[43-config-env] 已写入 NetworkManager 99-zt1.conf（关闭 MAC 随机化）"

# ── 7. 安装 iw（设置射频国家码；没有它 brcmfmac 固件停在 world 域，5G 频段扫不到）──
if [ -x "$ROOTFS/usr/sbin/iw" ] || [ -x "$ROOTFS/usr/bin/iw" ]; then
    log "[43-config-env] iw 已存在，跳过安装"
else
    if { command -v qemu-aarch64-static >/dev/null 2>&1 || [ -e "${QEMU_BIN:-/usr/bin/qemu-aarch64-static}" ]; } \
       && [ -f "$HERE/../../scripts/lib-chroot.sh" ]; then
        # shellcheck disable=SC1090
        source "$HERE/../../scripts/lib-chroot.sh"
        chroot_mount "$ROOTFS"
        trap 'chroot_umount "$ROOTFS"' EXIT
        chroot_run "$ROOTFS" /bin/bash -c '
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq 2>/dev/null || true
            apt-get install -y --no-install-recommends iw >/dev/null 2>&1 || true
            command -v iw >/dev/null 2>&1 && echo "[43] iw 安装成功" || echo "[43] WARN: iw 安装失败"
        '
        chroot_umount "$ROOTFS"
        trap - EXIT
        if [ -x "$ROOTFS/usr/sbin/iw" ] || [ -x "$ROOTFS/usr/bin/iw" ]; then
            log "[43-config-env] iw 已安装进镜像"
        else
            warn "[43-config-env] iw 未装成功（首启 5G 将不可用，2.4G 仍可连）"
        fi
    else
        warn "[43-config-env] 无 qemu/lib-chroot，跳过 iw 安装（首启 5G 将不可用）"
    fi
fi

log "[43-config-env] 完成（WiFi=$([ -n "$WIFI_SSID" ] && echo "$WIFI_SSID" || echo 未配置)，SSH=$ENABLE_SSH）"
