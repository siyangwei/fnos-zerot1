#!/usr/bin/env bash
# 90-rootfs-resize.sh —— 禁止 fnOS 自动扩容 rootfs（分区布局由我们固定）
#
# 背景（2026-11-05 真机确认）：
#   fnOS 的 `trim` 包自带 `/usr/trim/bin/resize-rootfs.sh` + `resize-rootfs.service`，
#   脚本逻辑：若 rootfs 是最后一个分区且磁盘 >32GB，就把 rootfs 扩到 **28GB**；
#   扩容吃掉的是本应留给「存储空间/存储池」的空闲空间。
#   更麻烦的是：`trim` 包的 postinst **每次升级都会** `systemctl enable resize-rootfs.service`
#   ⇒ 每次 Web 更新后都会重新打开，仅靠 `systemctl mask` 或 /etc/fnnas.conf 的
#   rootfs_resize="no" 都拦不住（那两个是 ophub 的语义，fnOS 自己的脚本不读）。
#
# 解法（双层防护）：
#   1) dpkg-divert 接管 `/usr/trim/bin/resize-rootfs.sh`，换成一个直接 exit 0 的 stub。
#      diversion 记录在 dpkg 数据库里，trim 包升级时新脚本会被装到 `.distrib`，
#      我们的 stub 保留 ⇒ 更新后即使 postinst 重新 enable 服务，脚本也是空操作。
#   2) 兜底自愈：/usr/local/sbin/zt1-rootfs-guard + systemd 单元，开机在
#      resize-rootfs.service 之前检查 stub 是否被覆盖，被覆盖就重新接管并清 marker。
#
# 停用（如需恢复官方行为）：dpkg-divert --remove --rename /usr/trim/bin/resize-rootfs.sh
#                            并删掉 /etc/systemd/system/zt1-rootfs-guard.service
#
# 用法: 90-rootfs-resize.sh <rootfs-dir>
set -euo pipefail
ROOTFS="${1:?用法: $0 <rootfs-dir>}"

log() { echo "[90-rootfs-resize] $*"; }

install -d -m755 "$ROOTFS/usr/local/sbin" "$ROOTFS/etc/systemd/system"

# ---- 1) 兜底自愈脚本 -------------------------------------------------------
cat > "$ROOTFS/usr/local/sbin/zt1-rootfs-guard" <<'EOS'
#!/bin/bash
# zt1-rootfs-guard —— 阻止 fnOS 自动扩容 rootfs（ZeroT1 定制，2026-11-05）
#
# 为什么需要：trim 包的 postinst 每次升级都会 systemctl enable resize-rootfs.service，
# 该服务调 /usr/trim/bin/resize-rootfs.sh 把 rootfs 扩到 28GB（磁盘 >32GB 时），
# 会吃掉留给存储池的空间。这里用 dpkg-divert + stub 让它变成空操作，
# 并在每次开机时自愈（防包升级把我们接管冲掉）。
set -u

STUB_MARK="zt1-rootfs-guard: stub"
TARGET=/usr/trim/bin/resize-rootfs.sh
DISTRIB="$TARGET.distrib"
UNIT_LINKS="/etc/systemd/system/basic.target.wants/resize-rootfs.service /etc/systemd/system/multi-user.target.wants/resize-rootfs.service /etc/systemd/system/sysinit.target.wants/resize-rootfs.service"

log() { logger -t zt1-rootfs-guard "$*" 2>/dev/null || true; }

log_line() {  # 没有 logger 时也能留下痕迹
    log "$*"
}

# 1) 确保 dpkg-divert 已登记（这样 trim 升级会把新脚本装到 .distrib，不会覆盖 stub）
if command -v dpkg-divert >/dev/null 2>&1 && ! dpkg-divert --list 2>/dev/null | grep -qF "$TARGET"; then
    if [ -f "$DISTRIB" ]; then
        dpkg-divert --local --add "$TARGET" >/dev/null 2>&1 || true
        log_line "已登记 diversion（采用已有 .distrib）"
    elif [ -f "$TARGET" ]; then
        dpkg-divert --local --rename --add "$TARGET" >/dev/null 2>&1 || true
        log_line "已登记 diversion 并改名原脚本"
    fi
fi

# 2) 确保 TARGET 是 stub
if ! grep -qF "$STUB_MARK" "$TARGET" 2>/dev/null; then
    if [ -f "$TARGET" ] && [ ! -f "$DISTRIB" ]; then
        mv -f "$TARGET" "$DISTRIB" 2>/dev/null || cp -a "$TARGET" "$DISTRIB" 2>/dev/null || true
    fi
    cat > "$TARGET" <<'STUB'
#!/bin/bash
# zt1-rootfs-guard: stub —— 禁止 fnOS 自动扩容 rootfs（ZeroT1 定制，2026-11-05）
# 原脚本在 /usr/trim/bin/resize-rootfs.sh.distrib；恢复用 dpkg-divert --remove --rename
[[ -e /.trim-need_resize_rootfs ]] && rm -f /.trim-need_resize_rootfs
[[ -e /.trim-need_resize_to_full_disk ]] && rm -f /.trim-need_resize_to_full_disk
logger -t zt1-rootfs-guard "skip fnOS auto-resize (rootfs stays as-is)" 2>/dev/null || true
exit 0
STUB
    chmod 755 "$TARGET"
    log_line "resize-rootfs.sh 已被 stub 接管"
