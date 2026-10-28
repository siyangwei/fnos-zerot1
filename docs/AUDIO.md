# 音频（ES8388）说明与 RK3588 MCLK 门控坑

本板音频拓扑：

```
CPU i2s0_8ch (0xfe470000)  --I2S(2ch,16bit)-->  ES8388 codec (i2c-7, 0x11)
        ^  MCLK 12.288MHz                          |--> LOUT1/ROUT1 --> 耳机 (HP 检测 GPIO4_C2)
        |                                          |--> LOUT2/ROUT2 --> 功放(喇叭, 使能 GPIO4_A3 = spk-con)
        +-- cru I2S0_8CH_MCLKOUT --(GRF to_io 门控)--+
```

## 结论（2026-10-29 实测）

**RK3588 的 GRF SOC_CON6（`0xfd58c318`）bit0 是 I2S0_8CH MCLKOUT 到 IO 的 “to_io” 门控，
语义是 set-to-disable（1 = 断开，0 = 接通），复位默认 1（断开）。**

所以会出现“一切看起来都正常但没声音”：

| 检查项 | 现象 |
|---|---|
| `clk_summary` | `i2s0_8ch_mclkout` 12.288MHz enabled，consumer `7-0011` |
| codec 寄存器 | `0x04=0x0c`（DAC/LOUT2/ROUT2 上电）、`0x27/0x2a=0xb8`（DAC→mixer 通）、音量满 |
| DAPM | 全 On（Left DAC → Left Mixer → Left Out 2 → LOUT2 → Speaker） |
| I2S 控制器 | `XFER=3`、`FIFOLR` 在排空、LRCK 48kHz |
| 功放 | 播放/停止时咔哒（使能有效） |

**但 ES8388 收不到 MCLK → DAC 无时钟 → 完全无声**（耳机仅一边有沙沙声）。

修复（写 GRF，高 16 位是写使能掩码，只允许改 bit0）：

```sh
# 读: 0xfd58c318 = 0x000007c7
busybox devmem 0xfd58c318 32 0x000107C6
# 写后 = 0x000007c6 → 立刻出声
```

## 为什么不用 DTS 解决

BSP 内核（Rockchip 5.10 / 6.1）里有 `rockchip,clk-out` 驱动
（`drivers/clk/rockchip/clk-out.c`），DTS 里这样写即可：

```dts
&i2s0_8ch { ... };

codec@11 {
    compatible = "everest,es8388";
    clocks = <&mclkout_i2s0>;      /* rk3588s.dtsi: mclkout-i2s0@fd58c318 */
    clock-names = "mclk";
    assigned-clocks = <&mclkout_i2s0>;
    assigned-clock-rates = <12288000>;
};
```

Android 树 `kernel-6.1` 就是这个改法（commit `954c252cd4e`）。

**但 fnOS 官方内核是 mainline 6.18，没有 `clk-out` 驱动**（该驱动是 Rockchip 私有，未进 mainline），
DTS 写了也没人解析 ⇒ 本项目用开机的 systemd oneshot 服务写 GRF：

- `patches/rootfs/26-audio-mclk.sh` 生成：
  - `/usr/local/sbin/zt1-audio-mclk.sh`
  - `/etc/systemd/system/zt1-audio-mclk.service`（`Before=sound.target`，oneshot）
  - enable 到 `multi-user.target.wants`

## 其它相关

- 执行器/驱动：mainline `sound/soc/codecs/es8328.c`（`compatible = "everest,es8388"`）能正确驱动这颗芯片，
  DAPM 路由 `LOUT2/ROUT2` 为喇叭、`LOUT1/ROUT1` 为耳机，无需改驱动。
- 功放使能：`spk-con` = GPIO4_A3，DT 里 `GPIO_ACTIVE_LOW` + gpio-hog `output-high`（逻辑 1 = 物理低 = 功放使能）。
- 混音：`amixer -c 1`（PCM 音量、Output 1/2 音量、`Route=Stereo`）。
- 耳机检测：`Headphones Jack` 在 codec 上；`Headphones`/`Speaker` DAPM 由驱动切换。
