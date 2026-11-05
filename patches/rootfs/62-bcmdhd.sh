#!/bin/bash
# 62-bcmdhd.sh — 用 Broadcom bcmdhd_sdio 驱动替换 brcmfmac（AP6256/BCM43456）
#
# 背景：造通实践 + 我们的实测（板子 AIOT-3588A V1.1）表明：
#   - brcmfmac 在这块板上 5GHz 不稳/DFS 扫描受限（world 域扫不到 DFS，需 US 法规域）
#   - bcmdhd 吞吐更高（实测 host→board 79.9 vs 53.5 Mbps，board→host 129.5 vs 118.5 Mbps），
#     且 FW 自带 DFS 扫描能力
# 组件：assets/bcmdhd/firmware（fw/nvram/config）、modules/<kver>（预编译 ko）、src（换内核时重编）
# 说明：模块按 running kernel 的 vermagic 选择；换内核后由 zt1-kernel-sync 重编
set -euo pipefail
SRC=${SRC_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
: "${ROOTFS:?ROOTFS 未设置}"
ASSETS="$SRC/assets/bcmdhd"
LIB="$ROOTFS/usr/local/lib/zt1/bcmdhd"
log() { echo "[62-bcmdhd] $*"; }

[ -d "$ASSETS" ] || { log "WARN: 缺少 assets/bcmdhd，跳过"; exit 0; }

# 1) 模块 + 源码
install -d "$LIB/modules" "$LIB/src"
for d in "$ASSETS"/modules/*/; do
  [ -d "$d" ] || continue
  kver=$(basename "$d")
  install -d "$LIB/modules/$kver"
  install -m 0644 "$d"*.ko "$LIB/modules/$kver/"
  log "模块: $kver -> $(ls "$d" | tr '\n' ' ')"
done
if [ -f "$ASSETS/src/bcmdhd-src.tgz" ]; then
  tar xzf "$ASSETS/src/bcmdhd-src.tgz" -C "$LIB/src"
  log "源码: $(du -sh "$LIB/src" | cut -f1)"
fi

# 2) 固件 / nvram / 配置
install -d "$ROOTFS/lib/firmware"
install -m 0644 "$ASSETS/firmware/fw_bcm43456c5_ag.bin" "$ROOTFS/lib/firmware/"
install -m 0644 "$ASSETS/firmware/nvram_ap6256.txt" "$ROOTFS/lib/firmware/"
install -m 0644 "$ASSETS/firmware/config_bcm43456c5_ag.txt" "$ROOTFS/lib/firmware/"
# clm blob 复用镜像内 brcmfmac 的同源文件
if [ -f "$ROOTFS/lib/firmware/brcm/brcmfmac43456-sdio.clm_blob" ]; then
  ln -sfn /lib/firmware/brcm/brcmfmac43456-sdio.clm_blob "$ROOTFS/lib/firmware/clm_bcm43456c5_ag.blob"
fi

# 3) blacklist brcmfmac（仅阻止自动加载；显式 modprobe 仍可用作回退）
install -d "$ROOTFS/etc/modprobe.d"
cat > "$ROOTFS/etc/modprobe.d/zt1-bcmdhd.conf" <<'EOF'
# zt1: AP6256 使用 vendor bcmdhd_sdio 驱动（由 zt1-wifi-driver.service 加载）
blacklist brcmfmac
blacklist brcmutil
EOF

# 4) 驱动加载器
install -d "$ROOTFS/usr/local/sbin"
cat > "$ROOTFS/usr/local/sbin/zt1-wifi-driver" <<'EOF'
#!/bin/bash
# zt1-wifi-driver start|stop|status — 加载/卸载 bcmdhd_sdio（按 running kernel 的 vermagic 选模块）
set -u
LIB=/usr/local/lib/zt1/bcmdhd
LOG=/var/log/zt1-wifi-driver.log
log() { echo "$(date '+%F %T') $*" >>"$LOG"; echo "$*"; }
kver=$(uname -r)
find_mod() {
  local f v
  for f in "$LIB"/modules/*/bcmdhd_sdio.ko; do
    [ -f "$f" ] || continue
    v=$(modinfo -F vermagic "$f" 2>/dev/null | awk '{print $1}')
    if [ "$v" = "$kver" ]; then echo "$f"; return 0; fi
  done
  return 1
}
case "${1:-start}" in
  start)
    log "start: kernel=$kver"
    rmmod brcmfmac_wcc 2>/dev/null; rmmod brcmfmac 2>/dev/null; rmmod brcmutil 2>/dev/null
    if [ -d /sys/module/bcmdhd_sdio ]; then log "bcmdhd 已加载"; exit 0; fi
    mod=$(find_mod) || mod=""
    if [ -z "$mod" ]; then
      log "没有匹配 $kver 的 bcmdhd 模块，回退 brcmfmac（可稍后 zt1-kernel-sync 重编）"
      modprobe brcmfmac && exit 0 || exit 1
    fi
    md=$(dirname "$mod")
    insmod "$md/dhd_static_buf_sdio.ko" || { log "dhd_static_buf 加载失败"; modprobe brcmfmac; exit 1; }
    if insmod "$mod" firmware_path=/lib/firmware/fw_bcm43456c5_ag.bin nvram_path=/lib/firmware/nvram_ap6256.txt op_mode=0 iface_name=wlan0; then
      log "bcmdhd 加载成功: $mod"
    else
      log "bcmdhd 加载失败，回退 brcmfmac"; modprobe brcmfmac; exit 1
    fi
    ;;
  stop)
    log "stop: 卸载 bcmdhd"
    modprobe -r bcmdhd_sdio 2>/dev/null; modprobe -r dhd_static_buf_sdio 2>/dev/null
    ;;
  status)
    if [ -d /sys/module/bcmdhd_sdio ]; then echo "bcmdhd_sdio 已加载"; else echo "bcmdhd_sdio 未加载"; fi
    iw dev wlan0 link 2>/dev/null | head -6
    ;;
  *) echo "用法: $0 start|stop|status"; exit 2 ;;
