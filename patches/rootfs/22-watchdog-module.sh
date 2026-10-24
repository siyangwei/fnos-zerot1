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

echo "  已安装 smdt_mcu_wdt.ko 到 $MODDIR"
