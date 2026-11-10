#!/usr/bin/env bash
# prepare-boot.sh —— 组装 FNOS_BOOT 目录（fnOS 官方内核的 boot 分区内容）
#
# 输入（全部可下载/复用，不入库）：
#   fnOS 官方内核包  6.18.18-rockchip.tar.gz（ophub/fnnas release `kernel_fnnas`）
#                    内含 boot/dtb/modules/header 四个子包；本脚本只用 boot 子包。
#   assets/modules/6.18.18-trim/analogix_dp.ko  我们自编译的 eDP 驱动
#   assets/modules/6.18.18-trim/tcpm.ko         我们打了 defer 修复的 Type-C tcpm
#
# 输出（$FNOS_BOOT，供 scripts/pack-image.sh 直接拷进 boot 分区）：
#   Image       <- vmlinuz-6.18.18-trim（fnOS 官方内核，带 trimafs/zfs/rk_vcodec）
#   uInitrd     <- 官方 uInitrd，但把里面的 analogix_dp.ko / tcpm.ko 换成我们改过的版本
#                  （eDP 与 Type-C 角色切换都在启动早期由 initramfs 里的模块驱动，
#                   只改 rootfs 不生效；tcpm 旧版还会吞掉 -EPROBE_DEFER 导致角色切换随机失效）
#   config / System.map  <- 留档，便于排查
#
# 用法：
#   sudo ./scripts/prepare-boot.sh
#   KERNEL_PKG=/path/6.18.18-rockchip.tar.gz FNOS_BOOT=/path/boot sudo ./scripts/prepare-boot.sh
#
# 环境变量：
#   KERNEL_PKG        已下载的内核包（.tar.gz）或已解包目录；默认 $WORK_DIR/kernel-fnos/6.18.18-rockchip.tar.gz
#   KERNEL_PKG_URL    内核包下载地址（默认 ophub kernel_fnnas release）
#   FNOS_BOOT         输出目录，默认 $WORK_DIR/boot-fnos
#   SKIP_UINITRD_PATCH=1  不替换 uInitrd 里的 analogix_dp.ko（排障用）
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib-common.sh"

KVER="${KVER:-6.18.18-trim}"
KPKG_URL="${KERNEL_PKG_URL:-https://github.com/ophub/fnnas/releases/download/kernel_fnnas/6.18.18-rockchip.tar.gz}"
KPKG="${KERNEL_PKG:-$WORK_DIR/kernel-fnos/6.18.18-rockchip.tar.gz}"
FNOS_BOOT="${FNOS_BOOT:-$WORK_DIR/boot-fnos}"
ANALOGIX_KO="$ASSETS_DIR/modules/$KVER/analogix_dp.ko"
TCPM_KO="$ASSETS_DIR/modules/$KVER/tcpm.ko"

# ---- 1. 取得内核包 ----
if [ -d "$KPKG" ]; then
    PKG_DIR="$KPKG"
elif [ -f "$KPKG" ]; then
    PKG_DIR="$(mktemp -d "$WORK_DIR/kernel-fnos.XXXXXX")"
    log "解包内核包 $(basename "$KPKG")"
    tar -xzf "$KPKG" -C "$PKG_DIR"
else
    mkdir -p "$(dirname "$KPKG")"
    log "下载 fnOS 官方内核包: $KPKG_URL"
    curl -fL --retry 3 --retry-delay 2 -o "$KPKG.part" "$KPKG_URL"
    mv "$KPKG.part" "$KPKG"
    PKG_DIR="$(mktemp -d "$WORK_DIR/kernel-fnos.XXXXXX")"
    tar -xzf "$KPKG" -C "$PKG_DIR"
fi

