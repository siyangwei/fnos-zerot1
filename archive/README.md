# archive/ —— 淘汰备案（仅供追溯，不参与构建）

这里存放已被主线方案替代、或已停用的历史文件。**构建流程不引用本目录**，
保留原因：便于回溯当时的做法与排查旧镜像问题。

## dts/ —— Type-C 角色切换用的变体设备树（已淘汰）

| 文件 | 原用途 | 淘汰原因 |
| --- | --- | --- |
| `rk3588-aiot3588a-host.dts` | Type-C 固定 host（`dr_mode="host"` + 禁用 `usbc0`） | 2026-11-10 修好 tcpm 原生角色切换后不再需要 |
| `rk3588-aiot3588a-usbdev.dts` | Type-C 固定 device（`dr_mode="peripheral"` + 禁用 `usbc0`） | 同上 |

旧方案：打包时把两种变体 dtb 一起放进 boot 分区，用 `zt1-usb-role` 覆盖
u-boot 固定加载的 `rk3588-aiot3588a.dtb` 文件名并重启来切角色。

现行方案：单份 `dts/mainline-6.18/rk3588-aiot3588a.dts`，tcpm + fusb302 +
usb-role-switch 原生自动切换（关键两处：`usbc0_con` connector 的 `port@2`
挂 role_sw 端点；删除 `&usbdp_phy1` 误绑的 `phy-supply = <&vbus5v0_typec>`，
否则 VBUS 常开导致 U 盘场景卡在 SRC_ATTACH_WAIT）。

## uboot/ —— 厂商/vendor u-boot 的直启动补丁（已淘汰）

`0001-zt1-uboot-cpll-ext4-directboot.patch`：改 `arch/arm/mach-rockchip/board.c`
的 `board_late_init` 写死 bootargs/bootcmd（ext4/直启动）+ CPLL 1500MHz。

淘汰原因：已切换到上游 U-Boot v2026.10 + bootstd/extlinux，bootargs 由
`/boot/extlinux/extlinux.conf` 提供，不再需要改 vendor u-boot 源码。
现行构建见 `scripts/build-uboot-upstream.sh`。

## rootfs/ —— 停用的 rootfs 补丁

| 文件 | 原用途 | 淘汰原因 |
| --- | --- | --- |
| `53-rk806-rstfix.sh.disabled` | 装 `rk806_rstfix.ko`（开机写 RK806 SYS_CFG3 RST_FUN=1） | 已改用板级 DTB `rockchip,reset-mode = <1>`（内核 rk8xx-core.c 原生支持） |
| `59-otg-autoswitch.sh.disabled` | 用户态 Type-C 角色守护（读 fusb302 STATUS0 写 dwc3 debugfs） | tcpm 原生切换修复后退役；其时间基准 bug 与 PC/U 盘误判见工作记录 §55 |
| `55-usb-role.sh` | `zt1-usb-role` 命令（dtb 覆盖切角色）+ adb gadget 自愈 | 角色切换部分淘汰；adb gadget 自愈部分保留为 `patches/rootfs/55-adb-watch.sh` |

## kernel-modules/ —— 停用的内核模块源码

| 目录 | 原用途 | 淘汰原因 |
| --- | --- | --- |
| `rk806-rstfix/` | 写 RK806 RST_FUN 的 out-of-tree 模块 | 同 `53-rk806-rstfix.sh.disabled`，已由 DTB 接管 |

## 其他被删除的备案

- `patches/kernel/6.1.141/files`：旧 vendor 内核（6.1.141）时代的空补丁目录，删除。
