#!/usr/bin/env bash
# 53-rk806-rstfix.sh —— 修「Linux 软件重启卡死 / Web 重启不可用」（RK806 PMIC 复位模式）
#
# 现象：systemctl reboot / 飞牛 Web 重启 → systemd-shutdown 打完 `Rebooting.` 后串口静默、
#       无 DDR/U-Boot、红灯、网络不通（只能断电）。
# 根因：RK806 PMIC `SYS_CFG3`(0x72) bit[7:6] = RST_FUN，厂商 DT 用 pmic-reset-func=<1>(MODE1)，
#       厂商 u-boot 与 Android 内核都会写；我们 mainline 侧不支持 → 实测本板为 0x02(RST_FUN=0)，
#       SoC 复位后 PMIC 不做整板复位 ⇒ 卡死。
# 修法：把 rk806_rstfix.ko 开机加载，模块 init 时把 RST_FUN 写成 MODE1（默认 mode=1）。
#       实测：写入后 `systemctl reboot` 可完整重启（DDR→U-Boot→内核→登录）。
#
# 用法: 53-rk806-rstfix.sh <rootfs-dir>
set -euo pipefail

ROOTFS="${1:?usage: $0 <rootfs-dir>}"
KVER="6.18.18-trim"
MODBASE="$ROOTFS/lib/modules/$KVER"
SRC="$(cd "$(dirname "$0")/../.." && pwd)/assets/modules/$KVER"

[ -d "$MODBASE" ] || { echo "  跳过：rootfs 中没有 $KVER 模块目录"; exit 0; }

# ---- 1. 确保模块就位（27-vendor-modules.sh 也会装，这里做幂等兜底）----
if [ -f "$SRC/rk806_rstfix.ko" ]; then
    mkdir -p "$MODBASE/updates/zerot1"
    install -m 644 "$SRC/rk806_rstfix.ko" "$MODBASE/updates/zerot1/rk806_rstfix.ko"
    echo "  安装: rk806_rstfix.ko -> /lib/modules/$KVER/updates/zerot1"
else
    echo "  警告: $SRC/rk806_rstfix.ko 不存在，跳过（重启卡死问题不会修复）"
fi

# ---- 2. 开机自动加载 ----
mkdir -p "$ROOTFS/etc/modules-load.d"
cat > "$ROOTFS/etc/modules-load.d/zt1-rk806-rstfix.conf" <<'CONF'
# zeroT1：把 RK806 PMIC 的 SYS_CFG3.RST_FUN 置 MODE1，修复「软件重启卡死」
# 对应厂商 DT 的 pmic-reset-func = <1>；mainline rk8xx 驱动不支持该属性，用模块补。
rk806_rstfix
CONF
echo "  已写入 /etc/modules-load.d/zt1-rk806-rstfix.conf（开机加载 rk806_rstfix）"

# ---- 3. 重建依赖索引 ----
if command -v depmod >/dev/null 2>&1; then
    depmod -b "$ROOTFS" "$KVER" 2>/dev/null || depmod -b "$ROOTFS" -a "$KVER" 2>/dev/null || true
    echo "  已执行 depmod -b $ROOTFS $KVER"
fi

chmod -R a+rX "$MODBASE" 2>/dev/null || true
echo "  完成: RK806 复位模式修复"