esac
EOF
chmod 0755 "$ROOTFS/usr/local/sbin/zt1-wifi-driver"

# 5) systemd units
install -d "$ROOTFS/etc/systemd/system"
cat > "$ROOTFS/etc/systemd/system/zt1-wifi-driver.service" <<'EOF'
[Unit]
Description=Load vendor bcmdhd_sdio driver for AP6256 (replaces brcmfmac)
DefaultDependencies=no
After=systemd-modules-load.service local-fs.target
Before=NetworkManager.service wpa_supplicant.service network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/zt1-wifi-driver start
ExecStop=/usr/local/sbin/zt1-wifi-driver stop

[Install]
WantedBy=multi-user.target
EOF
cat > "$ROOTFS/etc/systemd/system/zt1-wifi-poweroff.service" <<'EOF'
[Unit]
Description=Power down AP6256 (bcmdhd) before shutdown/reboot
DefaultDependencies=no
Before=shutdown.target reboot.target halt.target kexec.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/zt1-wifi-driver stop

[Install]
WantedBy=shutdown.target reboot.target halt.target kexec.target
EOF
install -d "$ROOTFS/etc/systemd/system/multi-user.target.wants"
ln -sfn /etc/systemd/system/zt1-wifi-driver.service "$ROOTFS/etc/systemd/system/multi-user.target.wants/zt1-wifi-driver.service"
for t in shutdown reboot halt kexec; do
  install -d "$ROOTFS/etc/systemd/system/${t}.target.wants"
  ln -sfn /etc/systemd/system/zt1-wifi-poweroff.service "$ROOTFS/etc/systemd/system/${t}.target.wants/zt1-wifi-poweroff.service"
done

log "完成：bcmdhd 模块/固件/服务已安装（默认驱动，brcmfmac 保留为回退）"
