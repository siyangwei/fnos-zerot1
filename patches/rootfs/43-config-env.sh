#!/bin/bash
# ============================================================================
# 43-config-env.sh - config.env 落盘 + 首启连 WiFi + SSH 可登录
#
# 读取仓库根目录的 config.env（由 scripts/lib-common.sh 加载，外部环境变量优先），
# 把配置写进镜像：
#   /etc/zerot1/config.env                构建配置副本（root 600，供开机脚本读取）
#   /usr/local/sbin/zt1-wifi-connect.sh   首启连 WiFi 脚本（读 /etc/zerot1/config.env）
#   /etc/systemd/system/zt1-wifi-connect.service  开机执行上面脚本
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
# zt1-wifi-connect.sh —— 读取 /etc/zerot1/config.env，把设备连到配置的 WiFi
# 幂等：已连上就直接退出；连不上（不在范围/密码错）会在日志里留原因，然后退出 0
# 日志：/var/log/zt1-wifi-connect.log
set -u

ENV_FILE="/etc/zerot1/config.env"
LOG="/var/log/zt1-wifi-connect.log"
TAG="zt1-wifi"

log() { printf '%s [%s] %s\n' "$(date '+%F %T')" "$TAG" "$*" | tee -a "$LOG" >/dev/null; }

[ -r "$ENV_FILE" ] || { echo "$(date '+%F %T') [$TAG] 缺少 $ENV_FILE，跳过" >>"$LOG"; exit 0; }
# shellcheck disable=SC1090
. "$ENV_FILE"

[ "${ENABLE_WIFI:-1}" = "1" ] || { log "ENABLE_WIFI=0，跳过"; exit 0; }
[ -n "${WIFI_SSID:-}" ]      || { log "WIFI_SSID 为空，跳过"; exit 0; }

command -v nmcli >/dev/null 2>&1 || { log "nmcli 不存在，跳过"; exit 0; }

# 日志限长（保留最后 2000 行）
if [ -f "$LOG" ] && [ "$(wc -c <"$LOG" 2>/dev/null || echo 0)" -gt 262144 ]; then
    tail -n 2000 "$LOG" >"$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi

# 第 0 步：国家码（brcmfmac 默认用固件 world 法规域，5G 只剩 2.4G+5.8G；
# 必须把国家码写给固件，5150-5350(信道36-64) 才会被扫描/连接。实测 CN 可行：
#   iw reg set CN 后 scan 出现 5300MHz 的 AP，连接 5G 成功（263/390 Mbps）
if [ -n "${WIFI_COUNTRY:-}" ] && command -v iw >/dev/null 2>&1; then
    for _ in 1 2 3; do
        iw reg set "$WIFI_COUNTRY" 2>/dev/null || true
        sleep 2
        iw reg get 2>/dev/null | grep -q "$WIFI_COUNTRY" && break
    done
    log "国家码：$(iw reg get 2>/dev/null | head -2 | tr '\n' ' ')"
else
    log "iw 不可用，跳过国家码设置（5G 可能不可见）"
fi

# 第 1 步：等 NetworkManager 与 wlan0 就绪（最多 60s）
for _ in $(seq 1 60); do
    nmcli -t general status >/dev/null 2>&1 && break
    sleep 1
done
for _ in $(seq 1 30); do
    nmcli -t -f DEVICE,TYPE device status 2>/dev/null | grep -q '^wlan0:wifi$' && break
    sleep 1
done

