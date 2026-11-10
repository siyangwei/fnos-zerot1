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

# ---- 1b. 其余 zeroT1 外挂模块源码（换内核后同样要重编，否则看门狗修复失效）----
install -d -m 0755 "$ROOTFS/usr/local/lib/zt1/smdt-mcu-wdt"
install -m 0644 "$REPO/kernel-modules/smdt-mcu-wdt/smdt_mcu_wdt.c" \
                "$REPO/kernel-modules/smdt-mcu-wdt/Makefile" \
                "$ROOTFS/usr/local/lib/zt1/smdt-mcu-wdt/"

# ---- 1b2. tcpm defer 修复（Type-C 角色切换，见 kernel-modules/tcpm-defer-fix/README.md）----
# initramfs 与 rootfs 里的原厂 tcpm.ko 都会抢先生效，所以镜像内直接预置修复版：
#   - /boot/uInitrd 里的副本由 scripts/prepare-boot.sh 用 --replace 替换
#   - rootfs 的 kernel 路径在这里覆盖；换内核后由 zt1-kernel-sync 重编再覆盖
KVER="${KVER:-6.18.18-trim}"
install -d -m 0755 "$ROOTFS/usr/local/lib/zt1/tcpm-defer-fix"
install -m 0644 "$REPO/kernel-modules/tcpm-defer-fix/tcpm.c" \
                "$REPO/kernel-modules/tcpm-defer-fix/Makefile" \
                "$ROOTFS/usr/local/lib/zt1/tcpm-defer-fix/"
if [ -f "$REPO/assets/modules/$KVER/tcpm.ko" ] && [ -d "$ROOTFS/lib/modules/$KVER" ]; then
    tcpm_kdir="$ROOTFS/lib/modules/$KVER/kernel/drivers/usb/typec/tcpm"
    install -d -m 0755 "$tcpm_kdir" "$ROOTFS/lib/modules/$KVER/updates/zerot1"
    install -m 0644 "$REPO/assets/modules/$KVER/tcpm.ko" "$tcpm_kdir/tcpm.ko"
    install -m 0644 "$REPO/assets/modules/$KVER/tcpm.ko" "$ROOTFS/lib/modules/$KVER/updates/zerot1/tcpm.ko"
fi

# ---- 1c. 清理历史 rk806_rstfix 残留（RK806 复位模式已由 DTB rockchip,reset-mode=1 接管）----
rm -f "$ROOTFS/etc/modules-load.d/zt1-rk806-rstfix.conf"
rm -f "$ROOTFS"/usr/lib/modules/*/updates/zerot1/rk806_rstfix.ko
rm -f "$ROOTFS"/lib/modules/*/updates/zerot1/rk806_rstfix.ko
rm -rf "$ROOTFS/usr/local/lib/zt1/rk806-rstfix"

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

# 缺 headers/模块目录时不要一次失败就放弃：fnOS 的 dpkg 是先装 image 再装 headers，
# 而 /boot 变化可能在 headers 装好之前触发本脚本。这里 60s 后自动重试（最多 5 次）。
retry_later() {
    local n
    n="$(cat "$STATE/retry" 2>/dev/null || echo 0)"
    if [ "${AUTOMODE:-0}" = 1 ] && [ "$n" -lt 5 ]; then
        n=$((n + 1)); echo "$n" > "$STATE/retry"
        systemd-run --on-active=60 --collect --unit="zt1-ksync-retry-$$" \
            /usr/local/sbin/zt1-kernel-sync --auto >>"$LOG" 2>&1 \
            || log "警告: 调度重试失败（请稍后手动执行 zt1-kernel-sync --force）"
        log "将在 60s 后自动重试（第 $n 次，最多 5 次）"
    fi
}

