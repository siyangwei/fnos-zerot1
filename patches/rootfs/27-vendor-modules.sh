#!/usr/bin/env bash
# 27-vendor-modules.sh —— 安装项目自编译的 out-of-tree 内核模块（analogix_dp / brcmfmac）
#
# 为什么需要：
#   * analogix_dp.ko  —— 我们改过（eDP 400ms 重试、132MHz 时序、ZT1 调试参数），
#                        原版模块没有这些逻辑，eDP 会黑屏。
#   * brcmfmac*.ko    —— 原版模块缺少 CONFIG_BRCMFMAC* 相关宏，加载失败（-EINVAL），
#                        WiFi 不可用；我们重编的版本才正常。
#
# 用法: 27-vendor-modules.sh <rootfs-dir>
set -euo pipefail

ROOTFS="${1:?usage: $0 <rootfs-dir>}"
KVER="6.18.18-trim"
MODBASE="$ROOTFS/lib/modules/$KVER"
SRC="$(cd "$(dirname "$0")/../.." && pwd)/prebuilts/modules/$KVER"

[ -d "$MODBASE" ] || { echo "  跳过：rootfs 中没有 $KVER 模块目录"; exit 0; }
[ -d "$SRC" ] || { echo "  跳过：$SRC 不存在"; exit 0; }

# ---- 1. analogix_dp.ko（覆盖官方模块，保持原路径）----
if [ -f "$SRC/analogix_dp.ko" ]; then
    dst="$MODBASE/kernel/drivers/gpu/drm/bridge/analogix/analogix_dp.ko"
    mkdir -p "$(dirname "$dst")"
    install -m 644 "$SRC/analogix_dp.ko" "$dst"
    echo "  安装: analogix_dp.ko -> ${dst#$ROOTFS}"
fi

# ---- 2. brcmfmac 三件套（覆盖官方模块）----
for m in brcmfmac brcmutil brcmfmac-wcc; do
    [ -f "$SRC/$m.ko" ] || continue
    case "$m" in
        brcmutil) dst="$MODBASE/kernel/drivers/net/wireless/broadcom/brcm80211/brcmutil/$m.ko" ;;
        *)        dst="$MODBASE/kernel/drivers/net/wireless/broadcom/brcm80211/brcmfmac/$m.ko" ;;
    esac
    mkdir -p "$(dirname "$dst")"
    install -m 644 "$SRC/$m.ko" "$dst"
    echo "  安装: $m.ko -> ${dst#$ROOTFS}"
done

# ---- 3. 其他 prebuilt 模块（如 smdt_mcu_wdt.ko）放进 updates/zerot1 ----
mkdir -p "$MODBASE/updates/zerot1"
for ko in "$SRC"/*.ko; do
    b="$(basename "$ko")"
    case "$b" in analogix_dp.ko|brcmfmac.ko|brcmutil.ko|brcmfmac-wcc.ko) continue ;; esac
    install -m 644 "$ko" "$MODBASE/updates/zerot1/$b"
    echo "  安装: $b -> ${MODBASE#$ROOTFS}/updates/zerot1"
done

# ---- 4. 重建依赖索引 ----
if command -v depmod >/dev/null 2>&1; then
    depmod -b "$ROOTFS" "$KVER" 2>/dev/null || depmod -b "$ROOTFS" -a "$KVER" 2>/dev/null || true
    echo "  已执行 depmod -b $ROOTFS $KVER"
fi

# 可执行权限（模块目录原样即可）
chmod -R a+rX "$MODBASE" 2>/dev/null || true
echo "  完成: 自定义内核模块安装"
