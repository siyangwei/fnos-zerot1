#!/usr/bin/env bash
# 28-graphics-modules.sh —— 显示 / 音频 / 网卡内核模块开机加载
#
# fnOS 官方内核是 headless 设计：rockchipdrm、hdptx phy、panel-simple、
# i2s-tdm、es8328 都是 =m 模块，fnOS 的 rootfs 里没有任何地方主动 modprobe
# 它们，所以 eDP 屏不亮、声卡也不注册。
#
# 这里写 /etc/modules-load.d/zerot1-hardware.conf 把它们拉到开机加载，
# 顺序由 modprobe 依赖自己解决。
#
# 用法: 28-graphics-modules.sh <rootfs-dir>
set -euo pipefail
ROOTFS="${1:?usage: $0 <rootfs-dir>}"

mkdir -p "$ROOTFS/etc/modules-load.d"
cat > "$ROOTFS/etc/modules-load.d/zerot1-hardware.conf" <<'CONF'
# zeroT1（AIOT-3588A）板级外设模块
#
# 显示链路（eDP + HDMI1）
rockchipdrm
phy-rockchip-samsung-hdptx
panel-simple
# 音频（ES8388 / es8323 驱动 + I2S0 TDM）
snd-soc-rockchip-i2s-tdm
snd-soc-rockchip-i2s
snd-soc-es8328
snd-soc-es8328-i2c
# 以太网（GMAC1 + RTL8211）
dwmac-rk
stmmac-platform
CONF

echo "  已写入 /etc/modules-load.d/zerot1-hardware.conf"