# ---- bcmdhd（AP6256 WiFi 驱动）换内核后也必须重编，否则只能回退 brcmfmac ----
BLIB="/usr/local/lib/zt1/bcmdhd"
bcmdhd_needed() { [ -d "$BLIB/src" ] && [ -f "$BLIB/src/Makefile" ]; }
bcmdhd_ready() {
    [ -f "$BLIB/modules/$NEW/bcmdhd_sdio.ko" ] && \
    [ -f "$BLIB/modules/$NEW/dhd_static_buf_sdio.ko" ]
}
build_bcmdhd() {
    bcmdhd_needed || { log "跳过 bcmdhd 重编（$BLIB/src 缺失）"; return 0; }
    local bd
    bd="$(mktemp -d)"
    cp -a "$BLIB/src"/. "$bd"/
    if make -C "$HB" M="$bd" ARCH=arm64 \
            CONFIG_BCMDHD_SDIO=y CONFIG_MACH_PLATFORM=y CONFIG_BCMDHD_DTS=y \
            CONFIG_BCMDHD_OOB= CONFIG_BCMDHD_PCIE= CONFIG_BCMDHD_USB= \
            modules >>"$LOG" 2>&1 \
       && [ -f "$bd/bcmdhd_sdio.ko" ] && [ -f "$bd/dhd_static_buf_sdio.ko" ]; then
        mkdir -p "$BLIB/modules/$NEW"
        cp -f "$bd/bcmdhd_sdio.ko" "$bd/dhd_static_buf_sdio.ko" "$BLIB/modules/$NEW/"
        strip --strip-debug "$BLIB/modules/$NEW/"*.ko 2>/dev/null || true
        log "已安装 bcmdhd_sdio.ko 到 $BLIB/modules/$NEW"
        rm -rf "$bd"; return 0
    fi
    log "警告: bcmdhd_sdio 编译失败（新内核 $NEW），WiFi 将回退 brcmfmac"
    tail -10 "$bd/build.log" 2>/dev/null >> "$LOG" || true
    rm -rf "$bd"; return 1
}

# ---- initrd/uInitrd 是否「确实由我们基于补丁模块生成」----
# 2026-11-09 教训：fnOS 内核包会自己生成官方 uInitrd，里面带原厂 analogix_dp.ko（initramfs 优先加载），
# 只看「uInitrd 文件存在」会误判就绪 ⇒ 新内核 eDP 只有背光。这里用 marker 记录生成时的
# 「补丁模块 md5 + uInitrd md5」，两者一致才算就绪。
uintrd_ready() {
    local mk="$BOOT/.zt1-uinitrd-$NEW.md5" mm mu tt
    [ -f "$mk" ] || return 1
    read -r mm mu tt < "$mk" || true
    # 2026-11-09 教训2：marker 末尾若无换行，bash 的 read 在 EOF 未遇换行会返回 1，
    # 曾导致每次开机都误判 initrd 未就绪 → 无限重启循环。这里按内容非空判断。
    [ -n "$mm" ] && [ -n "$mu" ] || return 1
    [ "$mm" = "$(md5sum "$KDIR/$MODREL/analogix_dp.ko" 2>/dev/null | cut -d' ' -f1)" ] || return 1
    [ "$mu" = "$(md5sum "$BOOT/uInitrd-$NEW" 2>/dev/null | cut -d' ' -f1)" ] || return 1
    # 第三位 = tcpm defer 修复模块 md5（2026-11-10 新增）。旧 marker 只有两位，
    # 缺少 tt 时跳过以保持向后兼容（升级后首次同步会重写成三位）。
    if [ -n "$tt" ]; then
        [ "$tt" = "$(md5sum "$KDIR/kernel/drivers/usb/typec/tcpm/tcpm.ko" 2>/dev/null | cut -d' ' -f1)" ] || return 1
    fi
}
build_uintrd() {
    command -v mkinitramfs >/dev/null 2>&1 || die "缺少 mkinitramfs"
    command -v mkimage     >/dev/null 2>&1 || die "缺少 mkimage（u-boot-tools）"
    mkinitramfs -o "$BOOT/initrd.img-$NEW" "$NEW" >>"$LOG" 2>&1 || die "mkinitramfs 失败，不切换"
    local MAGIC
    MAGIC="$(od -An -tx1 -N4 "$BOOT/initrd.img-$NEW" | tr -d ' \n')"
    case "$MAGIC" in
        28b52ffd|1f8b*|fd377a58|04224d18|425a68*) : ;;
        *) zstd -19 -f -q "$BOOT/initrd.img-$NEW" -o "$BOOT/initrd.img-$NEW.zst" \
               && mv -f "$BOOT/initrd.img-$NEW.zst" "$BOOT/initrd.img-$NEW" \
               || die "initrd 压缩失败" ;;
    esac
    local P="$BOOT/initrd.img-$NEW"
    local CPIO_MAGIC
    case "$MAGIC" in
        1f8b*) CPIO_MAGIC="$(gzip -dc "$P" 2>/dev/null | head -c5)" ;;
        fd377a58) CPIO_MAGIC="$(xzcat "$P" 2>/dev/null | head -c5)" ;;
        04224d18) CPIO_MAGIC="$(lz4 -dc "$P" 2>/dev/null | head -c5)" ;;
        425a68*) CPIO_MAGIC="$(bzip2 -dc "$P" 2>/dev/null | head -c5)" ;;
        *) CPIO_MAGIC="$(zstdcat "$P" 2>/dev/null | head -c5)" ;;
    esac
    [ "${CPIO_MAGIC:0:4}" = "0707" ] || die "initrd 解开后不是 cpio（magic='$CPIO_MAGIC'），拒绝切换内核"
    mkimage -A arm64 -O linux -T ramdisk -C none -d "$P" "$BOOT/uInitrd-$NEW" >>"$LOG" 2>&1 \
        || die "mkimage 失败，不切换"
    local PAYLOAD
    PAYLOAD="$(od -An -tx1 -N4 -j64 "$BOOT/uInitrd-$NEW" | tr -d ' \n')"
    [ "$PAYLOAD" = "$MAGIC" ] || die "uInitrd 头部载荷校验失败，不切换"
    local MK="$BOOT/.zt1-uinitrd-$NEW.md5" MM UU TT
    MM="$(md5sum "$KDIR/$MODREL/analogix_dp.ko" 2>/dev/null | cut -d' ' -f1)"
    UU="$(md5sum "$BOOT/uInitrd-$NEW" 2>/dev/null | cut -d' ' -f1)"
    TT="$(md5sum "$KDIR/kernel/drivers/usb/typec/tcpm/tcpm.ko" 2>/dev/null | cut -d' ' -f1)"
    [ -n "$MM" ] && [ -n "$UU" ] || die "marker 计算失败，不切换"
    if [ -n "$TT" ]; then
        printf '%s %s %s\n' "$MM" "$UU" "$TT" > "$MK"
    else
        printf '%s %s\n' "$MM" "$UU" > "$MK"
    fi
    log "已生成 uInitrd-$NEW（marker：补丁模块 md5 + uInitrd md5 + tcpm md5）"
}

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

