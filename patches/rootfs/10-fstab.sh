#!/usr/bin/env bash
# 10-fstab.sh —— 重写 fnOS rootfs 的 /etc/fstab（与本项目分区布局对齐）
#
# 背景（2026-10-28 实机踩坑，必看）：
#   1) fnOS 官方基础镜像的 fstab 是按它自己的布局写的：
#        /dev/mmcblk0p2  /      btrfs  ... errors=remount-ro
#        /dev/mmcblk0p1  /boot  ext4   ... errors=remount-ro
#      而本项目 repack 后的布局是：
#        p1=uboot(非文件系统) p2=misc p3=resource p4=BOOT(ext4) p5=rootfs(btrfs)
#      ⇒ systemd 挂 / 时把 misc 分区当 btrfs 挂（报 `btrfs: Unknown parameter 'errors'`），
#        挂 /boot 时把 uboot 分区当 ext4 挂（报 `EXT4-fs (mmcblk0p1): VFS: Can't find ext4 filesystem`），
#        结果进入 maintenance 模式（"Give root password for maintenance"），桌面起不来。
#   2) btrfs 不支持 `errors=remount-ro` 这个 ext4 选项，必须去掉。
#
# 用法: 10-fstab.sh <rootfs-dir>
set -euo pipefail

ROOTFS="${1:?usage: $0 <rootfs-dir>}"
FSTAB="$ROOTFS/etc/fstab"

[ -f "$FSTAB" ] || { echo "[10-fstab] ERROR: $FSTAB 不存在"; exit 1; }

# 备份一次（幂等）
[ -f "${FSTAB}.orig" ] || cp "$FSTAB" "${FSTAB}.orig"

cat > "$FSTAB" <<'EOF'
# /etc/fstab —— 由 ZeroT1(fnOS) 项目 patches/rootfs/10-fstab.sh 生成
#
# 本机分区布局（见 parameter.txt）：
#   p1 uboot / p2 misc / p3 resource / p4 BOOT(ext4) / p5 rootfs(btrfs) / p6 userdata
# 根分区也可以由 armbianEnv.txt 的 rootdev(UUID) 挂载；这里写设备路径与之并存。
# 用设备路径而不是 UUID：mkfs 每次重新打包都会换 UUID，写死 UUID 会导致下次进 maintenance。

/dev/mmcblk0p5	/	btrfs	defaults,noatime,compress=zstd:1	0	1
/dev/mmcblk0p4	/boot	ext4	defaults,noatime	0	2
tmpfs		/tmp	tmpfs	defaults,nosuid	0	0

EOF

echo "[10-fstab] 完成，当前生效内容:"
grep -vE '^[[:space:]]*#' "$FSTAB" | grep -vE '^[[:space:]]*$'
