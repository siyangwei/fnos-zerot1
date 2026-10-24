#!/usr/bin/env bash
# 95-diag-console.sh —— 开机把显示/音频/模块加载诊断打到串口控制台（临时）
#
# 用途：fnOS 官方内核对本板是 headless 的，eDP 不亮时需要知道
# rockchipdrm/hdptx/panel-simple 这几个模块到底有没有加载、失败原因是什么。
# 开启时每次启动会往 /dev/console 打印一段诊断，排查完删掉
# /etc/zerot1-diag.enable 即可关闭（不需要重新出镜像）。
#
# 用法: 95-diag-console.sh <rootfs-dir>
set -euo pipefail
ROOTFS="${1:?usage: $0 <rootfs-dir>}"

mkdir -p "$ROOTFS/usr/local/sbin"
cat > "$ROOTFS/usr/local/sbin/zerot1-diag.sh" <<'SCRIPT'
#!/bin/sh
# zeroT1 启动诊断（临时，删除 /etc/zerot1-diag.enable 即关闭）
exec > /dev/console 2>&1
echo ""
echo "============= zeroT1 diag start ============="
echo "--- systemd-modules-load status ---"
systemctl --no-pager --no-legend status systemd-modules-load.service 2>&1 | head -25
echo "--- lsmod (filtered) ---"
lsmod | grep -Ei "drm|hdptx|panel|es8328|i2s|dwmac|stmmac|smdt" || echo "(none of interest loaded)"
echo "--- modprobe -v rockchipdrm ---"
modprobe -v rockchipdrm 2>&1 || echo "modprobe rockchipdrm failed ($?)"
echo "--- /proc/modules | rockchip ---"
grep -i rockchip /proc/modules || echo "(rockchip modules absent)"
echo "--- /dev/dri ---"
ls -l /dev/dri 2>&1 || true
echo "--- dmesg (drm/edp/hdptx/panel/es8328/i2s) ---"
dmesg | grep -iE "drm|vop|edp|hdptx|panel|es8328|i2s" | tail -60
echo "--- aplay -l ---"
aplay -l 2>&1 | head -20 || true
echo "============= zeroT1 diag end =============="
SCRIPT
chmod +x "$ROOTFS/usr/local/sbin/zerot1-diag.sh"

cat > "$ROOTFS/etc/systemd/system/zerot1-diag.service" <<'UNIT'
[Unit]
Description=zeroT1 boot diagnostics (temporary)
After=local-fs.target systemd-modules-load.service
ConditionPathExists=/etc/zerot1-diag.enable

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/zerot1-diag.sh
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

touch "$ROOTFS/etc/zerot1-diag.enable"
mkdir -p "$ROOTFS/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/zerot1-diag.service \
    "$ROOTFS/etc/systemd/system/multi-user.target.wants/zerot1-diag.service"

echo "  已启用 zerot1-diag.service（诊断输出到串口）"
