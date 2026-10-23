#!/usr/bin/env bash
# patch-rootfs.sh —— 对 rootfs 目录按顺序执行补丁脚本
#
# 每个补丁是一个独立 shell 脚本（patches/rootfs/NN-*.sh），只做一件事：
#   10-fstab.sh          改写 /etc/fstab（去掉不存在的 /boot ext4 条目）
#   20-firmware.sh       拷贝 WiFi/BT/regulatory 固件
#   30-adb.sh            chroot 安装 adb 客户端 + adbd
#   40-xfce.sh           chroot 安装 XFCE + lightdm
#   50-watchdog.sh       systemd RuntimeWatchdogSec + watchdog 工具
#   60-desktop-apps.sh   nm-applet / blueman / chromium / alsa-utils + autostart
#   70-audio-state.sh    ES8388 喇叭功放使能（spk switch）
#   80-docker-fix.sh     docker.service ExecStop bug + 国内镜像源
#   90-rootfs-resize.sh  fnnas.conf 首次启动扩到 16GiB
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
