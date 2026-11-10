# assets/ —— 预编译产物与第三方二进制

构建时**直接使用**的文件，不在这里编译（编译见 `kernel-modules/`、`scripts/`）。改这里的二进制前先确认有对应源码与重建方法。

## 结构

| 路径 | 内容 | 说明 |
|---|---|---|
| `uboot-upstream/` | 上游 U-Boot v2026.10 产物：`idbloader.img`、`u-boot.itb`、`u-boot-rockchip.bin`、LDR `MiniLoaderAll.bin`、`MD5SUMS` | `src/` 里是**板级源文件**（`zerot1-rk3588_defconfig`、`rk3588-aiot3588a.dts`、`-u-boot.dtsi`），改引导只改这里再跑 `scripts/build-uboot-upstream.sh` |
| `uboot.img` | 厂商定制 u-boot（4MB） | 仅 `UBOOT_MODE=vendor` 时使用，上游模式已不再引用 |
| `MiniLoaderAll.bin` | 上游 LDR loader（uf 刷写时放在 loader 槽） | 由 `scripts/make-ldr-loader.sh` 生成，必须是 LDR 容器 |
| `modules/<ver>/` | 预编译内核模块：`analogix_dp.ko`（eDP）、`tcpm.ko`（Type-C defer 修复）、`smdt_mcu_wdt.ko`（MCU 看门狗）、`brcmfmac*.ko` | `<ver>` 与内核版本对应（当前 `6.18.18-trim`）；源码在 `kernel-modules/` |
| `bcmdhd/` | bcmdhd WiFi 驱动：模块、源码、固件 | 默认 WiFi 驱动（替代 brcmfmac） |
| `adbd-ss-shim/` | `libadbd_ss_shim.so` + **`adbd_ss_shim.c` 源码** | adb USB3 SuperSpeed 描述符 shim；改源码后重新编译放回这里 |
| `rkbin/` | Rockchip 官方 bin（BL31、DDR TPL、usbplug） | 上游 u-boot 构建时取用 |
| `tools/` | Rockchip 打包工具：`mkupdate.sh`、`boot_merger`、`rkImageMaker`、`afptool`、`resource_tool` | 生成 `update.img` 与 LDR loader 用 |
| `firmware/`、`vendor-ubuntu-adb/` | 固件/厂商 adbd 等杂项 | 按需引用 |

## 约定

- **入库**：所有产物都 commit（CI 直接复用，不重新构建 u-boot）。
- **更新流程**：改源码 → 重编 → 覆盖这里 → 更新 `MD5SUMS`（如 u-boot）→ 重打镜像验证。
- **不要**直接改二进制；`.ko` 必须与 `kernel-modules/` 源码、`patches/kernel/` 记录三者一致。
- `assets/tools/package-file-tmp` 是生成物，已 gitignore。
