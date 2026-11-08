#!/usr/bin/env bash
# =====================================================================
#  实验：把板子的 u-boot 换成上游（upstream）v2026.10
#  - 需要板子处于 MaskROM 模式（lsusb 可见 2207:350b）
#  - 只写 loader1(0x40) 与 loader2(0x4000)，其余分区不动
#  - 回退：assets/MiniLoaderAll.bin + assets/uboot.img（同样 MaskROM 写入）
# =====================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
TOOL="${UPGRADE_TOOL:-upgrade_tool_2.45}"
A=assets; U=$A/uboot-upstream

need() { command -v "$1" >/dev/null || { echo "缺少命令: $1"; exit 1; }; }
need sudo
[ -f "$U/idbloader.img" ] || { echo "缺少 $U/idbloader.img（先构建）"; exit 1; }
[ -f "$U/u-boot.itb" ]    || { echo "缺少 $U/u-boot.itb"; exit 1; }
[ -f "$A/MiniLoaderAll.bin" ] || { echo "缺少 $A/MiniLoaderAll.bin（upgrade_tool 需要 loader）"; exit 1; }

echo "== 检测 MaskROM/Loader 设备 =="
lsusb | grep -E "2207:(350b|3000|110a)" || { echo "未发现 Rockchip 设备，请把板子切到 MaskROM 并接 USB"; exit 1; }

echo "== 1) 下载 loader 到 RAM（仅用于 upgrade_tool 通信）=="
sudo "$TOOL" db "$A/MiniLoaderAll.bin"

echo "== 2) 写入上游 idbloader（0x40）=="
sudo "$TOOL" wl 0x40 "$U/idbloader.img"

echo "== 3) 写入上游 u-boot.itb（0x4000）=="
sudo "$TOOL" wl 0x4000 "$U/u-boot.itb"

echo "== 4) 复位启动 =="
sudo "$TOOL" rd
echo "完成。请观察串口（/dev/ttyACM1 1500000 8N1）或 HDMI。"
