#!/bin/bash
# ============================================================================
# 26-audio-mclk.sh - 打开 RK3588 I2S0 MCLK 到 IO 的 GRF 门控（ES8388 出声的必要条件）
#
# 背景（2026-10-29 实测确认）：
#   RK3588 的 GRF SOC_CON6 @ 0xfd58c318 bit0 是 I2S0_8CH 的 MCLKOUT "to_io" 门控，
#   语义是 **set-to-disable**（1 = 断开 MCLK 到 IO，0 = 接通）。
#   该位复位值为 1（BL31/u-boot 之后也是 1），因此：
#     clk_summary 里 i2s0_8ch_mclkout 显示 12.288MHz 已使能、consumer 也挂着 7-0011，
#     codec 寄存器（DAC 电源、混音、音量、DAPM 路由）全部正常，
#     功放（GPIO4_A3）也会随播放咔哒，
#     但 **ES8388 实际收不到 MCLK** -> DAC 无时钟 -> 完全无声（耳机只有沙沙声）。
#   用 busybox devmem 清 bit0 后立刻出声（用户实测确认）。
#
#   注意写成格式：GRF 寄存器高 16 位是写使能掩码，只清 bit0 时要写
#   (0x0001 << 16) | (原值 & ~1)，即 0x000107C6。
#
#   mainline 6.18 没有 BSP 的 rockchip,clk-out 驱动，故用开机 oneshot 脚本落位。
# ============================================================================
set -e

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../../scripts/lib-common.sh"

[ -n "$ROOTFS" ] || die "ROOTFS 未设置"
[ -d "$ROOTFS" ] || die "rootfs 不存在: $ROOTFS"

mkdir -p "$ROOTFS/usr/local/sbin"
cat > "$ROOTFS/usr/local/sbin/zt1-audio-mclk.sh" << 'SCRIPT'
#!/bin/sh
# RK3588 GRF SOC_CON6 @0xfd58c318 bit0 = I2S0_8CH MCLKOUT "to_io" 门控（set-to-disable）
# 默认 1（断开）→ ES8388 收不到 MCLK → 有寄存器无声音。开机清 bit0。
ADDR=0xfd58c318
cur=$(busybox devmem $ADDR 32 2>/dev/null) || exit 0
v=$((cur))
[ $((v & 1)) -eq 0 ] && exit 0          # 已接通
nv=$((v & ~1))
busybox devmem $ADDR 32 $(printf '0x%08x' $(( 0x00010000 | nv )))
logger -t zt1-audio "GRF mclk gate: $cur -> $(busybox devmem $ADDR 32)"
exit 0
SCRIPT
chmod 755 "$ROOTFS/usr/local/sbin/zt1-audio-mclk.sh"

mkdir -p "$ROOTFS/etc/systemd/system"
cat > "$ROOTFS/etc/systemd/system/zt1-audio-mclk.service" << 'UNIT'
[Unit]
Description=Enable I2S0 MCLK output to IO for ES8388 (RK3588 GRF gate)
Before=sound.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/zt1-audio-mclk.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

mkdir -p "$ROOTFS/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/zt1-audio-mclk.service \
       "$ROOTFS/etc/systemd/system/multi-user.target.wants/zt1-audio-mclk.service"

log "已安装 zt1-audio-mclk.service（清 GRF 0xfd58c318 bit0，打开 I2S0 MCLK 到 IO）"