# 内核包解包后是一个 6.18.18-rockchip/ 目录，里面有 4 个子 tar.gz + sha256sums
BOOT_TGZ="$(find "$PKG_DIR" -name 'boot-rockchip-*.tar.gz' | head -1)"
[ -n "$BOOT_TGZ" ] || die "内核包里找不到 boot-rockchip-*.tar.gz（$PKG_DIR）"
if [ -f "$(dirname "$BOOT_TGZ")/sha256sums" ]; then
    ( cd "$(dirname "$BOOT_TGZ")" && sha256sum -c --ignore-missing sha256sums >/dev/null 2>&1 ) || \
        warn "内核包 sha256sums 校验未通过（继续，但请检查下载完整性）"
fi

# ---- 2. 解出 boot 文件 ----
log "解出 boot 文件 -> $FNOS_BOOT"
rm -rf "$FNOS_BOOT"
mkdir -p "$FNOS_BOOT"
tar -xzf "$BOOT_TGZ" -C "$FNOS_BOOT"

cp -f "$FNOS_BOOT/vmlinuz-$KVER" "$FNOS_BOOT/Image"
cp -f "$FNOS_BOOT/config-$KVER" "$FNOS_BOOT/config"
cp -f "$FNOS_BOOT/System.map-$KVER" "$FNOS_BOOT/System.map"

# ---- 3. 替换 uInitrd 里的 analogix_dp.ko ----
SRC_UINITRD="$FNOS_BOOT/uInitrd-$KVER"
[ -f "$SRC_UINITRD" ] || die "内核包里缺少 uInitrd-$KVER"

if [ "${SKIP_UINITRD_PATCH:-0}" = "1" ]; then
    log "SKIP_UINITRD_PATCH=1：直接使用官方 uInitrd"
    cp -f "$SRC_UINITRD" "$FNOS_BOOT/uInitrd"
else
    [ -f "$ANALOGIX_KO" ] || die "缺少 $ANALOGIX_KO（先构建或从 assets 恢复）"
    [ -f "$TCPM_KO" ] || die "缺少 $TCPM_KO（tcpm defer 修复模块，先构建或从 assets 恢复）"
    log "替换 uInitrd 内的 analogix_dp.ko（md5 $(md5sum "$ANALOGIX_KO" | cut -d' ' -f1)）"
    log "替换 uInitrd 内的 tcpm.ko（md5 $(md5sum "$TCPM_KO" | cut -d' ' -f1)）"
    need_root   # initramfs 含设备节点，解包需要 root
    python3 "$HERE/uinitrd-tool.py" repack "$SRC_UINITRD" "$FNOS_BOOT/uInitrd" \
        --replace "usr/lib/modules/$KVER/kernel/drivers/gpu/drm/bridge/analogix/analogix_dp.ko=$ANALOGIX_KO" \
        --replace "usr/lib/modules/$KVER/kernel/drivers/usb/typec/tcpm/tcpm.ko=$TCPM_KO"
fi

# 官方内核包里的这些命名带版本号，boot 分区里不需要（u-boot 按固定名加载）
rm -f "$FNOS_BOOT"/vmlinuz-* "$FNOS_BOOT"/initrd.img-* "$FNOS_BOOT"/uInitrd-* \
      "$FNOS_BOOT"/config-* "$FNOS_BOOT"/System.map-*

# ---- 4. 记录来源，便于镜像内追溯 ----
cat > "$FNOS_BOOT/BUILD-INFO.txt" <<EOF
fnOS 官方内核 boot 内容（由 scripts/prepare-boot.sh 生成）
kernel version : $KVER
kernel package : $KPKG_URL
Image md5      : $(md5sum "$FNOS_BOOT/Image" | cut -d' ' -f1)
uInitrd md5    : $(md5sum "$FNOS_BOOT/uInitrd" | cut -d' ' -f1)
analogix_dp.ko : $(md5sum "$ANALOGIX_KO" 2>/dev/null | cut -d' ' -f1 || echo 'n/a (官方)')
built at       : $(date -Is)
EOF

log "FNOS_BOOT 就绪: $FNOS_BOOT"
ls -lh "$FNOS_BOOT" | head -10
