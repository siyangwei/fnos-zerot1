# dts/ —— 内核板级设备树

fnOS 内核是**预编译**的，板级硬件描述只能通过 DTS 提供（`scripts/build-dts.sh` 编译成 dtb 放进 boot 分区）。

## 结构

```
mainline-6.18/
  rk3588-aiot3588a.dts   唯一主设备树（板级差异全在这里）
```

- 编译：`KERNEL_DIR=$PWD/work/linux-6.18.18 ./scripts/build-dts.sh`（cpp + dtc，输出 `work/images/dtb/rockchip/rk3588-aiot3588a.dtb`）。
- 生效：`scripts/pack-image.sh` 把 dtb 放进 boot 分区 `dtb/rockchip/`，`extlinux.conf` 用 `fdt /dtb/rockchip/rk3588-aiot3588a.dtb` 加载。
- 历史上还有 `rk3588-aiot3588a-host.dts`、`-usbdev.dts`（用切换 dtb 的方式固定 Type-C 角色），已在 2026-11-10 修好 tcpm 原生切换后归档到 `archive/dts/`。

## 关键修复（改前先读，避免踩重复坑）

- **Type-C 角色**：`usbc0_con: connector` 的 `port@2` 必须指向 dwc3 的 role-switch 端点（`&usb_host0_xhci_drd_sw`），否则 tcpm 拿不到 `role_sw`；`&usbdp_phy1` **不能**绑 `phy-supply = <&vbus5v0_typec>`（否则 VBUS 常开，U 盘卡 `SRC_ATTACH_WAIT`）。详见 `docs/CONFIG.md`。
- **RK806 复位**：`pmic@0` 上的 `rockchip,reset-mode = <1>`（RK806_RESET）必须保留——上游 U-Boot 会先写 2（RESET_NOTIFY，重启挂死），内核用该属性改回 1。
- **eDP**：`&edp`/`&edp_phy` 的配置与 `kernel-modules/analogix-dp-6.18.18/` 的补丁模块配套。

## 约定

- 只改这一个 dts；不要加变体文件（固定角色等需求已由 tcpm 原生解决）。
- 改完先在板端 `/proc/device-tree/` 核对属性（大端显示），再重打镜像全量验证。