# ★判断是否真的需要同步：不能只看 Image 是否已指向新内核。
# 2026-11-05 实测：fnOS 内核包的 postinst 自己会把 /boot/Image 软链切到新内核，
# 而我们的 eDP 补丁模块/initrd 还是官方的 ⇒ 新内核起来后 eDP 黑屏（只有背光）。
# 因此这里额外校验「目标内核的 analogix_dp.ko 是否含我们的 zt1_ 补丁参数」+
# 「/boot/uInitrd-<ver> 是否存在」，缺任意一项都要重做一遍（重编模块 + 重生成 initrd）。
KDIR="/lib/modules/$NEW"
HB="$KDIR/build"; [ -d "$HB" ] || HB="/usr/src/linux-headers-$NEW"
patched_module() {
    local m="$KDIR/$MODREL/analogix_dp.ko"
    [ -f "$m" ] && strings "$m" 2>/dev/null | grep -q 'zt1_bpc'
}
SAME=0
if [ -n "${CUR:-}" ] && [ -f "$CUR" ] && \
   [ "$(md5sum < "$NEWF" | cut -d' ' -f1)" = "$(md5sum < "$CUR" | cut -d' ' -f1)" ]; then
    SAME=1
fi
CORE_READY=0
if patched_module && uintrd_ready; then CORE_READY=1; fi
if [ "$SAME" = 1 ] && [ "$CORE_READY" = 1 ] && bcmdhd_ready; then
    log "已是最新内核 $NEW（Image -> $(basename "$CUR")，补丁模块/bcmdhd/uInitrd 均已就绪）"; exit 0
fi
# 内核已切到 $NEW、eDP 模块与 uInitrd 都就绪，只差 bcmdhd（常见于换内核时编译被打断）：
# 只补编 WiFi 驱动并重启 wifi 驱动服务，不重复切软链、不安排重启。
if [ "$SAME" = 1 ] && patched_module && { [ "$CORE_READY" = 0 ] || ! bcmdhd_ready; }; then
    log "内核已是 $NEW，但补丁/initrd/bcmdhd 有缺失，进入修复模式（已在运行该内核）"
    [ -d "$KDIR" ] || die "缺少 /lib/modules/$NEW"
    if [ ! -d "$HB" ]; then retry_later; die "缺少 linux-headers-$NEW，稍后重试"; fi
    NEED_REBOOT=0
    if uintrd_ready; then
        log "uInitrd 就绪，跳过重生成"
    else
        log "uInitrd 缺失或非补丁版，重新生成（需要重启后生效）"
        build_uintrd
        ln -sfn "vmlinuz-$NEW" "$BOOT/Image"
        ln -sfn "uInitrd-$NEW" "$BOOT/uInitrd"
        NEED_REBOOT=1
    fi
    if ! bcmdhd_ready && bcmdhd_needed; then
        if build_bcmdhd; then
            systemctl restart zt1-wifi-driver 2>/dev/null || true
            log "bcmdhd 已补齐并重启 zt1-wifi-driver"
        else
            retry_later
        fi
    fi
    if [ "$NEED_REBOOT" = 1 ] && [ "$AUTOMODE" = 1 ] && [ "$REBOOT_AFTER_SYNC" = 1 ]; then
        say "initrd 已更新，30 秒后自动重启以生效"
        systemd-run --on-active=30 --collect --unit="zt1-ksync-reboot-$$" /bin/systemctl reboot \
            >>"$LOG" 2>&1 || shutdown -r +1 "zt1-kernel-sync: initrd 更新" >>"$LOG" 2>&1 || true
    fi
    exit 0
