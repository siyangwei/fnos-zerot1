#!/bin/bash
# 一条命令刷写完整 update.img（等价于：sudo upgrade_tool_2.45 uf <img>）
#
# 用法：
#   sudo bash scripts/flash-image.sh [镜像路径]
#
# 默认镜像：output/ 下最新的 fnos-aiot3588a-*.img
#
# 说明：
#   - 板子需处于 MaskROM / Loader 模式（Rockusb 设备 2207:350b 或 2207:xxxx loader）
#   - 全程只调用 upgrade_tool uf，不再分 loader/uboot/rootfs 多步
#   - 刷完自动 rd 重启
set -euo pipefail

TOPDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="${UPGRADE_TOOL:-upgrade_tool_2.45}"

IMG="${1:-}"
if [[ -z $IMG ]]; then
    IMG=$(ls -t "$TOPDIR"/output/fnos-aiot3588a-*.img 2>/dev/null | head -1 || true)
fi
[[ -n $IMG && -f $IMG ]] || { echo "找不到镜像，请显式传入路径：bash scripts/flash-image.sh output/xxx.img" >&2; exit 1; }
command -v "$TOOL" >/dev/null || { echo "找不到 $TOOL（可用 UPGRADE_TOOL=... 指定）" >&2; exit 1; }

echo "镜像: $IMG ($(stat -c %s "$IMG") 字节)"
echo "sha256: $(sha256sum "$IMG" | awk '{print $1}')"
echo "工具: $(command -v "$TOOL")"
echo

# 检查 Rockusb 设备是否在线
if command -v lsusb >/dev/null; then
    if ! lsusb | grep -q "2207:"; then
        echo "未检测到 Rockchip USB 设备（2207:xxxx）。请先把板子切到 MaskROM 模式再试。" >&2
        exit 2
    fi
    lsusb | grep "2207:" | sed 's/^/  /'
    echo
fi

echo "开始整包刷写（upgrade_tool uf）..."
"$TOOL" uf "$IMG"
rc=$?
if [[ $rc -ne 0 ]]; then
    echo "uf 失败（rc=$rc）。可尝试：先 'upgrade_tool db assets/MiniLoaderAll.bin' 再重试；" >&2
    echo "或退回三步刷：bash scripts/flash-uboot-upstream.sh" >&2
    exit $rc
fi
echo "刷写完成，发送复位重启..."
"$TOOL" rd || true
echo "OK"
