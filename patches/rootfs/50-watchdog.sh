#!/usr/bin/env bash
# 50-watchdog.sh —— 看门狗用户态配置
#
# 内核驱动 smdt_mcu_wdt（本仓库 patches/kernel/0001-add-smdt-mcu-watchdog.patch）
# 已经在板载 STM8S00K3 MCU 上注册了标准 /dev/watchdog（WATCHDOG_CORE）。
# 这里做两件事：
#   1) 让 systemd 自己拿 watchdog 并定期喂狗（RuntimeWatchdogSec）
#   2) 安装 watchdog 工具包，便于调试（wdctl 看状态）
#
# 注意：MCU 约 603 秒收不到喂狗就复位 SoC，systemd 每 30s 喂一次足够。
#
# 用法: 50-watchdog.sh <rootfs-dir>
set -euo pipefail

ROOTFS="${1:?usage: $0 <rootfs-dir>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../scripts/lib-chroot.sh"

mkdir -p "$ROOTFS/etc/systemd/system.conf.d"
cat > "$ROOTFS/etc/systemd/system.conf.d/10-watchdog.conf" <<'EOF'
[Manager]
# 使用内核 watchdog（smdt_mcu_wdt，对应板载 MCU）
RuntimeWatchdogSec=30s
RebootWatchdogSec=2min
EOF

# 安装 watchdog 用户态工具（wdctl 用来查看）
if command -v qemu-aarch64-static >/dev/null 2>&1 || [ -e "$QEMU_BIN" ]; then
    chroot_mount "$ROOTFS"
    trap 'chroot_umount "$ROOTFS"' EXIT
    chroot_run "$ROOTFS" /bin/bash -c '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq 2>/dev/null || true
    apt-get install -y --no-install-recommends watchdog 2>/dev/null || true
    ' || echo "[50-watchdog] WARN: watchdog 包安装失败（不影响内核驱动生效）"
    chroot_umount "$ROOTFS"; trap - EXIT
else
    echo "[50-watchdog] 未找到 qemu-aarch64-static，跳过 watchdog 工具安装"
fi

echo "[50-watchdog] 完成: RuntimeWatchdogSec=30s"
