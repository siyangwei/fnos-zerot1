#!/bin/bash
# 58-kernel-sync.sh —— 让 fnOS Web 更新后的新内核真正生效（/boot 版本化 + Image/uInitrd 软链同步）
#
# 背景（2026-11-04 实测）：
#   fnOS 的 Web 更新是「逐包 dpkg 安装」，新内核会写 /boot/vmlinuz-<ver>、initrd.img-<ver>。
#   官方镜像的 /boot 是 512MB 且 Image/uInitrd 是指向当前版本文件的**符号链接**，所以
#   装完新内核后 u-boot 加载 /Image 自动就是新内核。
#   我们早期镜像只有 64MB boot + 普通文件 Image/uInitrd，因此：
#     ① dpkg 写 42.8MB vmlinuz 直接 ENOSPC（更新失败）；
#     ② 即使写进去，Image 仍指向旧内核（更新"成功"但不生效）。
#   images 已把 boot 改成 512MB + 版本化文件名 + 软链（scripts/pack-image.sh）。
#   本补丁补上「内核安装后自动生成 initrd/uInitrd、重建我们打补丁的 analogix_dp.ko、
#   并把软链切到新内核」这半件事，否则新内核缺少 eDP 修复（会黑屏/不显示）。
#
# 安全设计：
#   - 默认 AUTOSYNC=1：Web 更新装上新内核后，自动重编 eDP 模块 + 生成 initramfs/uInitrd + 切软链；
#     校验不通过会拒绝切换（保持旧内核），--disable 可关闭、--rollback 可回滚；
#   - `zt1-kernel-sync --enable` 打开自动跟随；`--status` 看状态；`--rollback` 回滚；
#   - 编译 eDP 模块 / 生成 initrd 任一步失败都不切换，旧内核继续可用。
set -e
ROOTFS="${1:?用法: 58-kernel-sync.sh <rootfs-dir>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SRC="$REPO/kernel-modules/analogix-dp-6.18.18"
log() { echo "[58-kernel-sync] $*"; }

[ -d "$SRC" ] || { echo "缺少 $SRC（analogix_dp 源码）"; exit 1; }

# ---- 1. eDP 修复模块源码（用目标内核的 linux-headers 现编）----
install -d -m 0755 "$ROOTFS/usr/local/lib/zt1/analogix-dp"
install -m 0644 "$SRC/analogix_dp_core.c" "$SRC/analogix_dp_core.h" \
                "$SRC/analogix_dp_reg.c"  "$SRC/analogix_dp_reg.h" \
                "$SRC/Makefile" "$ROOTFS/usr/local/lib/zt1/analogix-dp/"

# ---- 1b. 其余 zeroT1 外挂模块源码（换内核后同样要重编，否则复位/看门狗修复失效）----
install -d -m 0755 "$ROOTFS/usr/local/lib/zt1/rk806-rstfix" "$ROOTFS/usr/local/lib/zt1/smdt-mcu-wdt"
install -m 0644 "$REPO/kernel-modules/rk806-rstfix/rk806_rstfix.c" \
                "$REPO/kernel-modules/rk806-rstfix/Makefile" \
                "$ROOTFS/usr/local/lib/zt1/rk806-rstfix/"
install -m 0644 "$REPO/kernel-modules/smdt-mcu-wdt/smdt_mcu_wdt.c" \
                "$REPO/kernel-modules/smdt-mcu-wdt/Makefile" \
                "$ROOTFS/usr/local/lib/zt1/smdt-mcu-wdt/"

# ---- 2. 同步脚本 ----
install -d -m 0755 "$ROOTFS/usr/local/sbin" "$ROOTFS/etc/zerot1" "$ROOTFS/var/lib/zt1-kernel-sync"
cat > "$ROOTFS/usr/local/sbin/zt1-kernel-sync" <<'EOS'
#!/bin/bash
# zt1-kernel-sync —— 把 /boot/Image|uInitrd 同步到最新安装的内核（并重建 eDP 补丁模块）
# 触发：zt1-kernel-sync.service（开机）+ zt1-kernel-sync.path（/boot 有变化，比如 Web 更新装完内核）
set -u
CONF=/etc/zerot1/kernel-sync.conf
LOG=/var/log/zt1-kernel-sync.log
BOOT=/boot
STATE=/var/lib/zt1-kernel-sync
DST=/usr/local/lib/zt1/analogix-dp
MODREL=kernel/drivers/gpu/drm/bridge/analogix

AUTOSYNC=1
REBOOT_AFTER_SYNC=1
AUTOMODE=0
[ -r "$CONF" ] && . "$CONF"

