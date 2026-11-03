#!/usr/bin/env bash
# pack-image.sh —— 组装各分区镜像 + 用 Rockchip 工具打包出 update.img
#
# 分区布局（与 parameter.txt 一致，单位=512B 扇区）：
#   uboot    0x004000 .. +0x2000   (4MB,   预编译 assets/uboot.img)
#   misc     0x006000 .. +0x2000   (4MB,   全零，清 Android recovery 标记)
#   resource 0x008000 .. +0x8000   (16MB,  rk-kernel.dtb，u-boot 早期读)
#   boot     0x010000 .. +0x20000  (64MB,  ext4) -- Image + uInitrd + dtb/ + extlinux/
#   rootfs   0x030000 .. +<按 rootfs 大小，64MB 对齐>  (btrfs)
#   userdata 紧接 rootfs 之后，grow 到盘尾
#
# boot 分区与引导链路（重要）：
#   定制的 u-boot（assets/uboot.img）在 board_late_init() 里写死直接引导：
#     load mmc 0:4 ${kernel_addr_r}  /Image
#     load mmc 0:4 ${ramdisk_addr_r} /uInitrd
#     load mmc 0:4 ${fdt_addr_r}     /dtb/rockchip/rk3588-aiot3588a.dtb
#     booti ...
#   因此 boot 分区必须是 ext4（u-boot 里补了 FS_EXT4），且这三个文件名固定。
#   内核 = fnOS 官方 6.18.18-trim（带 trimafs/zfs/rk_vcodec 等私有驱动，
#   主线/友善内核都跑不了 fnOS 管理界面），由 scripts/prepare-boot.sh 准备。
#
# 用法：sudo ./scripts/pack-image.sh
# 产物：output/fnos-aiot3588a-update-<日期>.img（RKFW 格式，upgrade_tool uf 烧录）
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib-common.sh"

