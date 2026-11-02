# RK3588 VPU 硬编解码（MPP / rk_vcodec.ko）启用记录

> 适用：zeroT1（视美泰 AIOT-3588A / RK3588）+ fnOS 官方内核 **6.18.18-trim**（`#491`，devops@fnnas.com，不可重编）
> 日期：2026-10-31 ｜ 结论：**H.264 / HEVC / VP9 硬解 + H.264 硬编 已实测可用**；AV1 硬解受内核限制暂禁用（见 §6）

## 1. 修复前的现象

```bash
ls /dev/mpp_service          # No such file or directory
ls /dev/video*               # No such file or directory
lsmod | grep rk_vcodec       # rk_vcodec 389120  0  ← 模块已经加载
dmesg | grep -i vcodec       # 无 probe 输出
ffmpeg -hwaccel rkmpp ...    # Failed to init MPP context: -1
                             # 用户态日志：mpp_platform: client 4/9/12 driver is not ready!
```

## 2. 根因

fnOS 内核**自带** Rockchip 厂商的 MPP 服务驱动 `rk_vcodec.ko`
（`/lib/modules/6.18.18-trim/updates/trim/rk_vcodec/rk_vcodec.ko`，
由 `/etc/modules-load.d/trim-rk_vcodec.conf` 开机加载），它匹配的是 Rockchip BSP
设备树的 compatible：

| 硬件 | 厂商 compatible（rk_vcodec.ko of_match） |
|---|---|
| MPP 服务容器 | `rockchip,mpp-service` |
| H.264/HEVC 解码 VDPU2 | `rockchip,vpu-decoder-v2` |
| H.264/JPEG 编码 VEPU2 | `rockchip,vpu-encoder-v2` |
| HEVC/VP9 解码 RKVDEC2 | `rockchip,rkv-decoder-v2` |
| RKVDEC2 的 CCU | `rockchip,rkv-decoder-v2-ccu` |
| AV1 解码 | `rockchip,av1-decoder` |

而我们的 mainline 6.18 风格 DTS 里只有 **mainline 占位节点**：
`rockchip,rk3588-vpu121`（mainline 用 hantro 驱动，本内核 `CONFIG_VIDEO_HANTRO` 未编）、
`rockchip,rk3588-vepu121`（JPEG）、`rockchip,rk3588-av1-vpu`（mainline 没有驱动）。
两边 compatible 完全对不上 ⇒ rk_vcodec.ko 虽然加载了但一个设备也 probe 不到 ⇒ 没有
`/dev/mpp_service` ⇒ ffmpeg 的 `rkmpp` 硬解/硬编全部初始化失败。

**为什么可以靠改 DT 修**：fnOS 的内核 IOMMU 驱动是 mainline 6.18 的
`drivers/iommu/rockchip-iommu.c` + 厂商 API 补丁（导出
`rockchip_iommu_enable/disable/force_reset/mask_irq/unmask_irq/is_enabled`），
`/proc/kallsyms` 里都能找到；而且板上 **RGA3（rga3.ko，同为厂商模块）** 已经用同样的方式
在我们的 mainline-iommu 节点上工作。所以只要把厂商 DTS 节点用 mainline 的
clock/reset/power ID 和 mainline 能识别的 iommu compatible 写进来即可，不需要重编内核、
不需要新模块。

## 3. 改动（只改 DTS，其他都不动）

文件：`dts/mainline-6.18/rk3588-aiot3588a.dts`（`rk3588-aiot3588a-usbdev.dts` include 它，自动继承）

1. `&vpu121 { status = "disabled"; }`：关掉 mainline 占位节点（否则同地址冲突且无驱动）。
2. 新增 `mpp_srv: mpp-srv`：`compatible = "rockchip,mpp-service"`，
   `rockchip,taskqueue-count = <12>`、`rockchip,resetgroup-count = <1>`。
3. 新增 VDPU2 / VEPU2：
   - `vdpu: vdpu@fdb50400` → `rockchip,vpu-decoder-v2`，IRQ 119
   - `vepu: vepu@fdb50000` → `rockchip,vpu-encoder-v2`，IRQ 120
   - clocks `aclk_vcodec/hclk_vcodec` = `ACLK_VPU`/`HCLK_VPU`，normal-rates 594MHz/0
   - resets `shared_video_a/shared_video_h` = `SRST_A_VPU`/`SRST_H_VPU`
   - **IOMMU 复用 mainline 已有的 `vpu121_mmu`（iommu@fdb50800）**，其 compatible 本来就是
     `rockchip,rk3588-iommu`,`rockchip,rk3568-iommu`（fnOS 内核认）
   - `rockchip,srv`、`rockchip,taskqueue-node = <0>`、`rockchip,resetgroup-node = <0>`，
     `power-domains = <&power RK3588_PD_VDPU>`