# 并发保护：path 触发与开机触发可能同时进来，避免重复重编/重复切软链
mkdir -p "$STATE"
exec 9>"$STATE/lock"
flock -n 9 || { echo "[$(date '+%F %T')] 另一个同步进程在运行，跳过" >> "$LOG"; exit 0; }

log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }
say() { log "$*"; echo "$*"; }
die() { log "失败: $*"; echo "失败: $*" >&2; exit 1; }

case "${1:-}" in
  --enable)  sed -i 's/^AUTOSYNC=.*/AUTOSYNC=1/' "$CONF" 2>/dev/null || echo 'AUTOSYNC=1' >> "$CONF"; say "已启用内核自动同步"; exit 0 ;;
  --disable) sed -i 's/^AUTOSYNC=.*/AUTOSYNC=0/' "$CONF" 2>/dev/null || echo 'AUTOSYNC=0' >> "$CONF"; say "已关闭内核自动同步"; exit 0 ;;
  --status)
      say "AUTOSYNC=$AUTOSYNC"
      say "Image   -> $(readlink "$BOOT/Image" 2>/dev/null || echo '(普通文件)')"
      say "uInitrd -> $(readlink "$BOOT/uInitrd" 2>/dev/null || echo '(普通文件)')"
      echo "--- /boot 内核文件 ---"; ls -lh "$BOOT"/vmlinuz-* "$BOOT"/uInitrd-* 2>/dev/null
      echo "--- 已安装模块 ---"; ls -d /lib/modules/*/ 2>/dev/null
      exit 0 ;;
  --rollback)
      [ -f "$STATE/previous" ] || die "没有回滚记录"
      P="$(cat "$STATE/previous")"
      [ -f "$BOOT/$P" ] || die "旧内核 $BOOT/$P 不存在"
      ln -sfn "$P" "$BOOT/Image"
      ln -sfn "uInitrd-${P#vmlinuz-}" "$BOOT/uInitrd"
      say "已回滚：Image -> $P"
      exit 0 ;;
  --force)  FORCE=1 ;;
  --auto)   AUTOMODE=1 ;;
  *)        FORCE=0 ;;
esac
[ "$*" = "" ] && AUTOMODE=1   # 不带参数（systemd 服务）按自动模式

[ "$AUTOSYNC" = 1 ] || [ "${FORCE:-0}" = 1 ] || { log "AUTOSYNC=0，跳过（zt1-kernel-sync --force 可手动同步）"; exit 0; }

CUR="$(readlink -f "$BOOT/Image" 2>/dev/null || true)"
[ -n "$CUR" ] && [ -f "$CUR" ] || CUR="$BOOT/Image"
NEW="$(ls -1 "$BOOT"/vmlinuz-* 2>/dev/null | sed -n 's#.*/vmlinuz-##p' | sort -V | tail -1)"
[ -n "$NEW" ] || { log "没有 /boot/vmlinuz-*，跳过"; exit 0; }
NEWF="$BOOT/vmlinuz-$NEW"
[ -f "$NEWF" ] || die "$NEWF 不存在"

if [ "$(md5sum < "$NEWF" | cut -d' ' -f1)" = "$(md5sum < "$CUR" | cut -d' ' -f1)" ]; then
    log "已是最新内核 $NEW（Image -> $(basename "$CUR")）"; exit 0
fi

log "发现新内核 $NEW（当前 Image -> $(basename "$CUR")），开始同步"
KDIR="/lib/modules/$NEW"; [ -d "$KDIR" ] || die "缺少 /lib/modules/$NEW"
HB="$KDIR/build"; [ -d "$HB" ] || HB="/usr/src/linux-headers-$NEW"
[ -d "$HB" ] || die "缺少 linux-headers-$NEW，不切换（避免新内核缺 eDP 修复）"
[ -d "$DST" ] || die "缺少 $DST"

# 空间检查（initrd + uInitrd 约 40MB）
AVAIL_MB=$(df -Pm "$BOOT" | awk 'NR==2{print $4}')
[ "${AVAIL_MB:-0}" -ge 120 ] || die "/boot 剩余 ${AVAIL_MB}MB < 120MB，不切换（分区太小？）"

# ---- 1. 重编 analogix_dp.ko ----
BD="$(mktemp -d)"; trap 'rm -rf "$BD"' EXIT
cp -a "$DST"/. "$BD"/
if ! make -C "$HB" M="$BD" ARCH=arm64 modules >"$BD/build.log" 2>&1; then
    tail -20 "$BD/build.log" >> "$LOG"; die "analogix_dp.ko 编译失败（新内核 $NEW），不切换"
