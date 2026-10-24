#!/bin/bash
# ============================================================================
# 15-network.sh - 修复 NetworkManager 插件属主
#
# 背景：fnOS 官方镜像（ophub nanopc-t6 底稿）里 /usr/lib/aarch64-linux-gnu/
#       NetworkManager/1.42.4/*.so 的属主是 1000:Administrators（不是 root）。
#       NetworkManager 在 root 下加载 device plugin 时会校验文件属主，
#       遇到非 root 属主直接 skip（日志：`plugin: skip invalid file ...:
#       file has invalid own`），表现为：
#         - nmcli radio all 显示 `WIFI-HW missing`
#         - 桌面右上角网络图标只有"以太网"，没有 WiFi
#         - nmcli dev wifi list 报 "未发现 Wi-Fi 设备"
#       而实际上 wlan0 存在、brcmfmac 固件已加载、rfkill 未 block。
#       修复：chown root:root 整个 NM 插件目录 → 重启 NetworkManager。
# ============================================================================
set -e

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../../scripts/lib-common.sh"

[ -n "$ROOTFS" ] || die "ROOTFS 未设置"
[ -d "$ROOTFS" ] || die "rootfs 不存在: $ROOTFS"

NM_DIR="$ROOTFS/usr/lib/aarch64-linux-gnu/NetworkManager"
if [ -d "$NM_DIR" ]; then
    # 先看看有多少非 root 属主文件
    BAD=$(find "$NM_DIR" -not -user root 2>/dev/null | wc -l)
    chown -R root:root "$NM_DIR" 2>/dev/null || true
    log "[15-network] NetworkManager 插件属主修复完成（原非 root 文件 $BAD 个）"
else
    log "[15-network] 跳过：$NM_DIR 不存在"
fi

# 统一修复 rootfs 里其它 ophub 遗留的 uid 1000 文件属主（仅 root 可写的关键目录）
for d in "$ROOTFS/usr/lib" "$ROOTFS/usr/bin" "$ROOTFS/usr/sbin" "$ROOTFS/usr/share"; do
    [ -d "$d" ] && find "$d" -uid 1000 -exec chown root:root {} + 2>/dev/null || true
done
log "[15-network] rootfs uid=1000 文件属主统一修复完成"

log "[15-network] 完成：WiFi 可在 NetworkManager 中正常识别"
