#!/usr/bin/env bash
# patch-rootfs.sh —— 对 rootfs 目录按顺序执行补丁脚本
#
# 每个补丁是一个独立 shell 脚本（patches/rootfs/NN-*.sh），只做一件事：
#   10-fstab.sh          改写 /etc/fstab（对齐本项目分区布局）
#   15-network.sh        NetworkManager / 主机名默认值
#   20-firmware.sh       WiFi/BT/regulatory 固件
#   22-watchdog-module.sh 板载 MCU 看门狗 ko
#   25-audio.sh          ES8388 codec 用户态配置
#   26-audio-mclk.sh     GRF I2S0 MCLK to_io 门控（无声根因，服务固化）
#   27-vendor-modules.sh 自编译 analogix_dp / brcmfmac 模块
#   28-graphics-modules.sh 显示/音频/网卡模块开机加载
#   30-adb.sh            chroot 安装 adb 客户端 + adbd
#   32-serial-autologin.sh 调试串口自动登录
#   40-xfce.sh           chroot 安装 XFCE + lightdm（不预置普通用户）
#   41-wizard-firstboot.sh 恢复出厂未初始化态，保证 Web 向导可注册管理员
#   42-logclean.sh       日志刷屏治理（journald 限容/mask nut/libupnp13/eventlogger 延迟/enable ssh）
#   45-desktop-apps.sh   桌面快捷方式
#   50-watchdog.sh       systemd RuntimeWatchdogSec + watchdog 工具
#   60-desktop-apps.sh   nm-applet / blueman / chromium / alsa-utils + autostart
#   70-audio-state.sh    ES8388 喇叭功放使能（spk switch）
#   80-docker-fix.sh     docker.service ExecStop bug + 国内镜像源
#   90-rootfs-resize.sh  fnnas.conf 首次启动扩到 16GiB
#   95/96-diag/gfx       临时开机诊断（串口输出/强制拉起显示）
#
# 用法:
#   ./scripts/patch-rootfs.sh <rootfs-dir>                 # 全部按序执行
#   ./scripts/patch-rootfs.sh <rootfs-dir> --only 70,80     # 只跑指定编号
#   ./scripts/patch-rootfs.sh <rootfs-dir> --list           # 列出可执行补丁
set -euo pipefail

ROOTFS="${1:?usage: $0 <rootfs-dir> [--only NN,NN] [--list]}"
shift || true

MODE="all"
ONLY=""
if [ "${1:-}" = "--list" ]; then
    MODE="list"
elif [ "${1:-}" = "--only" ]; then
    MODE="only"
    ONLY="${2:?--only 需要编号，例如 70,80}"
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
PATCH_DIR="$HERE/../patches/rootfs"

[ -d "$PATCH_DIR" ] || { echo "[patch-rootfs] ERROR: $PATCH_DIR 不存在" >&2; exit 1; }

shopt -s nullglob
scripts=("$PATCH_DIR"/*.sh)
shopt -u nullglob

if [ "${#scripts[@]}" -eq 0 ]; then
    echo "[patch-rootfs] $PATCH_DIR 下没有 .sh 补丁"
    exit 0
fi

if [ "$MODE" = "list" ]; then
    for s in "${scripts[@]}"; do
        base="$(basename "$s")"
        desc="$(sed -n '2s/^# *//p' "$s")"
        printf '  %-24s %s\n' "$base" "$desc"
    done
    exit 0
fi

[ -d "$ROOTFS" ] || { echo "[patch-rootfs] ERROR: rootfs 目录不存在: $ROOTFS" >&2; exit 1; }

echo "[patch-rootfs] rootfs: $ROOTFS"
for s in "${scripts[@]}"; do
    base="$(basename "$s")"
    num="${base%%-*}"
    if [ "$MODE" = "only" ]; then
        case ",$ONLY," in
            *",$num,"*) ;;
            *) continue ;;
        esac
    fi
    echo "[patch-rootfs] ===== $base ====="
    bash "$s" "$ROOTFS"
done

echo "[patch-rootfs] 全部完成"