fi
if [ "$SAME" = 1 ]; then
    log "Image 已指向 $NEW，但补丁模块/uInitrd/bcmdhd 未就绪（fnOS 自己改的软链？），补做同步"
fi

log "发现新内核 $NEW（当前 Image -> $(basename "${CUR:-无}")），开始同步"
[ -d "$KDIR" ] || die "缺少 /lib/modules/$NEW"
if [ ! -d "$HB" ]; then
    retry_later
    die "缺少 linux-headers-$NEW，不切换（避免新内核缺 eDP 修复）"
fi
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

# ---- 1b. 重编 zeroT1 外挂模块（MCU 看门狗）----
for pair in smdt-mcu-wdt:smdt_mcu_wdt; do
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

# ---- 1b2. 重编 tcpm defer 修复模块（Type-C 角色切换；必须覆盖 kernel 路径原文件，
#         因为 initramfs/rootfs 里原厂 tcpm.ko 会抢先生效）----
TCLIB="/usr/local/lib/zt1/tcpm-defer-fix"
if [ -d "$TCLIB" ]; then
    bd="$(mktemp -d)"
    cp -a "$TCLIB"/. "$bd"/
    if make -C "$HB" M="$bd" ARCH=arm64 modules >"$bd/build.log" 2>&1 && [ -f "$bd/tcpm.ko" ]; then
        strip --strip-debug "$bd/tcpm.ko" 2>/dev/null || true
        tk="$KDIR/kernel/drivers/usb/typec/tcpm"; mkdir -p "$tk"
        [ -f "$tk/tcpm.ko" ] && cp -f "$tk/tcpm.ko" "$STATE/tcpm.ko.$NEW.bak"
        cp -f "$bd/tcpm.ko" "$tk/tcpm.ko"
        mkdir -p "$KDIR/updates/zerot1"
        cp -f "$bd/tcpm.ko" "$KDIR/updates/zerot1/tcpm.ko"
        log "已安装 tcpm defer 修复模块到 $tk/tcpm.ko"
    else
        log "警告: tcpm.ko 编译失败（新内核 $NEW），Type-C 角色切换可能随机失效"
        tail -10 "$bd/build.log" >> "$LOG"
    fi
    rm -rf "$bd"
fi
depmod "$NEW" >/dev/null 2>&1 || log "警告: depmod $NEW 失败（不致命）"

# ---- 1c. bcmdhd 推迟到二次重启后由「修复模式」补齐 ----
# bcmdhd 编译约 3~4 分钟，放在切换前会显著推迟二次重启；它只是运行时可加载模块，
# 不影响首次起来的内核/initrd。这里只提示，下一次开机时 repair 分支会自动补编并重启 WiFi。
if bcmdhd_needed && ! bcmdhd_ready; then
    log "bcmdhd 模块暂缺，将在重启后自动补齐（不影响 eDP/系统启动）"
fi

# ---- 2. initrd.img + uInitrd（必须基于刚装好的补丁模块）----
build_uintrd

# ---- 3. 切换软链（保留旧内核，可 --rollback）----
echo "$(basename "$CUR")" > "$STATE/previous"
ln -sfn "vmlinuz-$NEW" "$BOOT/Image"
ln -sfn "uInitrd-$NEW" "$BOOT/uInitrd"
sync
rm -f "$STATE/retry"
say "内核已切换：Image -> vmlinuz-$NEW，uInitrd -> uInitrd-$NEW（旧: $(cat "$STATE/previous")，回滚: zt1-kernel-sync --rollback）"

# ---- 4. 自动模式且允许时，自动重启一次让新内核生效 ----
# fnOS Web 更新会先自动重启一次（此时 Image 仍指旧内核），本服务随后才切换软链，
# 所以这里再重启一次，用户不用手动操作即可进入新内核。
if [ "$(uname -r)" = "$NEW" ]; then
    say "当前运行内核已是 $NEW，无需重启"
elif [ "$AUTOMODE" = 1 ] && [ "$REBOOT_AFTER_SYNC" = 1 ]; then
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
# 编译模块（bcmdhd 约 3~4 分钟）+ mkinitramfs 可能超过默认 90s 的 oneshot 超时，
# 曾被 SIGTERM 打断（make 已终止）导致模块/initrd 未生成，务必放宽。
TimeoutStartSec=1800
TimeoutStopSec=120
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
