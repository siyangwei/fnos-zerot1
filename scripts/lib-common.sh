#!/usr/bin/env bash
# lib-common.sh —— 构建脚本共用变量与函数
#
# 目录约定：
#   PROJECT_DIR/          仓库根
#   PROJECT_DIR/work/     构建缓存的源码（u-boot / kernel / fnos 镜像解包等，已 gitignore）
#   PROJECT_DIR/output/   最终产物（update.img，已 gitignore）
#   PROJECT_DIR/assets/   预编译复用资源（loader / uboot.img / 固件，入库）
#   PROJECT_DIR/dts/      板级设备树
#   PROJECT_DIR/patches/  u-boot / 内核 / rootfs 的补丁
#
# 环境变量（可覆盖）：
#   WORK_DIR       默认 $PROJECT_DIR/work
#   OUTPUT_DIR     默认 $PROJECT_DIR/output
#   IMAGE_DIR      默认 $WORK_DIR/images     （分区镜像目录，供 pack 使用）
#   FNOS_IMG       默认 $WORK_DIR/fnnas_base.img（ophub 底稿镜像，解压后）
#   FNOS_IMG_URL   底稿镜像下载地址
#   SKIP_*         跳过某阶段

set -euo pipefail

_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${PROJECT_DIR:-$(cd "$_HERE/.." && pwd)}"

# ── config.env：仓库根目录的可编辑配置（WiFi / SSH / 构建开关等）──────────
# 外部环境变量优先：命令行或 GitHub Actions 传入的同名变量会覆盖文件里的值。
CONFIG_ENV="${CONFIG_ENV:-$PROJECT_DIR/config.env}"
load_config_env() {
    local f="$1" line k
    local keys=()
    [ -f "$f" ] || return 0
    declare -A _cfg_saved=()
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|\#*) continue ;; esac
        case "$line" in *=*) ;; *) continue ;; esac
        k="${line%%=*}"; k="${k#export }"; k="${k//[[:space:]]/}"
        [[ "$k" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        keys+=("$k")
        [ -n "${!k+x}" ] && _cfg_saved[$k]="${!k}"
    done < "$f"
    set -a
    # shellcheck disable=SC1090
    . "$f"
    set +a
    for k in "${keys[@]}"; do
        [ -n "${_cfg_saved[$k]+x}" ] && printf -v "$k" '%s' "${_cfg_saved[$k]}"
    done
    unset _cfg_saved
}
load_config_env "$CONFIG_ENV"

WORK_DIR="${WORK_DIR:-$PROJECT_DIR/work}"
OUTPUT_DIR="${OUTPUT_DIR:-$PROJECT_DIR/output}"
IMAGE_DIR="${IMAGE_DIR:-$WORK_DIR/images}"

# 板型/硬件版本：AIOT-3588A 官方有 V1.1 / V1.3 两个板型，本仓库只适配 V1.1
BOARD_MODEL="${BOARD_MODEL:-AIOT-3588A}"
BOARD_REV="${BOARD_REV:-V1.1}"
IMG_BASENAME="${IMG_BASENAME:-fnos-aiot3588a-$(echo "$BOARD_REV" | tr "A-Z" "a-z")-update}"
# 引导链：upstream=上游 U-Boot v2026.10（默认）；vendor=厂商 2017.09
UBOOT_MODE="${UBOOT_MODE:-upstream}"
export UBOOT_MODE
ROOTFS="${ROOTFS:-$PROJECT_DIR/work/rootfs}"

ASSETS_DIR="$PROJECT_DIR/assets"
DTS_DIR="$PROJECT_DIR/dts"
PATCHES_DIR="$PROJECT_DIR/patches"

# fnOS 底稿镜像（ophub nanopc-t6, k6.18.18）—— 只用来提取 rootfs（Debian 12 + fnOS 服务）
FNOS_IMG_URL="${FNOS_IMG_URL:-https://github.com/ophub/fnnas/releases/download/fnnas_rockchip_1253/fnnas_rockchip_nanopc-t6_k6.18.18_2026.09.23.img.gz}"
FNOS_IMG_GZ="${FNOS_IMG_GZ:-$WORK_DIR/fnnas_base.img.gz}"
FNOS_IMG="${FNOS_IMG:-$WORK_DIR/fnnas_base.img}"

log()  { printf '\033[1;36m[build]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[build]\033[0m WARN: %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[build]\033[0m ERROR: %s\n' "$*" >&2; exit 1; }

need_root() {
    [ "$(id -u)" -eq 0 ] || die "此步骤需要 root（chroot/mount/losetup），请用 sudo 运行"
}

mkdir -p "$WORK_DIR" "$OUTPUT_DIR" "$IMAGE_DIR"
