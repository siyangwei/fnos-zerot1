#!/usr/bin/env bash
# =============================================================================
# fnOS (fnNAS) 镜像构建脚本  —— 板级移植：Shimeta AIOT-3588A (RK3588)
#
# 原理（与 zhangyada/fnos-elf3588 相同路线）：
#   1) 下载 ophub/fnnas 的官方预编译镜像（rk3588 通用内核 + Debian rootfs）
#   2) 下载与镜像内核版本严格一致的 mainline 内核源码，编译本板 DTS -> DTB
#   3) 把 DTB 放入 boot 分区，并把 armbianEnv.txt 的 fdtfile 指向它
#   4) 重新压缩成可 dd 写的 .img.gz
#
# 为什么不能用 NanoPC-T6 的现成 DTB：
#   本板显示是 eDP（hdptxphy0 + VP1）、HDMI 走 HDMI1（hdptxphy1 + VP0）、
#   HDMI0 与 eDP 共用 PHY 不能同时开；音频 codec 是 ES8388；NPU 电源在 i2c1；
#   还有 5V 外设电源 GPIO3_D5 必须常开。详见 dts/rk3588-aiot3588a.dts 头注释。
#
# 用法：
#   sudo ./build-image.sh                 # 完整构建
#   sudo BOARD_NAME=aiot3588a ./build-image.sh
#   SKIP_DOWNLOAD=1 sudo ./build-image.sh # 复用 work/ 下已有镜像与源码
# =============================================================================
set -euo pipefail

# ---------- 可覆盖配置 ----------
BOARD_NAME="${BOARD_NAME:-aiot3588a}"        # dtb 名字：rk3588-<BOARD_NAME>.dtb
BASE_BOARD="${BASE_BOARD:-nanopc-t6}"        # ophub 底稿机型（同 SoC/同 PMIC）
KERNEL_VER="${KERNEL_VER:-6.18.18}"          # ★ 必须与底稿镜像内核版本一致
BASE_DATE="${BASE_DATE:-2026.09.23}"         # ophub release 内镜像日期
FNOS_RELEASE_TAG="${FNOS_RELEASE_TAG:-fnnas_rockchip_1253}"
BASE_IMAGE="fnnas_rockchip_${BASE_BOARD}_k${KERNEL_VER}_${BASE_DATE}.img.gz"
BASE_URL="https://github.com/ophub/fnnas/releases/download/${FNOS_RELEASE_TAG}/${BASE_IMAGE}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${ROOT_DIR}/work"
OUT="${ROOT_DIR}/output"
DTS_DIR="${ROOT_DIR}/dts"
mkdir -p "$WORK" "$OUT"