4. 新增 RKVDEC2 + CCU（HEVC/VP9 解码，照抄厂商 `rk3588s.dtsi` 参数）：
   - `rkvdec_ccu: rkvdec-ccu@fdc30000`（`rockchip,rkv-decoder-v2-ccu`, `rockchip,ccu-mode = <1>`）
   - `rkvdec0: rkvdec-core@fdc38000`、`rkvdec1: rkvdec-core@fdc48000`（`rockchip,rkv-decoder-v2`，
     reg 两段 `regs`/`link`，IRQ 95/97，core-mask `0x00010001`/`0x00020002`，
     taskqueue-node 9，task-capacity 16，rcb-iova `0xFFF00000`/`0xFFE00000` + 厂商 rcb-info）
   - `rkvdec0_mmu: iommu@fdc38700`、`rkvdec1_mmu: iommu@fdc48700`：**两个 0x40 的 reg + 1 个中断**
     （mainline `rk_iommu_probe` 会映射全部 reg、`num_mmu++`，IRQ handler 遍历所有 base，支持这种布局），
     compatible 改成 `rockchip,rk3588-iommu`,`rockchip,rk3568-iommu`（厂商的 `rockchip,iommu-v2`
     本内核不认），保留 `rockchip,disable-mmu-reset`
   - `aliases` 里加 `rkvdec0` / `rkvdec1`：驱动用 `of_alias_get_id(np,"rkvdec")` 取 core_id，**必需**
   - RKVDEC 的 RCB 行缓冲必须放在 SoC SRAM：在 `&system_sram2` 下补两个分区
     `rkvdec-sram@0`（0x78000）和 `rkvdec-sram@78000`（0x77000），供 `rockchip,sram` 引用
5. AV1：`av1d_vpu: av1d@fdc70000` + `av1d_mmu: iommu@fdca0000`（`rockchip,iommu-av1d`）节点写好，
   但两个都 `status = "disabled"`（原因见 §6；厂商 BSP 默认也是 disabled）。

> 时钟/复位/电源 ID 全部来自 mainline 6.18 的 dt-bindings：
> `ACLK_VPU/HCLK_VPU`、`ACLK_RKVDEC_CCU`、`CLK_RKVDEC[01]_CORE/CA/HEVC_CA`、
> `SRST_A_RKVDEC_CCU`、`SRST_A/H_VPU`、`RK3588_PD_VDPU/RKVDEC0/RKVDEC1/AV1` 等（均已确认存在）。

## 4. 编译 + 部署（主机上，不需要重编内核）

```bash
cd /path/to/fnos-zerot1
KC=/path/to/linux-6.18.18        # 完整 vanilla 6.18.18 源码，仅用于 cpp 预处理（scripts/build-dts.sh 会下载）
cpp -nostdinc -I$KC/include -I$KC/arch/arm64/boot/dts \
    -I$KC/arch/arm64/boot/dts/rockchip -I dts/mainline-6.18 \
    -undef -D__DTS__ -x assembler-with-cpp \
    dts/mainline-6.18/rk3588-aiot3588a.dts -o /tmp/zt1.dts.pre
/usr/bin/dtc -I dts -O dtb -o /tmp/zt1.dtb /tmp/zt1.dts.pre

# 板子在线时直接替换验证（持久化到 /boot）
adb push /tmp/zt1.dtb /boot/dtb/rockchip/rk3588-aiot3588a.dtb
adb shell 'sync; reboot'                # 约 9s 回来

# 正式镜像：把两个 dtb 放进 work/images/dtb/rockchip/ 后重打镜像即可
#   rk3588-aiot3588a.dtb / rk3588-aiot3588a-usbdev.dtb（usbdev include 主 dts，需一起重编）
# pack-image.sh 在 FNOS_BOOT 路径下会把它们拷进 /boot/dtb/rockchip/
```

> 只有 DTS 变了。rootfs 不用动：`rk_vcodec.ko` 及其依赖（rockchip_opp_select /
> rockchip_system_monitor / rockchip_sip）本来就在镜像里，`trim-rk_vcodec.conf` 开机加载。

## 5. 验证（2026-10-31，板上实测）

### 5.1 设备节点 / 驱动 probe

