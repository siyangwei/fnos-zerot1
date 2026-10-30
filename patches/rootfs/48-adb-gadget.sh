#!/usr/bin/env bash
# 48-adb-gadget.sh —— 打开 USB adb 调试（把板子的 USB-C 口做成 adb gadget）
#
# 背景（2026-10-30 从视美泰官方 Ubuntu22 镜像取证）：
#   官方镜像 adb 可用的三件套 =
#     /usr/bin/adbd            （厂商自编译 ARM64 版的 adbd，只依赖 libc/libpthread/libz/libdl）
#     /usr/bin/usbdevice       （configfs 脚本：建 gadget + ffs.adb 功能 + 启动 adbd + 绑 UDC）
#     /etc/init.d/.usb_config  （内容一行 `usb_adb_en`）
#     /lib/systemd/system/adbd.service（Type=forking，ExecStart=/usr/bin/usbdevice start）
#   它绑定的 UDC 是 fc000000.usb（RK3588 USB3_OTG0），dts 里 `dr_mode="otg"`。
#
# 我们这张板的 dts（dts/mainline-6.18/rk3588-aiot3588a.dts）已经有
#   usbc0 = fcs,fusb302（Type-C），usb-role-switch 指向 usb_host0_xhci，
# 插到 PC 上角色会切成 device —— 只要有 adbd + gadget 就能像官方固件一样 adb。
#
# 本补丁做的事：
#   1) 装 adbd（用 assets/vendor-ubuntu-adb/adbd，厂商编译版，Debian 12 的 glibc 2.36 可跑）
#   2) 装我们自己的最小 gadget 脚本 /usr/local/sbin/zt1-adbd-gadget.sh
#      （只建 ffs.adb 一个功能，不碰 UMS/MTP/RNDIS，避免依赖一堆 function 模块）
#   3) adbd.service（Type=oneshot + RemainAfterExit）开机拉起
#   4) modules-load.d 加 libcomposite / usb_f_fs
#
# 用法: 48-adb-gadget.sh <rootfs-dir>
set -euo pipefail

ROOTFS="${1:?usage: $0 <rootfs-dir>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../scripts/lib-common.sh"

ASSETS="$PROJECT_DIR/assets/vendor-ubuntu-adb"
ADBD="$ASSETS/adbd"
if [ ! -f "$ADBD" ]; then die "缺少 $ADBD（应来自厂商 Ubuntu 镜像 /usr/bin/adbd）"; fi

# ---------- 1) adbd 二进制 ----------
install -m 0755 "$ADBD" "$ROOTFS/usr/bin/adbd"
log "[48-adb] /usr/bin/adbd 已安装"

# ---------- 2) gadget 脚本 ----------
mkdir -p "$ROOTFS/usr/local/sbin"
cat > "$ROOTFS/usr/local/sbin/zt1-adbd-gadget.sh" <<'GADGET'
#!/bin/bash
# zt1-adbd-gadget.sh —— 最小 USB adb gadget（只管 ffs.adb）
# start/stop；幂等；日志 /var/log/zt1-adbd.log
set -u
GADGET_NAME=zt1
CONFIGFS=/sys/kernel/config
G=$CONFIGFS/usb_gadget/$GADGET_NAME
FFS_DIR=/dev/usb-ffs/adb
LOG=/var/log/zt1-adbd.log
mkdir -p "$(dirname "$LOG")"
log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

modprobe libcomposite 2>/dev/null
modprobe usb_f_fs 2>/dev/null

do_start() {
    # 已经绑好 UDC 就直接退出（幂等）
    if [ -n "$(cat "$G/UDC" 2>/dev/null)" ]; then
        log "already bound to $(cat "$G/UDC")"
        return 0
    fi
    # 清掉残留
    do_stop >/dev/null 2>&1

    mountpoint -q $CONFIGFS || mount -t configfs none $CONFIGFS
    mkdir -p "$G"
    echo 0x2207 > "$G/idVendor"      # Rockchip
    echo 0x0006 > "$G/idProduct"     # 0x0006 = adb 常用 product id
    echo 0x0200 > "$G/bcdUSB"
    echo 0x0100 > "$G/bcdDevice"
    mkdir -p "$G/strings/0x409"
    # 序列号：优先 SoC eFuse（device-tree serial-number，本板 = 8e7aa4e0e4859430，与 Android 侧 adb 一致），
    # 其次 /proc/cpuinfo 的 Serial（注意很多 RK3588 板这里是 0000000000000000），最后厂商默认值。
    SERIAL="$(cat /proc/device-tree/serial-number 2>/dev/null | tr -d '\000\n')"
    SERIAL="$(printf '%s' "$SERIAL" | tr -d '\r\n')"
    if [ -z "$SERIAL" ] || [ "$SERIAL" = "0000000000000000" ]; then
        SERIAL="$(awk -F': ' '/^Serial/{print $2; exit}' /proc/cpuinfo 2>/dev/null)"
    fi
    if [ -z "$SERIAL" ] || [ "$SERIAL" = "0000000000000000" ]; then
        SERIAL="${ZT1_ADB_SERIAL:-0123456789ABCDEF}"
    fi
    echo "$SERIAL"        > "$G/strings/0x409/serialnumber"
    echo "shimeta"        > "$G/strings/0x409/manufacturer"
    echo "zeroT1 fnOS"    > "$G/strings/0x409/product"
    mkdir -p "$G/configs/c.1/strings/0x409"
    echo "adb"            > "$G/configs/c.1/strings/0x409/configuration"
    echo 500              > "$G/configs/c.1/MaxPower"

    mkdir -p "$G/functions/ffs.adb"
    ln -sfn "$G/functions/ffs.adb" "$G/configs/c.1/ffs.adb" 2>/dev/null
    mkdir -p "$FFS_DIR"
    mountpoint -q "$FFS_DIR" || mount -t functionfs adb "$FFS_DIR"

    # adbd 先起来并等它把 functionfs 的端点/描述符准备好（ready=1），再绑 UDC；
    # 否则 host 拿到的是一个没有 configuration 的坏设备（no configurations, error -22）
    start-stop-daemon --stop --quiet --exec /usr/bin/adbd 2>/dev/null
    start-stop-daemon --start --quiet --background --exec /usr/bin/adbd
    for i in $(seq 1 100); do
        [ "$(cat "$G/functions/ffs.adb/ready" 2>/dev/null)" = "1" ] && break
        sleep 0.1
    done

    # fnOS 内核 composite 在 SuperSpeed 下只统计 c->superspeed（ffs.adb 无 SS 描述符 ⇒ 计数 0 ⇒
    # host 报 "no configurations, error -22"），因此把 gadget 限制在 HighSpeed 才能枚举
    if [ -w "$G/max_speed" ]; then echo high-speed > "$G/max_speed" 2>/dev/null || true; fi

    UDC="$(ls /sys/class/udc 2>/dev/null | head -1)"
    if [ -z "${UDC:-}" ]; then log "ERROR: 没有 UDC（检查 Type-C 是否插到主机）"; return 1; fi
    for i in $(seq 1 60); do
        if echo "$UDC" > "$G/UDC" 2>/dev/null; then
            log "adbd gadget started on $UDC (ready=$(cat "$G/functions/ffs.adb/ready" 2>/dev/null))"
            return 0
        fi
        sleep 1
    done
    log "ERROR: 绑定 UDC $UDC 失败（dwc3 可能还在 host 模式，等 adb-watch 重试）"
    return 1
}