connect_one() {
    local ssid="$1" pass="$2" hidden="${3:-0}" name out
    name="${ssid//[^A-Za-z0-9_.-]/_}-zt1"

    # 已存在同名连接：直接拉起（NM 已保存过 PSK）
    if nmcli -t -f NAME connection show 2>/dev/null | grep -Fxq "$name"; then
        if nmcli -t -f NAME connection show --active 2>/dev/null | grep -Fxq "$name"; then
            log "已连接：$ssid"
            return 0
        fi
        out=$(nmcli connection up "$name" 2>&1) && { log "已拉起已保存的连接 $ssid"; return 0; }
        log "拉起已保存连接失败（$ssid）：$(echo "$out" | tail -n 2 | tr '\n' ' ')"
    fi

    # 新建连接（-- 语义：hidden 需显式声明）
    if [ "$hidden" = "1" ]; then
        out=$(nmcli device wifi connect "$ssid" password "$pass" name "$name" hidden yes 2>&1)
    else
        out=$(nmcli device wifi connect "$ssid" password "$pass" name "$name" 2>&1)
    fi
    if [ $? -eq 0 ]; then
        nmcli connection modify "$name" connection.autoconnect yes 2>/dev/null || true
        nmcli connection modify "$name" connection.autoconnect-priority 10 2>/dev/null || true
        log "连接成功：$ssid（已设为自动连接）"
        return 0
    fi
    log "连接失败（$ssid）：$(echo "$out" | tail -n 2 | tr '\n' ' ')"
    return 1
}

try_with_retry() {
    local ssid="$1" pass="$2" hidden="$3" i
    for i in 1 2 3; do
        connect_one "$ssid" "$pass" "$hidden" && return 0
        sleep 5
    done
    return 1
}

scan_has() {
    nmcli -t -f SSID device wifi list --rescan yes 2>/dev/null | grep -Fxq -- "$1"
}

OK=0
# 第 2 步：主 SSID（先扫描确认；扫不到等一轮再扫一次，避免盲连白等）
if scan_has "$WIFI_SSID"; then
    log "扫描到主 SSID：$WIFI_SSID"
    try_with_retry "$WIFI_SSID" "$WIFI_PASSWORD" "$WIFI_HIDDEN" && OK=1
else
    log "未扫到主 SSID '$WIFI_SSID'，8s 后重扫"
    sleep 8
    if scan_has "$WIFI_SSID"; then
        log "重扫到主 SSID：$WIFI_SSID"
        try_with_retry "$WIFI_SSID" "$WIFI_PASSWORD" "$WIFI_HIDDEN" && OK=1
    else
        log "仍未扫到主 SSID，改走备用"
    fi
fi

# 第 3 步：备用 SSID
if [ "$OK" -eq 0 ] && [ -n "${WIFI_FALLBACK_SSID:-}" ]; then
    log "尝试备用 WiFi：$WIFI_FALLBACK_SSID"
    try_with_retry "$WIFI_FALLBACK_SSID" "$WIFI_FALLBACK_PASSWORD" "0" && OK=1
fi

# 第 4 步：防止 NM 在两个频段的 profile 间来回跳（之前 5G profile 拉不起来会把 2.4G 踢掉）
if [ "$OK" -eq 1 ]; then
    ACT=$(nmcli -t -f NAME,TYPE connection show --active 2>/dev/null | awk -F: '$2=="802-11-wireless"{print $1; exit}')
    for n in $(nmcli -t -f NAME,TYPE connection show 2>/dev/null | awk -F: '$2=="802-11-wireless"{print $1}'); do
        if [ "$n" = "$ACT" ]; then
            nmcli connection modify "$n" connection.autoconnect yes connection.autoconnect-priority 20 >/dev/null 2>&1 || true
        else
            nmcli connection modify "$n" connection.autoconnect no >/dev/null 2>&1 || true
        fi
    done
    log "当前连接：${ACT:-未知}（其它 WiFi profile 已关闭自动连接，防频段互踢）"
fi

if [ "$OK" -eq 1 ]; then
    IP=$(ip -4 -o addr show wlan0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
    log "WiFi 就绪，wlan0 IP=${IP:-未知}"
    iw dev wlan0 link 2>/dev/null | grep -E 'SSID|freq|signal|bitrate' | tr '\n' ' ' | sed 's/^/  链路：/' >>"$LOG"
    # SSH 兜底（镜像里已 enable，这里再确保一次）
    systemctl start ssh 2>/dev/null || true
else
    log "本次未连上 WiFi（可在联网后手动 nmcli，或重插电源重试）"
fi

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
