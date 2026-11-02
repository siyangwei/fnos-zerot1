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
    # ★★ 关键：mount --rbind 会保留 shared mount propagation —— chroot 内对子挂载
    # （/sys/fs/cgroup、/dev/mqueue、/dev/shm 等）的任何挂载/卸载都会**传播回宿主机**。
    # 2026-10-22 两次把宿主机的 cgroup2 卸载掉，导致 systemd 无法创建 cgroup、
    # 所有 GUI 程序无法启动（polkit/kwin 全挂），只能强制重启。
    # 修复：每次 rbind 后立刻 --make-rslave（单向传播：只从宿主→chroot，不回传）。
    if ! mountpoint -q "$rootfs/sys"; then
        mount --rbind /sys "$rootfs/sys"
        mount --make-rslave "$rootfs/sys"
    fi
    if ! mountpoint -q "$rootfs/dev"; then
        mount --rbind /dev "$rootfs/dev"
        mount --make-rslave "$rootfs/dev"
    fi
    mountpoint -q "$rootfs/dev/pts"  || mount -t devpts devpts "$rootfs/dev/pts"

    # DNS：镜像里的 /etc/resolv.conf 通常指向 systemd-resolved 的 127.0.0.53，
    # chroot 里没有 resolved，apt 会解析失败 ⇒ 构建时临时换成宿主的 resolv.conf。
    if [ -f /etc/resolv.conf ] && [ ! -f "$rootfs/etc/resolv.conf.orig" ]; then
        cp -p "$rootfs/etc/resolv.conf" "$rootfs/etc/resolv.conf.orig" 2>/dev/null || true
        cp -f /etc/resolv.conf "$rootfs/etc/resolv.conf"
    fi

    echo "[chroot] mounted $rootfs"
}

chroot_umount() {
    local rootfs="$1"
    # 还原构建前的 resolv.conf（避免把构建机的 DNS 写进镜像）
    if [ -f "$rootfs/etc/resolv.conf.orig" ]; then
        mv -f "$rootfs/etc/resolv.conf.orig" "$rootfs/etc/resolv.conf" 2>/dev/null || true
    fi
    # 用 -R 递归卸载（先子后父）；不要用 -l（lazy umount 会留下子挂载，
    # systemd 之后处理这些残留 mount unit 时又可能触发传播问题）
    umount -R "$rootfs/dev" 2>/dev/null || true
    umount -R "$rootfs/sys" 2>/dev/null || true
    umount -R "$rootfs/proc" 2>/dev/null || true
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
