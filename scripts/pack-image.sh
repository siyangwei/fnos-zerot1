#!/usr/bin/env bash
# pack-image.sh —— 组装各分区镜像 + 用 Rockchip 工具打包出 update.img
#
# 分区布局（与 parameter.txt 一致，单位=512B 扇区）：
#   uboot    0x004000 .. +0x2000   (4MB)
#   misc     0x006000 .. +0x2000   (4MB)
#   resource 0x008000 .. +0x8000   (16MB)  -- 放 rk-kernel.dtb 给 u-boot 用
#   boot     0x010000 .. +0x20000  (64MB, FAT32) -- Image + dtb + extlinux.conf
#   rootfs   0x030000 .. +<按rootfs大小> (btrfs)
#   userdata 紧接 rootfs 之后，grow 到盘尾
#
# 用法：sudo ./scripts/pack-image.sh
# 产物：output/fnos-aiot3588a-update-<日期>.img（RKFW 格式，upgrade_tool uf 烧录）
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib-common.sh"

need_root
: "${ROOTFS:?}"
[ -f "$IMAGE_DIR/Image" ] || die "缺少 $IMAGE_DIR/Image（先跑 build-kernel.sh）"
[ -f "$IMAGE_DIR/dtb/rockchip/rk3588-aiot3588a.dtb" ] || die "缺少 dtb"

UBOOT_START=0x4000;  UBOOT_SIZE=0x2000
MISC_START=0x6000;   MISC_SIZE=0x2000
RES_START=0x8000;    RES_SIZE=0x8000
BOOT_START=0x10000;  BOOT_SIZE=0x20000
ROOTFS_START=0x30000

# rootfs 大小：按 64MB 对齐（+3 块冗余，跟 sd-fuse 的 build-rootfs-img.sh 一致）
ROOTFS_USED_MB=$(( $(du -sm "$ROOTFS" | cut -f1) + 3 ))
ROOTFS_MB=$(( (ROOTFS_USED_MB + 63) / 64 * 64 ))
ROOTFS_SIZE=$(( ROOTFS_MB * 1024 * 1024 / 512 ))
USERDATA_START=$(( ROOTFS_START + ROOTFS_SIZE ))

log "rootfs 计算：${ROOTFS_USED_MB}MB used → 分区 ${ROOTFS_MB}MB (${ROOTFS_SIZE} 扇区)"
log "userdata 起点：0x$(printf '%08x' $USERDATA_START)"

UPDATE_DIR="$WORK_DIR/fnos-update"
rm -rf "$UPDATE_DIR"
mkdir -p "$UPDATE_DIR/images"

# ---- 1. loader / u-boot（预编译复用 assets/）----
cp -f "$ASSETS_DIR/MiniLoaderAll.bin" "$UPDATE_DIR/MiniLoaderAll.bin"
cp -f "$ASSETS_DIR/uboot.img" "$UPDATE_DIR/uboot.img"

# ---- 2. misc.img（4MB 全零，清掉 Android 的 recovery 标记）----
log "生成 misc.img (4MB 零)"
dd if=/dev/zero of="$UPDATE_DIR/misc.img" bs=1M count=4 status=none

# ---- 3. resource.img（u-boot 从这里读 rk-kernel.dtb）----
log "生成 resource.img（内含 rk-kernel.dtb）"
mkdir -p "$UPDATE_DIR/res"
cp -f "$IMAGE_DIR/dtb/rockchip/rk3588-aiot3588a.dtb" "$UPDATE_DIR/res/rk-kernel.dtb"
"$ASSETS_DIR/tools/resource_tool" --pack --root="$UPDATE_DIR/res" \
    --image="$UPDATE_DIR/resource.img" "$UPDATE_DIR/res/rk-kernel.dtb" >/dev/null