```bash
ls -l /dev/mpp_service
# crw------- 1 root root 236, 0  /dev/mpp_service

cat /proc/mpp_service/supports-device
# DEVICE[ 1]:VDPU2
# DEVICE[ 3]:VDPU2_PP
# DEVICE[ 9]:RKVDEC    HW_ID:0x53813f05
# DEVICE[18]:VEPU2

dmesg | grep -E "mpp_service|mpp_vdpu2|mpp_vepu2|mpp_rkvdec2"
# mpp_service mpp-srv: probe start
# mpp_vdpu2 fdb50400.vdpu: probe device / probing finish
# mpp_vepu2 fdb50000.vepu: probing start / probing finish
# mpp_rkvdec2 fdc30000.rkvdec-ccu: ccu-mode: 1 / probing finish
# mpp_rkvdec2 fdc38100.rkvdec-core: core_mask=00010001 / attach ccu as core 0
#                                    sram_start 0x...ff001000 / rcb_iova 0x...fff00000 / probing finish
# mpp_rkvdec2 fdc48100.rkvdec-core: core_mask=00020002 / attach ccu as core 1 / probing finish
# mpp_service mpp-srv: probe success
```

### 5.2 硬解（与软解 framemd5 逐帧比对，全部一致）

```bash
# 测试片（主机 ffmpeg 生成后 push 到 /root/）：vpu-h264-1080p.mp4 / vpu-hevc-1080p.mp4 /
# vpu-hevc-4k.mp4 / vpu-vp9-1080p.webm
for pair in "h264 h264_rkmpp" "hevc hevc_rkmpp" "vp9 vp9_rkmpp"; do ... done

ffmpeg -c:v h264_rkmpp -i /root/vpu-h264-1080p.mp4 -pix_fmt yuv420p -f framemd5 -   # 60 帧 IDENTICAL
ffmpeg -c:v hevc_rkmpp -i /root/vpu-hevc-1080p.mp4 -pix_fmt yuv420p -f framemd5 -   # 60 帧 IDENTICAL
ffmpeg -c:v hevc_rkmpp -i /root/vpu-hevc-4k.mp4    -pix_fmt yuv420p -f framemd5 -   # 90 帧 IDENTICAL（3840x2160）
ffmpeg -c:v vp9_rkmpp  -i /root/vpu-vp9-1080p.webm -pix_fmt yuv420p -f framemd5 -   # 90 帧 IDENTICAL
```

### 5.3 硬编

```bash
ffmpeg -f lavfi -i testsrc2=size=1920x1080:rate=30 -t 3 \
       -c:v h264_rkmpp -pix_fmt nv12 -b:v 8M -y /root/enc-h264.mp4
# frame=90, 7570.7 kbits/s, speed=1.9x, 输出 2807469 B，可正常播放
```

## 6. 已知限制 / 风险

| 项 | 状态 | 说明 |
|---|---|---|
| H.264 解码 | ✅ | VDPU2，1080p framemd5 与软解一致 |
| HEVC 解码 | ✅ | RKVDEC2，1080p 与 4K 均一致 |
| VP9 解码 | ✅ | RKVDEC2，1080p 一致 |
| H.264 编码 | ✅ | VEPU2，1080p 正常出流 |
| **AV1 解码** | ❌ 禁用 | 节点/MMU 能 probe（`rk_iommu fdca0000.iommu: av1d iommu enabled`，supports-device 出 `DEVICE[4]:AV1DEC`），但解码时 `dma_buf_map_attachment ... failed(-22)`、`mpp_av1dec: no memory region mapped`，kprobe 显示 `av1_iommu_map` 返回 `-EADDRINUSE(-98)`：fnOS 合并进 mainline 的 AV1D IOMMU 在 dma-iommu 复用 IOVA 时硬件页表残留旧 PTE（页表全局共用）。**这是内核侧问题，DT 修不了**；去掉 `iommus` 直通物理地址会任务超时/花屏。故保持 `status="disabled"`，等内核修好后改回 `okay` 即可（节点本身已验证可 probe） |
| **HEVC 编码** | ❌ | `hevc_rkmpp` 报 `Task finished with error code: -22 (Invalid argument)`（H.264 编码正常）。MPP 用户态对 VEPU2 的限制，未深究；不影响解码 |
| 性能 | 未调优 | 只验证了正确性；频率/带宽/多路并发未测。`shared_niu_a/h is not found`、`no regulator, devfreq is disabled` 是厂商驱动找不到 NIULINK/devfreq 节点的 benign 警告 |
| 用户态噪声 | benign | `mpp_platform: client N driver is not ready!`（AV1DEC/JPEGE 等未启用的核）、`mpp_buf_slot: mismatch h_stride_by_pixel`、`mpp_mem_pool: invalid mem pool ptr`（编码收尾）均无功能影响 |

## 7. 回滚

```bash
cd /path/to/fnos-zerot1
git checkout -- dts/mainline-6.18/rk3588-aiot3588a.dts   # 撤销 DTS 改动
# 重新编出旧 dtb 推回板上 /boot/dtb/rockchip/ 后重启；或直接刷旧镜像
```
