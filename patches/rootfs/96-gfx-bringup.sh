#!/usr/bin/env bash
# 96-gfx-bringup.sh —— 开机强制拉起显示链路并把结果打到串口 + 存盘（临时诊断）
#
# fnOS 官方内核是 headless 的：rockchipdrm / hdptx phy / panel-simple 都是模块。
# 实测发现三个模块都能加载，但 /dev/dri 不出现 ⇒ 大概率卡在 component/
# deferred-probe（模块加载太晚，master 不再重试）。
# 这里显式 modprobe + 尝试手工 bind + 抓 dmesg，输出同时写 /dev/console 和
# /root/zt1-gfx.txt（串口丢字节时可事后读文件）。
#
# 用法: 96-gfx-bringup.sh <rootfs-dir>
set -euo pipefail
ROOTFS="${1:?usage: $0 <rootfs-dir>}"

mkdir -p "$ROOTFS/usr/local/sbin"
cat > "$ROOTFS/usr/local/sbin/zerot1-gfx.sh" <<'SCRIPT'
#!/bin/sh
OUT=/root/zt1-gfx.txt
run() {
    echo ""
    echo "============= ZT1GFX $(date +%T) ============="
    for m in phy-rockchip-samsung-hdptx panel-simple rockchipdrm; do
        echo "--- modprobe -v $m ---"
        modprobe -v "$m" 2>&1 || echo "!! modprobe $m rc=$?"
    done
    echo "--- lsmod ---"
    lsmod | grep -Ei "drm|hdptx|panel" || echo "(none)"
    echo "--- /dev/dri ---"
    ls -l /dev/dri 2>&1 || true
    echo "--- platform drivers with drm/display ---"
    ls /sys/bus/platform/drivers 2>/dev/null | grep -Ei "drm|display" || echo "(none)"
    echo "--- display-subsystem device ---"
    if [ -e /sys/bus/platform/devices/display-subsystem ]; then
        echo "device exists"
        echo "driver: $(readlink -f /sys/bus/platform/devices/display-subsystem/driver 2>/dev/null || echo NONE)"
    else
        echo "NO display-subsystem device node!"
    fi
    echo "--- explicit bind attempt ---"
    if [ -e /sys/bus/platform/drivers/rockchip-drm/bind ]; then
        echo display-subsystem > /sys/bus/platform/drivers/rockchip-drm/bind 2>&1 \
            && echo "bind OK" || echo "bind failed rc=$?"
        sleep 1
        echo "driver now: $(readlink -f /sys/bus/platform/devices/display-subsystem/driver 2>/dev/null || echo NONE)"
        ls -l /dev/dri 2>&1 || true
    else
        echo "no rockchip-drm driver dir"
    fi
    echo "--- devices_deferred ---"
    cat /sys/kernel/debug/devices_deferred 2>&1 || true
    echo "--- dmesg (last 60 drm-ish) ---"
    dmesg | grep -iE "rockchip|drm|vop|edp|hdptx|panel|component|deferred" | tail -60
    echo "============= ZT1GFX end ============="
}
run > "$OUT" 2>&1
cat "$OUT" > /dev/console 2>&1
SCRIPT
chmod +x "$ROOTFS/usr/local/sbin/zerot1-gfx.sh"

cat > "$ROOTFS/etc/systemd/system/zerot1-gfx.service" <<'UNIT'
[Unit]
Description=zeroT1 display bring-up (temporary diagnostics)
After=local-fs.target systemd-modules-load.service
Before=display-manager.service
ConditionPathExists=/etc/zerot1-diag.enable

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/zerot1-gfx.sh
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

mkdir -p "$ROOTFS/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/zerot1-gfx.service \
    "$ROOTFS/etc/systemd/system/multi-user.target.wants/zerot1-gfx.service"

echo "  已更新 zerot1-gfx.service（写 /root/zt1-gfx.txt + 显式 bind 尝试）"