fi

# 3) 去掉 resize-rootfs.service 的 enable 软链（postinst 每次升级会重建）
for l in $UNIT_LINKS; do
    [ -e "$l" ] && rm -f "$l" && log_line "已移除 $l"
done
# 4) mask 掉 resize-rootfs.service（若它是普通单元文件；已是 /dev/null 软链则跳过）
if [ -f /etc/systemd/system/resize-rootfs.service ] && [ ! -L /etc/systemd/system/resize-rootfs.service ]; then
    rm -f /etc/systemd/system/resize-rootfs.service
    ln -sf /dev/null /etc/systemd/system/resize-rootfs.service
    log_line "已 mask resize-rootfs.service"
fi

# 5) 清掉 fnOS 的一次性扩容 marker
rm -f /.trim-need_resize_rootfs /.trim-need_resize_to_full_disk 2>/dev/null || true

exit 0
EOS
chmod 755 "$ROOTFS/usr/local/sbin/zt1-rootfs-guard"

# ---- 2) 开机自愈单元（必须早于 resize-rootfs.service）---------------------
cat > "$ROOTFS/etc/systemd/system/zt1-rootfs-guard.service" <<'EOS'
[Unit]
Description=ZeroT1: block fnOS auto-resize of rootfs
DefaultDependencies=no
After=local-fs.target systemd-remount-fs.service
Before=resize-rootfs.service basic.target
Conflicts=resize-rootfs.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/zt1-rootfs-guard

[Install]
WantedBy=sysinit.target
EOS

install -d -m755 "$ROOTFS/etc/systemd/system/sysinit.target.wants"
ln -sfn /etc/systemd/system/zt1-rootfs-guard.service \
    "$ROOTFS/etc/systemd/system/sysinit.target.wants/zt1-rootfs-guard.service"

# ---- 3) 立即在 chroot 里执行一次（登记 dpkg-divert + 装 stub）------------
# 注意：chroot 里默认没有 /dev（dpkg-divert 要用 /dev/null），必须把宿主 /dev 等 bind 进去，
# 否则会出现"原脚本被覆盖、.distrib 丢失、diversion 没登记"的半成品状态（2026-11-05 踩过）。
CHROOT_OK=0
if command -v chroot >/dev/null 2>&1; then
    MNTED=""
    for d in dev dev/pts proc sys; do
        mkdir -p "$ROOTFS/$d"
        if mount --bind "/$d" "$ROOTFS/$d" 2>/dev/null; then MNTED="$(printf '%s %s' "$MNTED" "$ROOTFS/$d")"; fi
    done
    if chroot "$ROOTFS" /usr/local/sbin/zt1-rootfs-guard >/dev/null 2>&1; then CHROOT_OK=1; fi
    for m in $MNTED; do umount "$m" 2>/dev/null || true; done
fi

# 校验 chroot 的成果；不完整则宿主侧兜底（保留原脚本为 .distrib 再写 stub）
TGT="$ROOTFS/usr/trim/bin/resize-rootfs.sh"
if ! grep -qF "zt1-rootfs-guard: stub" "$TGT" 2>/dev/null; then
    if [ -f "$TGT" ] && [ ! -f "$TGT.distrib" ]; then
        cp -a "$TGT" "$TGT.distrib"
    fi
    cat > "$TGT" <<'STUB'
#!/bin/bash
# zt1-rootfs-guard: stub —— 禁止 fnOS 自动扩容 rootfs（ZeroT1 定制，2026-11-05）
# 原脚本在 /usr/trim/bin/resize-rootfs.sh.distrib；恢复用 dpkg-divert --remove --rename
[[ -e /.trim-need_resize_rootfs ]] && rm -f /.trim-need_resize_rootfs
[[ -e /.trim-need_resize_to_full_disk ]] && rm -f /.trim-need_resize_to_full_disk
logger -t zt1-rootfs-guard "skip fnOS auto-resize (rootfs stays as-is)" 2>/dev/null || true
exit 0
STUB
    chmod 755 "$TGT"
    log "宿主侧兜底安装 stub（chroot 不可用；diversion 由开机自愈单元登记）"
fi
[ -f "$TGT.distrib" ] || cp -a /tmp/resize-rootfs.orig.sh "$TGT.distrib" 2>/dev/null || true
if grep -qF "/usr/trim/bin/resize-rootfs.sh" "$ROOTFS/var/lib/dpkg/diversions" 2>/dev/null; then
    log "dpkg-divert 已登记"
else
    log "提示：diversion 未登记（开机后 zt1-rootfs-guard 会补登记；stub 已生效）"
fi

# ---- 4) 兼容旧逻辑：/etc/fnnas.conf（ophub 语义，无副作用，保留）---------
CONF="$ROOTFS/etc/fnnas.conf"
if [ -f "$CONF" ]; then
    grep -q '^rootfs_resize=' "$CONF" \
        && sed -i 's|^rootfs_resize=.*|rootfs_resize="no"|' "$CONF" \
        || echo 'rootfs_resize="no"' >> "$CONF"
else
    printf 'rootfs_limit_gib="16"\nrootfs_resize="no"\n' > "$CONF"
fi

log "完成：fnOS 自动扩容已被禁用（stub + dpkg-divert + 开机自愈单元）"
log "如需恢复官方行为：dpkg-divert --remove --rename /usr/trim/bin/resize-rootfs.sh 并停用 zt1-rootfs-guard"