do_stop() {
    [ -d "$G" ] || return 0
    echo "" > "$G/UDC" 2>/dev/null
    start-stop-daemon --stop --quiet --exec /usr/bin/adbd 2>/dev/null
    rm -f "$G/configs/c.1/ffs.adb"
    rmdir "$G/functions/ffs.adb" 2>/dev/null
    rmdir "$G/configs/c.1/strings/0x409" 2>/dev/null
    rmdir "$G/configs/c.1" 2>/dev/null
    rmdir "$G/strings/0x409" 2>/dev/null
    rmdir "$G" 2>/dev/null
    mountpoint -q "$FFS_DIR" && umount "$FFS_DIR" 2>/dev/null
    log "adbd gadget stopped"
}

case "${1:-start}" in
    start) do_start ;;
    stop)  do_stop ;;
    restart) do_stop; do_start ;;
    *) echo "usage: $0 {start|stop|restart}" >&2; exit 1 ;;
esac
GADGET
chmod 0755 "$ROOTFS/usr/local/sbin/zt1-adbd-gadget.sh"
log "[48-adb] /usr/local/sbin/zt1-adbd-gadget.sh 已安装"

# ---------- 3) systemd 单元 ----------
cat > "$ROOTFS/etc/systemd/system/adbd.service" <<'UNIT'
[Unit]
Description=zeroT1 USB adb gadget (adbd over functionfs)
Documentation=https://github.com/siyangwei/fnos-zerot1
# Type-C 角色切换/UDC 注册完成后再起
After=sys-kernel-config.mount systemd-modules-load.service
Wants=systemd-modules-load.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/zt1-adbd-gadget.sh start
ExecStop=/usr/local/sbin/zt1-adbd-gadget.sh stop
# 插拔 Type-C 时 UDC 会重新注册，失败一次不算致命，让 systemd 5s 后重试
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

mkdir -p "$ROOTFS/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/adbd.service \
    "$ROOTFS/etc/systemd/system/multi-user.target.wants/adbd.service"
log "[48-adb] adbd.service 已设为开机自启"

# ---------- 3.5) adb shell 提示符（厂商 adbd 固定 exec /bin/sh，bash 以 sh 模式读 $ENV） ----------
cat > "$ROOTFS/etc/zt1-adb-env.sh" <<'ENVFILE'
# adb shell 交互式提示符：显示设备名（首启向导完成后 /etc/hostname=设备名，如 zerot1）；
# 出厂未初始化时 hostname=fnnas，这里映射成 zerot1（与「开始使用 fnOS」向导默认设备名一致）
case "$(hostname 2>/dev/null)" in
    ""|localhost|fnnas) _zt1_h=zerot1 ;;
    *)                   _zt1_h=$(hostname) ;;
esac
[ -n "${BASH_VERSION:-}" ] && PS1='${_zt1_h}:\w\$ '
ENVFILE
mkdir -p "$ROOTFS/etc/systemd/system/adbd.service.d"
cat > "$ROOTFS/etc/systemd/system/adbd.service.d/10-adb-shell-env.conf" <<'UNIT'
[Service]
# /bin/sh(=bash) 以 sh 模式启动时也会读 $ENV —— 用它把提示符从 sh-5.2# 改成 zerot1# 
Environment=ENV=/etc/zt1-adb-env.sh
UNIT
log "[48-adb] adb shell 提示符已配置（ENV=/etc/zt1-adb-env.sh）"

# ---------- 4) 模块自动加载 ----------
MLOAD="$ROOTFS/etc/modules-load.d/zerot1-hardware.conf"
mkdir -p "$(dirname "$MLOAD")"
touch "$MLOAD"
for m in libcomposite usb_f_fs; do
    grep -qx "$m" "$MLOAD" 2>/dev/null || echo "$m" >> "$MLOAD"
done
log "[48-adb] modules-load.d 已加 libcomposite/usb_f_fs"

log "[48-adb] 完成：插 USB-C 到 PC 即可 adb shell（board 侧 /var/log/zt1-adbd.log）"
