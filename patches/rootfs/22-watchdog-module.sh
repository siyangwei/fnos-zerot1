#!/usr/bin/env bash
# 22-watchdog-module.sh —— 安装板载 MCU 看门狗 .ko（fnOS 官方内核）
#
# fnOS 的 6.18.18-trim 内核没有 smdt_mcu_wdt 驱动源码，我们在板子上用
# 它自带的 /usr/src/linux-headers-6.18.18-trim 原生编译出 .ko（源码
# patches/kernel/0001-add-smdt-mcu-watchdog.patch + 两处 6.18 适配：
# .probe_new -> .probe）。产物已随仓库提交：assets/modules/6.18.18-trim/
#
# 不喂狗时板载 MCU 约 603s 复位 SoC（现象=无故重启），所以必须装。
#
# 用法: 22-watchdog-module.sh <rootfs-dir>
set -euo pipefail
ROOTFS="${1:?usage: $0 <rootfs-dir>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
MODDIR="$ROOTFS/lib/modules/6.18.18-trim/updates/zerot1"

install -D -m 644 "$HERE/../../assets/modules/6.18.18-trim/smdt_mcu_wdt.ko" \
    "$MODDIR/smdt_mcu_wdt.ko"

# 让 modprobe 能按 DT modalias（smdtmcu,STM8S00K3）自动加载
depmod -b "$ROOTFS" 6.18.18-trim 2>/dev/null || \
    echo "  [warn] depmod 失败，请确认宿主机有 kmod"

# 关键：开机必须加载本驱动，否则关机时驱动的 .shutdown 不会执行，
# 板载 MCU 会一直保持 armed（0x32=0x01），重启时 MCU 可能拉住 SoC 复位线
# → 表现为「重启后红灯 1-2 分钟 / 偶发卡死」。驱动 .shutdown 会写 0x32=0x00
# 主动 disarm（与厂商 daemon 行为一致）。
install -D -m 644 /dev/stdin "$ROOTFS/etc/modules-load.d/zt1-mcu-wdt.conf" <<'EOF'
# 板载 STM8S00K3 MCU 看门狗：开机加载以便 pid1/驱动管理，关机 .shutdown 会 disarm。
smdt_mcu_wdt
EOF

echo "  已安装 smdt_mcu_wdt.ko 到 $MODDIR，并加入 modules-load.d/zt1-mcu-wdt.conf"
