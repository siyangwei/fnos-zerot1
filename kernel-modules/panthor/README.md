# panthor 开源 GPU 驱动（外层模块）

Mali-G610 (Valhall CSF) 的开源内核驱动，取自 mainline Linux **6.18.18**
`drivers/gpu/drm/panthor/`，未做功能修改。fnOS 内核（vendor 定制）没有启用
`CONFIG_DRM_PANTHOR`，所以以 out-of-tree 模块方式编译加载。

## 默认走闭源 kbase，panthor 为可选方案（2026-11-11 用户选型）

| | 闭源 kbase（fnOS 默认） | 开源 panthor |
|---|---|---|
| 内核模块 | `rkgpu_bifrost_csf`（DDK g18p0） | `panthor.ko`（自编） |
| 用户态 | libmali g24p0（fnOS 应用中心安装） | Mesa 25.0.7（系统自带 panthor_dri.so） |
| EGLDevice 平台 | **不支持**（无 `EGL_EXT_platform_device`） | 支持（Mesa） |
| Xorg glamor | 崩（X11 EGL 初始化失败） | 可用（Mali-G610 Panfrost） |
| GNOME Wayland (mutter 43) | 起不来（EGLDevice 平台缺失） | 可启动（但登录后 scanout 失败，见下） |
| 3D/Vulkan/OpenCL | GLES 3.2 / Vulkan 1.2 / OpenCL 3.0 | GL 3.1（Mesa 上限）/ panvk 实验性 / 无 OpenCL |

2026-11-11 曾切到 panthor 验证：它能让 **Xorg glamor 桌面/浏览器/窗口化视频走上 GPU**，
但该路线的 GL 上限是 3.1、3D 性能约为闭源 60~80%，且 X11 下快速甩动鼠标卡顿问题
（根因在 Xorg dirtyfb 同步等 vblank，与 GPU 驱动无关）两种方案都存在。用户最终选型
**默认闭源 kbase**（3D/Vulkan/OpenCL 更强）；panthor 作为可选方案保留（切换方法见
`dts/mainline-6.18/rk3588-aiot3588a.dts` 的 `&gpu` 注释与 `patches/rootfs/40-xfce.sh`）。

## 重要坑

1. **RK3588 的显示与 GPU 是分离的 DRM 设备**：
   - `card0` = rockchip-drm（VOP，eDP/HDMI，有 KMS）
   - `card2` = panthor（render-only，无 KMS）
   - **mutter 43（GNOME Wayland）要求 KMS 与 EGL 渲染在同一 GPU**，跨 GPU 时
     `DRM_IOCTL_MODE_CREATE_DUMB failed / Failed to create scanout resource`，
     登录后画面冻结。**GNOME Wayland 在此架构下不可行**，桌面必须用 Xorg。
2. **不要安装 fnOS 应用中心的「Mali GPU Driver」**：它会把
   `/usr/lib/aarch64-linux-gnu/mali` 插到 `ld.so.conf.d/00-aarch64-mali.conf` 首位，
   libEGL/libgbm 抢占 Mesa，导致 panthor 的 EGL 不可用、Xorg glamor 崩溃。
   如果已经装过，删除该 ld.so 配置文件并 `ldconfig`。
3. **initramfs 优先级**：与 analogix_dp/tcpm 一样，若 uInitrd 里打包了旧
   panthor.ko 会抢先加载。默认镜像的 uInitrd 不含 panthor（只有 boot 分区根目录
   的 uInitrd 由 prepare-boot 重建），rt 见 58-kernel-sync.sh 的预置逻辑。
4. **模块必须用目标内核 headers 编译**（vermagic 匹配），换内核后由
   zt1-kernel-sync 自动重编（58-kernel-sync.sh 1b3 段）。
5. **固件**：需要 `/lib/firmware/mali_csffw.bin`（镜像已带，dmesg 显示
   `CSF FW using interface v1.1.0`）。

## 编译方法（板端）

```bash
cd kernel-modules/panthor
make -C /lib/modules/$(uname -r)/build M=$PWD modules
strip --strip-debug panthor.ko
# 部署到 rootfs（镜像构建时由 58-kernel-sync.sh 预置，这里只是手动验证）：
#   /lib/modules/$(uname -r)/updates/zerot1/panthor.ko   （udev 按 of alias 自动加载）
# udev 加载靠 dts compatible "arm,mali-valhall-csf"（MODALIAS=of:N*T*Crockchip,rk3588-maliC*）
```

## 固件与 dts

- dts `&gpu` 必须为上游形态：
  ```dts
  &gpu {
      compatible = "rockchip,rk3588-mali", "arm,mali-valhall-csf";
      mali-supply = <&vdd_gpu_s0>;
      status = "okay";
  };
  ```
  （不要用 BSP 的 `arm,mali-valhall` + interrupts/clocks 覆盖，那是闭源 kbase 的写法）
- 实测 probe：`clock rate = 198000000`、`Mali-G610 id 0xa867`、
  `Firmware git sha: 814b47b5…`、`Initialized panthor 1.5.0 for fb000000.gpu on minor 2`。