need_root
: "${ROOTFS:?}"
FNOS_BOOT="${FNOS_BOOT:-$WORK_DIR/boot-fnos}"
[ -f "$FNOS_BOOT/Image" ]  || die "缺少 $FNOS_BOOT/Image（先跑 scripts/prepare-boot.sh）"
[ -f "$FNOS_BOOT/uInitrd" ] || die "缺少 $FNOS_BOOT/uInitrd（先跑 scripts/prepare-boot.sh）"
[ -f "$IMAGE_DIR/dtb/rockchip/rk3588-aiot3588a.dtb" ] || die "缺少 dtb（先跑 scripts/build-dts.sh）"

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
# 复用现成 rootfs.img 时，先把源文件挪到独立位置（UPDATE_DIR 会被清空重建）
if [ -n "${ROOTFS_IMG_REUSE:-}" ] && [ -f "$ROOTFS_IMG_REUSE" ]; then
    _reuse_src="$(readlink -f "$ROOTFS_IMG_REUSE")"
    case "$_reuse_src" in
        "$UPDATE_DIR"/*) cp -f "$_reuse_src" "$WORK_DIR/rootfs-reuse.img"; ROOTFS_IMG_REUSE="$WORK_DIR/rootfs-reuse.img" ;;
    esac
fi
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

# ---- 4. boot.img（ext4，fnOS 官方内核布局）----
log "生成 boot.img (ext4 ${BOOT_SIZE} 扇区)"
BOOT_SRC="$UPDATE_DIR/boot"
rm -rf "$BOOT_SRC"
mkdir -p "$BOOT_SRC"
cp -a "$FNOS_BOOT/." "$BOOT_SRC/"
# 板级 dtb（含 Type-C device 变体）；u-boot 固定加载 rk3588-aiot3588a.dtb
mkdir -p "$BOOT_SRC/dtb/rockchip"
cp -f "$IMAGE_DIR/dtb/rockchip/rk3588-aiot3588a.dtb" "$BOOT_SRC/dtb/rockchip/"
# Type-C 双 dtb：host 版另存一份 .host 母本，zt1-usb-role 用它回切
cp -f "$BOOT_SRC/dtb/rockchip/rk3588-aiot3588a.dtb" "$BOOT_SRC/dtb/rockchip/rk3588-aiot3588a.dtb.host"
if [ -f "$IMAGE_DIR/dtb/rockchip/rk3588-aiot3588a-usbdev.dtb" ]; then
    cp -f "$IMAGE_DIR/dtb/rockchip/rk3588-aiot3588a-usbdev.dtb" "$BOOT_SRC/dtb/rockchip/"
fi
# extlinux.conf：宿主机手动引导（sysboot）时可用；定制 u-boot 默认走直接引导
mkdir -p "$BOOT_SRC/extlinux"
cat > "$BOOT_SRC/extlinux/extlinux.conf" <<'EOF'
label fnos
    kernel /Image
    fdt /dtb/rockchip/rk3588-aiot3588a.dtb
    initrd /uInitrd
    append root=UUID=357e9eb7-73ea-4367-b981-6296a97687e0 rootwait rw rootfstype=btrfs rootflags=compress=zstd:1 console=ttyS2,1500000n8 console=tty0 quiet loglevel=3 systemd.show_status=0 net.ifnames=0 max_loop=128
EOF
USED_MB=$(( $(du -sm "$BOOT_SRC" | cut -f1) ))
log "boot 分区内容 ${USED_MB}MB / 分区 $(( BOOT_SIZE / 2048 ))MB"
[ "$USED_MB" -lt $(( BOOT_SIZE / 2048 - 6 )) ] || die "boot 分区空间不足（内容 ${USED_MB}MB）"
truncate -s $(( BOOT_SIZE * 512 )) "$UPDATE_DIR/boot.img"
# u-boot 2017.09 的 ext4 驱动不支持 64bit / metadata_csum 特性，必须关掉；
# 64MB 分区要装 32MB Image + 17MB uInitrd，再去掉日志（-O ^has_journal）、
# 预留块（-m 0）和多余 inode 表（-N 1024），否则 cp 到一半 ENOSPC。
mkfs.ext4 -q -F -L BOOT -O ^64bit,^metadata_csum,^has_journal -m 0 -N 1024 -I 256 "$UPDATE_DIR/boot.img"
MNTB="$WORK_DIR/mnt-boot"
mkdir -p "$MNTB"
mount -o loop "$UPDATE_DIR/boot.img" "$MNTB"
trap 'mountpoint -q "$MNTB" && umount "$MNTB" || true' EXIT
df -h "$MNTB" | tail -1
cp -a "$BOOT_SRC/." "$MNTB/"
sync
df -h "$MNTB" | tail -1
umount "$MNTB"
rmdir "$MNTB"
log "boot.img 内容："; ls -lh "$BOOT_SRC" | head -8

# ---- 4.9 属主归一（必须！见 scripts/normalize-ownership.sh 头注释）----
# 历史坑：rootfs 树被污染成 uid 1000 后，postgres 数据目录不可读（web 注册报 4208 数据库读写错误）、
# sshd 因 /etc/ssh/sshd_config 非 root 拥有而拒绝启动。每次打包前强制校正回官方底稿的属主。
bash "$HERE/normalize-ownership.sh" "$ROOTFS"

# ---- 4.95 lightdm 运行时目录属主兜底 ----
# 背景（2026-11-04）：40-xfce.sh 里曾写死 `chown -R 110:110 /var/lib/lightdm`，
# 但 lightdm 的 uid/gid 在不同构建里并不固定（CI 镜像实测 111:122）。一旦目录属主
# 变成别的用户（如 pulse），greeter 就无法写 .Xauthority，报
#   "Failed to open X authority: Permission denied" → lightdm 反复失败 → 桌面起不来。
# 这里在打包前按镜像自己的 /etc/passwd 再兜底一次（属主归一不会碰这个 base 里不存在的路径）。
lm_dir="$ROOTFS/var/lib/lightdm"
if [ -d "$lm_dir" ]; then
    lm_uid="$(awk -F: '$1=="lightdm"{print $3}' "$ROOTFS/etc/passwd" 2>/dev/null || true)"
    lm_gid="$(awk -F: '$1=="lightdm"{print $4}' "$ROOTFS/etc/passwd" 2>/dev/null || true)"
    if [ -n "$lm_uid" ] && [ -n "$lm_gid" ]; then
        chown -R "$lm_uid:$lm_gid" "$lm_dir"
        chmod 755 "$lm_dir"
        log "lightdm 目录属主校正: /var/lib/lightdm → $lm_uid:$lm_gid"
    else
        log "WARN: /etc/passwd 里没有 lightdm 用户，跳过 /var/lib/lightdm 属主校正"
    fi
fi

# ---- 5. rootfs.img（btrfs，UUID 与 fstab 一致）----
# 设 ROOTFS_IMG_REUSE=<现成 rootfs.img> 可跳过 rsync（仅改 boot/uboot 时提速）
ROOTFS_IMG="$UPDATE_DIR/rootfs.img"
if [ -n "${ROOTFS_IMG_REUSE:-}" ] && [ -f "$ROOTFS_IMG_REUSE" ]; then
    log "复用现成 rootfs.img: $ROOTFS_IMG_REUSE"
    cp -f "$ROOTFS_IMG_REUSE" "$ROOTFS_IMG"
else
    log "生成 rootfs.img (${ROOTFS_MB}MB btrfs)"
    truncate -s $(( ROOTFS_SIZE * 512 )) "$ROOTFS_IMG"
    mkfs.btrfs -L rootfs -U 357e9eb7-73ea-4367-b981-6296a97687e0 -f "$ROOTFS_IMG" >/dev/null
    MNT="$WORK_DIR/mnt-rootfs"
    mkdir -p "$MNT"
    mount -o loop,compress=zstd:1 "$ROOTFS_IMG" "$MNT"
    trap 'mountpoint -q "$MNT" && umount "$MNT" || true' EXIT
    rsync -aHAX --numeric-ids "$ROOTFS/" "$MNT/"
    sync
    umount "$MNT"
    rmdir "$MNT"
fi

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
TYPE: GPT
PWR_HLD: 0,0,A,0,1
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
