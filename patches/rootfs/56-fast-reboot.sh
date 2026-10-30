#!/bin/bash
# 56-fast-reboot.sh —— 「最快重启」：reboot 时直接写 CRU GLB_SRST_FST，跳过 PSCI+PMIC 的 ~90s 空档
#
# 背景（2026-10-30 实测）：
#   systemctl reboot / sysrq-b / kexec 都走 PSCI SYSTEM_RESET → BL31 → RK806 → 整板上下电，
#   实测「Rebooting.」到内核重新起来约 90~120s（红灯空档）。
#   而直接写 RK3588 CRU 的 GLB_SRST_FST（0xfd7c0000 + 0xc08 = 0xfd7c0c08，值 0xfdb9）
#   约 4 秒就能重新进内核（u-boot `reset` 走的也是这条）。
#
# 实现：systemd-shutdown 钩子，只在 reboot 时执行；写入后 SoC 立即复位，脚本不会返回。
set -e
ROOTFS="${1:?用法: 56-fast-reboot.sh <rootfs-dir>}"
log() { echo "[56-fast-reboot] $*"; }

install -d -m 0755 "$ROOTFS/usr/lib/systemd/system-shutdown"
cat > "$ROOTFS/usr/lib/systemd/system-shutdown/zt1-fast-reboot.sh" <<'EOS'
#!/bin/sh
# systemd-shutdown 钩子：仅 reboot 时用 CRU 直接复位（比 PSCI+PMIC 快 ~90s）
[ "${1:-}" = "reboot" ] || exit 0
CRU_REG=0xfd7c0c08
VAL=0xfdb9
# 1) busybox devmem（镜像内有 busybox）
if command -v busybox >/dev/null 2>&1; then
    busybox devmem "$CRU_REG" 32 "$VAL" 2>/dev/null && { sleep 5; exit 0; }
fi
# 2) 兜底：dd 写 /dev/mem（小端 0xfdb9 → 字节 b9 fd 00 00）
if [ -c /dev/mem ]; then
    printf '\271\375\000\000' | dd of=/dev/mem bs=1 seek=$((CRU_REG)) conv=notrunc 2>/dev/null \
        && { sleep 5; exit 0; }
fi
exit 0
EOS
chmod 0755 "$ROOTFS/usr/lib/systemd/system-shutdown/zt1-fast-reboot.sh"
log "已安装 systemd-shutdown 快速重启钩子（CRU GLB_SRST_FST）"
