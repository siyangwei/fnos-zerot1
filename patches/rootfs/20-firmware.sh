#!/usr/bin/env bash
# 20-firmware.sh —— 安装 WiFi / 蓝牙固件
#
# 板子用的是 AP6256（WiFi: brcmfmac43456-sdio + BT: BCM4345C0.hcd），
# 友善的 sd-fuse prebuilt/firmware 里自带这些固件，本项目把它们
# 放进 assets/firmware/（已入库，构建时无需再下载）。
#
# 用法: 20-firmware.sh <rootfs-dir> <assets-dir>
set -euo pipefail

ROOTFS="${1:?usage: $0 <rootfs-dir> <assets-dir>}"
ASSETS="${2:?usage: $0 <rootfs-dir> <assets-dir>}"

FW_DST="$ROOTFS/usr/lib/firmware"
FW_SRC="$ASSETS/firmware"

[ -d "$FW_SRC" ] || { echo "[20-firmware] ERROR: $FW_SRC 不存在"; exit 1; }

mkdir -p "$FW_DST/brcm"
cp -f "$FW_SRC/brcm/brcmfmac43456-sdio.bin" "$FW_DST/brcm/"
cp -f "$FW_SRC/brcm/brcmfmac43456-sdio.txt" "$FW_DST/brcm/"

# 蓝牙（hci_uart 走 ttyS9，固件路径 /lib/firmware/BCM4345C0.hcd）
cp -f "$FW_SRC/BCM4345C0.hcd" "$FW_DST/"

# 无线监管数据库（否则 wpa_supplicant 起动时报警）
[ -f "$FW_SRC/regulatory.db" ]     && cp -f "$FW_SRC/regulatory.db" "$FW_DST/"
[ -f "$FW_SRC/regulatory.db.p7s" ] && cp -f "$FW_SRC/regulatory.db.p7s" "$FW_DST/"

# 兼容 /lib/firmware 是真实目录（不是 /usr/lib 的软链）的发行版
if [ -d "$ROOTFS/lib/firmware" ] && [ ! -e "$ROOTFS/lib/firmware/brcm/brcmfmac43456-sdio.bin" ]; then
    cp -f "$FW_SRC/brcm/brcmfmac43456-sdio.bin" "$ROOTFS/lib/firmware/brcm/" 2>/dev/null || true
    cp -f "$FW_SRC/brcm/brcmfmac43456-sdio.txt" "$ROOTFS/lib/firmware/brcm/" 2>/dev/null || true
    cp -f "$FW_SRC/BCM4345C0.hcd" "$ROOTFS/lib/firmware/" 2>/dev/null || true
fi

echo "[20-firmware] 完成:"
ls -l "$FW_DST/brcm/brcmfmac43456-sdio."* "$FW_DST/BCM4345C0.hcd"