fi
[ -f "$BD/analogix_dp.ko" ] || die "编译产物缺失，不切换"
MODDIR="$KDIR/$MODREL"; mkdir -p "$MODDIR"
[ -f "$MODDIR/analogix_dp.ko" ] && cp -f "$MODDIR/analogix_dp.ko" "$STATE/analogix_dp.ko.$NEW.bak"
cp -f "$BD/analogix_dp.ko" "$MODDIR/analogix_dp.ko"
depmod "$NEW" >/dev/null 2>&1 || log "警告: depmod $NEW 失败（不致命）"
log "已安装 eDP 修复模块到 $MODDIR"

# ---- 1b. 重编 zeroT1 外挂模块（RK806 PMIC 复位修复 / MCU 看门狗）----
for pair in rk806-rstfix:rk806_rstfix smdt-mcu-wdt:smdt_mcu_wdt; do
    md="${pair%%:*}"; ko="${pair##*:}"; sd="/usr/local/lib/zt1/$md"
    [ -d "$sd" ] || { log "跳过 $md（源码缺失）"; continue; }
    bd="$(mktemp -d)"
    cp -a "$sd"/. "$bd"/
    if make -C "$HB" M="$bd" ARCH=arm64 modules >"$bd/build.log" 2>&1 && [ -f "$bd/$ko.ko" ]; then
        edir="$KDIR/updates/zerot1"; mkdir -p "$edir"
        cp -f "$bd/$ko.ko" "$edir/$ko.ko"
        log "已安装 $ko.ko 到 $edir"
    else
        log "警告: $ko.ko 编译失败（新内核 $NEW），跳过（不致命，但对应硬件修复会失效）"
        tail -10 "$bd/build.log" >> "$LOG"
    fi
    rm -rf "$bd"
done
depmod "$NEW" >/dev/null 2>&1 || log "警告: depmod $NEW 失败（不致命）"

# ---- 2. initrd.img + uInitrd ----
command -v mkinitramfs >/dev/null 2>&1 || die "缺少 mkinitramfs"
command -v mkimage     >/dev/null 2>&1 || die "缺少 mkimage（u-boot-tools）"
mkinitramfs -o "$BOOT/initrd.img-$NEW" "$NEW" >>"$LOG" 2>&1 || die "mkinitramfs 失败，不切换"
# 注意：mkinitramfs 按 /etc/initramfs-tools/initramfs.conf 的 COMPRESS（本镜像=zstd）**已经压缩**，
# 不能再压一次！2026-11-04 踩坑：二次 zstd 后内核报 "Initramfs unpacking failed: no cpio magic"
# 直接 panic（VFS: Unable to mount root fs）。这里按 magic 判断，只有未压缩的 cpio 才压。
PAYLOAD="$BOOT/initrd.img-$NEW"
MAGIC="$(od -An -tx1 -N4 "$BOOT/initrd.img-$NEW" | tr -d ' \n')"
case "$MAGIC" in
    28b52ffd|1f8b*|fd377a58|04224d18|425a68*) : ;;   # 已压缩（zstd/gzip/xz/lz4/bzip2）
    *) zstd -q -19 -f "$BOOT/initrd.img-$NEW" -o "$BOOT/initrd.img-$NEW.zst" >>"$LOG" 2>&1 \
           || die "zstd 失败，不切换"
       PAYLOAD="$BOOT/initrd.img-$NEW.zst" ;;
esac
log "initrd 格式 magic=$MAGIC（已压缩则直接打包，避免二次压缩）"
# 切换前必须验证「解一层后就是 cpio」——2026-11-04 就是这里翻车：
# 二次压缩导致内核 "Initramfs unpacking failed: no cpio magic" → panic → 板子开不了机。
case "$MAGIC" in
    28b52ffd) CPIO_MAGIC="$(zstdcat "$PAYLOAD" 2>/dev/null | head -c 6)" ;;
    1f8b*)    CPIO_MAGIC="$(gzip -dc "$PAYLOAD" 2>/dev/null | head -c 6)" ;;
    fd377a58) CPIO_MAGIC="$(xzcat "$PAYLOAD" 2>/dev/null | head -c 6)" ;;
    *)        CPIO_MAGIC="$(head -c 6 "$PAYLOAD")" ;;
esac
case "$CPIO_MAGIC" in
    07070*) : ;;
    *) die "initrd 解开后不是 cpio（magic='$CPIO_MAGIC'），拒绝切换内核" ;;
