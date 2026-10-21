#!/usr/bin/env bash
# lib-chroot.sh —— arm64 rootfs chroot 辅助库（在 x86_64 构建机上用 qemu 模拟）
#
# 用法：
#   source scripts/lib-chroot.sh
#   chroot_mount "$ROOTFS"          # 挂载 /proc /sys /dev /dev/pts 并放入 qemu-aarch64-static
#   chroot "$ROOTFS" /bin/bash -c '...'
#   chroot_umount "$ROOTFS"         # 卸载
#
# 需要：root 权限、qemu-aarch64-static（Arch: qemu-user-static；Ubuntu: qemu-user-static）

QEMU_BIN="${QEMU_BIN:-/usr/bin/qemu-aarch64-static}"

chroot_mount() {
    local rootfs="$1"
    [ -d "$rootfs" ] || { echo "rootfs 不存在: $rootfs" >&2; return 1; }

    if [ ! -e "$QEMU_BIN" ]; then
        echo "[chroot] ERROR: 找不到 qemu-aarch64-static ($QEMU_BIN)" >&2
        echo "[chroot]   Arch:   sudo pacman -S qemu-user-static" >&2
        echo "[chroot]   Ubuntu: sudo apt install qemu-user-static" >&2
        return 1
    fi

    # qemu 放进 rootfs（chroot 时内核自己会识别 binfmt 或显式调用）
    if [ ! -f "$rootfs$QEMU_BIN" ]; then
        cp "$QEMU_BIN" "$rootfs$QEMU_BIN"
    fi

    # 挂载点
    mkdir -p "$rootfs"/{proc,sys,dev,dev/pts,tmp,run}
    mountpoint -q "$rootfs/proc"     || mount -t proc proc "$rootfs/proc"
    mountpoint -q "$rootfs/sys"      || mount --rbind /sys "$rootfs/sys"
    mountpoint -q "$rootfs/dev"      || mount --rbind /dev "$rootfs/dev"
    mountpoint -q "$rootfs/dev/pts"  || mount -t devpts devpts "$rootfs/dev/pts"

    echo "[chroot] mounted $rootfs"
}

chroot_umount() {
    local rootfs="$1"
    umount -l "$rootfs/dev/pts" 2>/dev/null || true
    umount -l "$rootfs/dev"     2>/dev/null || true
    umount -l "$rootfs/sys"     2>/dev/null || true
    umount -l "$rootfs/proc"    2>/dev/null || true
    echo "[chroot] unmounted $rootfs"
}

# 在 rootfs 里执行命令（通过 rootfs 内的 qemu-aarch64-static 显式解释，
# 这样不依赖宿主机的 binfmt_misc 注册）
chroot_run() {
    local rootfs="$1"; shift
    chroot "$rootfs" "$QEMU_BIN" /usr/bin/env -i \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        HOME=/root TERM=dumb LANG=C DEBIAN_FRONTEND=noninteractive \
        "$@"
}