log()  { echo -e "\033[1;32m[fnos]\033[0m $*"; }
warn() { echo -e "\033[1;33m[fnos]\033[0m $*"; }
die()  { echo -e "\033[1;31m[fnos]\033[0m $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "需要 root（losetup/mount），请用 sudo 运行"
command -v curl >/dev/null || die "缺少 curl"
command -v make >/dev/null || die "缺少 make"
command -v dtc  >/dev/null || warn "缺少 dtc（内核自带的 scripts/dtc 会用，通常没事）"

# ---------- 1. 底稿镜像 ----------
IMG="${WORK}/${BASE_IMAGE%.gz}"
# 下载（跳过已有 .img.gz；SKIP_DOWNLOAD=1 时完全跳过下载）
if [ "${SKIP_DOWNLOAD:-0}" != "1" ] && [ ! -f "${WORK}/${BASE_IMAGE}" ]; then
	log "下载底稿镜像: ${BASE_IMAGE}"
	curl -L --fail --retry 3 -o "${WORK}/${BASE_IMAGE}" "$BASE_URL" \
		|| die "下载失败，检查 FNOS_RELEASE_TAG / BASE_DATE / 网络"
fi
# 解压（只要 .img 不存在就解压，无论是否 SKIP_DOWNLOAD）
if [ ! -f "$IMG" ]; then
	[ -f "${WORK}/${BASE_IMAGE}" ] || die "缺少 ${BASE_IMAGE}（首次构建请勿设 SKIP_DOWNLOAD=1）"
	log "解压底稿镜像（约 1.7GB）"
	gunzip -c "${WORK}/${BASE_IMAGE}" > "$IMG"
fi
[ -f "$IMG" ] || die "找不到底稿镜像 $IMG"

# ---------- 2. 编译本板 DTB ----------
KSRC="${WORK}/linux-${KERNEL_VER}"
KVER_MAJOR="${KERNEL_VER%%.*}"
if [ ! -d "$KSRC" ]; then
	log "下载 Linux ${KERNEL_VER} 源码（cdn.kernel.org）"
	if [ ! -f "${WORK}/linux-${KERNEL_VER}.tar.xz" ]; then
		curl -L --fail --retry 3 -o "${WORK}/linux-${KERNEL_VER}.tar.xz" \
			"https://cdn.kernel.org/pub/linux/kernel/v${KVER_MAJOR}.x/linux-${KERNEL_VER}.tar.xz" \
			|| die "内核源码下载失败"
	fi
	tar -xJf "${WORK}/linux-${KERNEL_VER}.tar.xz" -C "$WORK"
fi
[ -d "$KSRC" ] || die "找不到内核源码目录 $KSRC"

log "放入板级 DTS: rk3588-${BOARD_NAME}.dts"
cp "${DTS_DIR}/rk3588-${BOARD_NAME}.dts" "${KSRC}/arch/arm64/boot/dts/rockchip/"

MK="${KSRC}/arch/arm64/boot/dts/rockchip/Makefile"
if ! grep -q "rk3588-${BOARD_NAME}.dtb" "$MK"; then
	log "在 dtb-y 中注册 rk3588-${BOARD_NAME}.dtb"
	# 放在 nanopc-t6 下一行，保持同类板相邻
	sed -i "/rk3588-nanopc-t6.dtb/a dtb-\$(CONFIG_ARCH_ROCKCHIP) += rk3588-${BOARD_NAME}.dtb" "$MK" 2>/dev/null \
		|| echo "dtb-\$(CONFIG_ARCH_ROCKCHIP) += rk3588-${BOARD_NAME}.dtb" >> "$MK"
fi

log "编译 dtb（只需要 host 工具链 + dtc，不需要交叉编译器）"
# 内核 Makefile 要求存在 .config 才能构建任何目标；defconfig 只用到宿主工具
if [ ! -f "${KSRC}/.config" ]; then
	log "生成 .config（ARCH=arm64 defconfig，仅用于 dtb 编译）"
	make -C "$KSRC" ARCH=arm64 defconfig >/dev/null 2>&1 \
		|| die "defconfig 失败（缺少 host 编译工具？）"
fi
make -C "$KSRC" ARCH=arm64 "rockchip/rk3588-${BOARD_NAME}.dtb" -j"$(nproc)" \
	|| die "dtb 编译失败（看上面的 dtc 报错）"
DTB="${KSRC}/arch/arm64/boot/dts/rockchip/rk3588-${BOARD_NAME}.dtb"
[ -f "$DTB" ] || die "dtb 未生成"
log "dtb 大小: $(stat -c %s "$DTB") 字节"

# ---------- 3. 挂载 boot 分区并替换 ----------
# ophub 镜像 GPT 布局：p1 = boot（起始 LBA 32768）
BOOT_OFFSET=$((32768 * 512))
MNT="${WORK}/boot-mnt"
mkdir -p "$MNT"
LOOP=""
cleanup() {
	if mountpoint -q "$MNT" 2>/dev/null; then umount "$MNT" || true; fi
	[ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null || true
}
trap cleanup EXIT

LOOP=$(losetup --find --show --offset "$BOOT_OFFSET" "$IMG")
log "boot 分区 loop: $LOOP (offset=$BOOT_OFFSET)"

mounted=0
for fstype in "" ext4 vfat; do
	if [ -z "$fstype" ]; then
		mount "$LOOP" "$MNT" 2>/dev/null && { mounted=1; break; }
	else
		mount -t "$fstype" "$LOOP" "$MNT" 2>/dev/null && { mounted=1; break; }
	fi
done
[ "$mounted" = "1" ] || die "无法挂载 boot 分区；请确认镜像版本/偏移没有变化（可用 fdisk -l 检查）"

log "boot 分区内容:"; ls "$MNT" | head -20

# 目标 dtb 目录（Armbian 风格 /boot/dtb/rockchip/）
DTB_DIR="${MNT}/dtb/rockchip"
[ -d "$DTB_DIR" ] || die "boot 分区里没有 dtb/rockchip 目录，镜像布局可能变了"
cp "$DTB" "${DTB_DIR}/rk3588-${BOARD_NAME}.dtb"
log "已放入 ${DTB_DIR}/rk3588-${BOARD_NAME}.dtb"

# 修改 armbianEnv.txt 的 fdtfile
ENVF="${MNT}/armbianEnv.txt"
if [ -f "$ENVF" ]; then
	if grep -q '^fdtfile=' "$ENVF"; then
		sed -i "s|^fdtfile=.*|fdtfile=rockchip/rk3588-${BOARD_NAME}.dtb|" "$ENVF"
	else
		echo "fdtfile=rockchip/rk3588-${BOARD_NAME}.dtb" >> "$ENVF"
	fi
	log "armbianEnv.txt fdtfile -> rockchip/rk3588-${BOARD_NAME}.dtb"
	grep -E '^(fdtfile|verbosity)=' "$ENVF" || true
else
	die "找不到 armbianEnv.txt；镜像可能不是 ophub/Armbian 布局"
fi

# 顺手把本板 dtb 也丢一份到 /boot/ 根（部分 u-boot 版本直接找 /boot/rk3588-xxx.dtb）
cp "$DTB" "${MNT}/rk3588-${BOARD_NAME}.dtb" 2>/dev/null || true

sync
umount "$MNT"
losetup -d "$LOOP"; LOOP=""

# ---------- 4. 打包 ----------
STAMP=$(date +%Y%m%d)
OUTNAME="fnos-fnnas-${BOARD_NAME}-k${KERNEL_VER}-${STAMP}.img.gz"
log "重新压缩 -> ${OUT}/${OUTNAME}"
gzip -c "$IMG" > "${OUT}/${OUTNAME}"

log "完成："
ls -lh "${OUT}/${OUTNAME}"
echo
echo "烧录（Linux）:  sudo dd if=${OUT}/${OUTNAME} of=/dev/sdX bs=4M status=progress conv=fsync"
echo "烧录（Windows）: 用 balenaEtcher 直接写 .img.gz"
