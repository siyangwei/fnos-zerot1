#!/usr/bin/env bash
# 42-logclean.sh —— 清理开机日志刷屏 / 修复反复失败的服务
#
# 背景（2026-10-29 实测 `journalctl -p 3` + `dmesg` 计数）：
#   1. hdmi-audio-codec 在无显示器时 snd_soc_dai_prepare() 恒返回 -ENODEV，
#      dmesg/journal 每秒刷 "ASoC error (-19)"、"HDMI: Unknown ELD version 0"
#      （单次开机 2000+ 行）。根因在 DTS：本板不用 HDMI 音频，已把
#      &hdmi1_sound 置 disabled（见 dts/mainline-6.18/rk3588-aiot3588a.dts）。
#   2. upnp.service（fnOS 的 trim avahi 服务）缺 libupnp.so.13，status=127
#      每 1s 重启一次、日志狂刷。装 libupnp13 + libixml10 解决。
#   3. nut-monitor/nut-server 因为没有 UPS 直接 failed（ups.conf 为空）。
#      本板无 UPS，mask 掉。
#   4. eventlogger_service 开机早期会 SEGV 循环（日志停在
#      "failed to get system lang conf: Couldn't connect to server" 之后），
#      等 trim_main 起来后自己就好了。加 10s 启动延迟 + 无限重启退避，
#      避免开机前 20 分钟一直刷 "status=11/SEGV"。
#   5. journald 没有大小上限，/var/log/journal 会一直涨；限制到 200MB。
#   6. sshd 默认 disabled，刷完机只能用串口开；这里直接 enable。
#   7. brcmfmac 找不到板级 firmware 名 brcmfmac43456-sdio.shimeta,aiot-3588a.bin，
#      用软链指向通用文件，去掉一条 -2 报错。
#
# 用法: 42-logclean.sh <rootfs-dir>
set -euo pipefail

ROOTFS="${1:?usage: $0 <rootfs-dir>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../scripts/lib-chroot.sh"

# ---- 纯文件操作（不需要 chroot）----
# journald 体积上限
mkdir -p "$ROOTFS/etc/systemd/journald.conf.d"
cat > "$ROOTFS/etc/systemd/journald.conf.d/50-size.conf" <<'EOF'
[Journal]
SystemMaxUse=200M
RuntimeMaxUse=64M
SystemMaxFileSize=32M
EOF

# nut：本板没有 UPS
mkdir -p "$ROOTFS/etc/systemd/system"
for u in nut-monitor.service nut-server.service; do
    ln -sfn /dev/null "$ROOTFS/etc/systemd/system/$u"
done
rm -f "$ROOTFS/etc/systemd/system/nut.target.wants/nut-monitor.service" \
      "$ROOTFS/etc/systemd/system/nut.target.wants/nut-server.service" 2>/dev/null || true
# masked 单元可能还散落在 multi-user.target.wants
rm -f "$ROOTFS"/etc/systemd/system/*.wants/nut-{monitor,server}.service 2>/dev/null || true

# eventlogger：开机早期避开 trim_main 未就绪的时间窗
mkdir -p "$ROOTFS/etc/systemd/system/eventlogger_service.service.d"
cat > "$ROOTFS/etc/systemd/system/eventlogger_service.service.d/10-boot-safety.conf" <<'EOF'
[Unit]
# 开机早期 trim_main 的 lang 配置 RPC 还没起来，eventlogger 会 SEGV 循环；
# 延后启动并放开重启间隔，避免日志刷 "status=11/SEGV"。
StartLimitIntervalSec=0

[Service]
# ★locale 是 SEGV 的直接触发点（2026-11-05 复现：1.2.1000 上仍会 SEGV）。
# 固定 C locale 后进程正常工作；缺这一行时日志应用会一直报「该App未安装或未启动」。
Environment=LANG=C LC_ALL=C
ExecStartPre=/bin/sleep 10
RestartSec=10
EOF

# sshd 开机自启（否则刷完机只能串口登）
mkdir -p "$ROOTFS/etc/systemd/system/multi-user.target.wants"
ln -sfn /lib/systemd/system/ssh.service \
    "$ROOTFS/etc/systemd/system/multi-user.target.wants/ssh.service"

# brcmfmac 板级固件名软链
FW_DIR="$ROOTFS/usr/lib/firmware/brcm"
if [ -f "$FW_DIR/brcmfmac43456-sdio.bin" ]; then
    ln -sfn brcmfmac43456-sdio.bin \
        "$FW_DIR/brcmfmac43456-sdio.shimeta,aiot-3588a.bin"
fi

# ---- chroot：装 libupnp（upnp.service 依赖）----
if command -v qemu-aarch64-static >/dev/null 2>&1 || [ -e "$QEMU_BIN" ]; then
    chroot_mount "$ROOTFS"
    trap 'chroot_umount "$ROOTFS"' EXIT

    chroot_run "$ROOTFS" /bin/bash -c '
set -e
export DEBIAN_FRONTEND=noninteractive
if ! ldconfig -p | grep -q "libupnp.so.13"; then
    apt-get update -qq || true
    apt-get install -y --no-install-recommends libupnp13 libixml10 \
        || apt-get install -y --no-install-recommends libupnp13 \
        || echo "[42] WARN: libupnp13 安装失败，upnp 服务仍会重启（非致命）"
fi
ldconfig || true
'
    chroot_umount "$ROOTFS"
    trap - EXIT
else
    echo "[42] 未找到 qemu-aarch64-static，跳过 libupnp 安装"
fi

# ---- 收尾：清 apt 缓存，避免把 100MB+ 的 lists/archives 打进镜像 ----
rm -rf "$ROOTFS"/var/lib/apt/lists/* "$ROOTFS"/var/cache/apt/archives/*.deb \
       "$ROOTFS"/var/cache/apt/pkgcache.bin "$ROOTFS"/var/cache/apt/srcpkgcache.bin 2>/dev/null || true
rm -rf "$ROOTFS"/tmp/* 2>/dev/null || true

echo "[42-logclean] done"