# ---- 4. boot.img（64MB FAT32：Image + dtb + extlinux.conf）----
log "生成 boot.img (64MB FAT32)"
BOOT_SRC="$UPDATE_DIR/boot"
mkdir -p "$BOOT_SRC/dtb/rockchip" "$BOOT_SRC/extlinux"
cp -f "$IMAGE_DIR/Image" "$BOOT_SRC/Image"
cp -f "$IMAGE_DIR/dtb/rockchip/rk3588-aiot3588a.dtb" "$BOOT_SRC/dtb/rockchip/"
cat > "$BOOT_SRC/extlinux/extlinux.conf" <<'EOF'
label fnos
    kernel /Image
    fdt /dtb/rockchip/rk3588-aiot3588a.dtb
    append root=/dev/mmcblk2p5 rootfstype=btrfs rootwait rw console=ttyS2,1500000n8 console=tty0 net.ifnames=0 max_loop=128 earlycon=uart8250,mmio32,0xfeb50000
EOF
truncate -s $(( BOOT_SIZE * 512 )) "$UPDATE_DIR/boot.img"
mkfs.vfat -F 32 -n BOOT "$UPDATE_DIR/boot.img" >/dev/null
mcopy -s -i "$UPDATE_DIR/boot.img" "$BOOT_SRC/Image" ::/Image
mcopy -s -i "$UPDATE_DIR/boot.img" "$BOOT_SRC/../boot/dtb" ::/ 2>/dev/null || \
    ( mdir -i "$UPDATE_DIR/boot.img" ::/ >/dev/null 2>&1; mcopy -s -i "$UPDATE_DIR/boot.img" "$BOOT_SRC/dtb" ::/dtb )
mcopy -s -i "$UPDATE_DIR/boot.img" "$BOOT_SRC/extlinux" ::/extlinux

# ---- 5. rootfs.img（btrfs，UUID 与 fstab 一致）----
log "生成 rootfs.img (${ROOTFS_MB}MB btrfs)"
ROOTFS_IMG="$UPDATE_DIR/rootfs.img"
truncate -s $(( ROOTFS_SIZE * 512 )) "$ROOTFS_IMG"
mkfs.btrfs -L rootfs -U 357e9eb7-73ea-4367-b981-6296a97687e0 -f "$ROOTFS_IMG" >/dev/null
MNT="$WORK_DIR/mnt-rootfs"
mkdir -p "$MNT"
mount -o loop,compress=zstd:1 "$ROOTFS_IMG" "$MNT"
rsync -aHAX --numeric-ids "$ROOTFS/" "$MNT/"
sync
umount "$MNT"
rmdir "$MNT"

# ---- 6. parameter.txt ----
log "生成 parameter.txt"
cat > "$UPDATE_DIR/parameter.txt" <<EOF
FIRMWARE_VER: 8.1.0
MACHINE_MODEL: RK3588
MACHINE_ID: 007
MANUFACTURER: RK3588
MAGIC: 0x5041524B
ATAG: 0x00200800
MACHINE: 0xffffffff
CHECK_MASK: 0x80
PACKAGE_FILE: parameter.txt
CMDLINE: mtdparts=rk29xxnand:0x00002000@0x00004000(uboot),0x00002000@0x00006000(misc),0x00008000@0x00008000(resource),0x00020000@0x00010000(boot),0x$(printf '%08x' $ROOTFS_SIZE)@0x$(printf '%08x' $ROOTFS_START)(rootfs)
uuid:rootfs=357e9eb7-73ea-4367-b981-6296a97687e0
EOF

# ---- 7. 打包 update.img ----
log "打包 update.img（mkupdate.sh）"
cd "$ASSETS_DIR/tools"
./mkupdate.sh rk3588 "$UPDATE_DIR" emmc > "$WORK_DIR/mkupdate.log" 2>&1 || {
    tail -30 "$WORK_DIR/mkupdate.log" >&2; die "mkupdate 失败"
}

OUT_IMG="$OUTPUT_DIR/fnos-aiot3588a-update-$(date +%Y%m%d).img"
cp -f update.img "$OUT_IMG"
rm -f update.img
cd - >/dev/null

log "产物: $OUT_IMG ($(stat -c %s "$OUT_IMG") B)"
sha256sum "$OUT_IMG"