esac
mkimage -A arm64 -O linux -T ramdisk -C none -n "uInitrd $NEW" \
        -d "$PAYLOAD" "$BOOT/uInitrd-$NEW" >>"$LOG" 2>&1 || die "mkimage 失败，不切换"
[ "$PAYLOAD" = "$BOOT/initrd.img-$NEW.zst" ] && rm -f "$BOOT/initrd.img-$NEW.zst"
# 再确认 uInitrd 里是同一份载荷（uImage 头 64B）
[ "$(dd if="$BOOT/uInitrd-$NEW" bs=1 skip=64 count=4 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "$MAGIC" ] \
    || die "uInitrd 头部载荷校验失败，不切换"
log "已生成 $BOOT/uInitrd-$NEW（$(du -h "$BOOT/uInitrd-$NEW" | cut -f1)）"

# ---- 3. 切换软链（保留旧内核，可 --rollback）----
echo "$(basename "$CUR")" > "$STATE/previous"
ln -sfn "vmlinuz-$NEW" "$BOOT/Image"
ln -sfn "uInitrd-$NEW" "$BOOT/uInitrd"
sync
say "内核已切换：Image -> vmlinuz-$NEW，uInitrd -> uInitrd-$NEW（旧: $(cat "$STATE/previous")，回滚: zt1-kernel-sync --rollback）"

# ---- 4. 自动模式且允许时，自动重启一次让新内核生效 ----
# fnOS Web 更新会先自动重启一次（此时 Image 仍指旧内核），本服务随后才切换软链，
# 所以这里再重启一次，用户不用手动操作即可进入新内核。
if [ "$AUTOMODE" = 1 ] && [ "$REBOOT_AFTER_SYNC" = 1 ]; then
    say "按配置自动重启以启用新内核（REBOOT_AFTER_SYNC=1，30 秒后重启）"
    sync
    # 优先用 transient timer（独立于本服务，服务退出后仍会触发）
    if ! systemd-run --on-active=30 --collect --unit="zt1-ksync-reboot-$$" \
            /bin/systemctl reboot >>"$LOG" 2>&1; then
        log "systemd-run 失败，改用 shutdown -r 定时重启"
        shutdown -r +1 "zt1-kernel-sync: 切换到新内核" >>"$LOG" 2>&1 \
            || log "警告: 自动重启调度失败，请手动重启"
    fi
fi
EOS
chmod 0755 "$ROOTFS/usr/local/sbin/zt1-kernel-sync"

# ---- 3. 配置文件（默认不自动切换，先验证布局与更新链路）----
cat > "$ROOTFS/etc/zerot1/kernel-sync.conf" <<'EOC'
# fnOS Web 更新后是否自动把 /boot/Image|uInitrd 切到新内核
#   1 = 自动跟随（会重编 eDP 补丁模块 + 生成 initrd，失败则保持旧内核）
#   0 = 只保留更新能力，内核不自动切换
AUTOSYNC=1
# 自动模式下切换成功后是否自动重启一次（1=是，默认；0=等用户手动重启）
REBOOT_AFTER_SYNC=1
EOC
chmod 0644 "$ROOTFS/etc/zerot1/kernel-sync.conf"

# ---- 4. systemd 单元：开机一次 + /boot 变化即触发 ----
cat > "$ROOTFS/etc/systemd/system/zt1-kernel-sync.service" <<'EOF'
[Unit]
Description=zeroT1 kernel sync (/boot/Image,uInitrd -> newest installed kernel)
After=local-fs.target
ConditionPathIsMountPoint=/boot

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/zt1-kernel-sync --auto
Nice=10
IOSchedulingClass=idle
EOF

cat > "$ROOTFS/etc/systemd/system/zt1-kernel-sync.path" <<'EOF'
[Unit]
Description=Watch /boot for newly installed kernels

[Path]
PathChanged=/boot
Unit=zt1-kernel-sync.service

[Install]
WantedBy=paths.target
EOF

install -d -m 0755 "$ROOTFS/etc/systemd/system/multi-user.target.wants" "$ROOTFS/etc/systemd/system/paths.target.wants"
ln -sf /etc/systemd/system/zt1-kernel-sync.service "$ROOTFS/etc/systemd/system/multi-user.target.wants/zt1-kernel-sync.service"
ln -sf /etc/systemd/system/zt1-kernel-sync.path    "$ROOTFS/etc/systemd/system/paths.target.wants/zt1-kernel-sync.path"

log "已安装 zt1-kernel-sync（默认 AUTOSYNC=1；--disable/--status/--rollback）"
