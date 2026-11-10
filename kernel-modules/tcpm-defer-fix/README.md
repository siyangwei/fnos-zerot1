# tcpm-defer-fix —— usb-role-switch 未就绪时把 -EPROBE_DEFER 透传出去

## 为什么需要这个补丁

RK3588 上 Type-C 角色切换链路是：

```
fusb302 (i2c6@0x22) --tcpm--> usb-role-switch --> dwc3 (fc000000.usb, dr_mode=otg)
```

`tcpm_register_port()` 里原厂逻辑（Linux 6.18.18 `drivers/usb/typec/tcpm/tcpm.c:7879`）：

```c
	port->role_sw = fwnode_usb_role_switch_get(tcpc->fwnode);
	if (IS_ERR_OR_NULL(port->role_sw))
		port->role_sw = usb_role_switch_get(port->dev);
```

`IS_ERR_OR_NULL()` 把 `-EPROBE_DEFER` 也当成「没有 role switch」吞掉了：当 fusb302/tcpm
的 i2c client 先于 dwc3 的 usb_role_switch 注册时，`fwnode_usb_role_switch_get()` 返回
`-EPROBE_DEFER`，fallback `usb_role_switch_get(port->dev)` 也返回 NULL，probe 仍"成功"，
但 `port->role_sw == NULL`。之后 tcpm 只更新 `/sys/class/typec/port0/data_role` 显示，
**从不调用 `usb_role_switch_set_role()` 切 dwc3**，表现为：

- 插 PC（sink 设备）：data_role 显示 `[host]` 但 dwc3 仍是 `device`，USB gadget 不枚举；
- 插 U 盘（source 设备）：data_role/power_role 显示 host/source 但不供电、U 盘不枚举；
- 是否复现取决于开机时 i2c 与 dwc3 的 probe 先后 —— **随机**。

补丁把该 defer 原样返回给驱动核心，让 probe 在 dwc3 就绪后自动重试：

```c
	if (IS_ERR(port->role_sw) && PTR_ERR(port->role_sw) == -EPROBE_DEFER) {
		pr_info("tcpm: %s: usb role switch not ready, deferring probe\n",
			dev_name(dev));
		err = -EPROBE_DEFER;
		goto out_destroy_wq;
	}
```

## 与 DTS 修复的关系

本补丁只解决「随机不生效」的时序问题，另外两处 DTS 修复是前提（见
`dts/mainline-6.18/rk3588-aiot3588a.dts`、commit `1f811ca`）：

1. **connector 下的 role_sw 端点**：tcpm 的 fwnode 是 `connector` 子节点
   （`fusb302_fwnode_get()`），role-switch 的 graph 端点必须挂在 `connector/ports/port@2`，
   而不是 `usb-typec@22` 节点下，否则 tcpm 根本找不到 role switch。
2. **删除 `&usbdp_phy1` 的 `phy-supply = <&vbus5v0_typec>`**：该误绑让 PHY 常开 Type-C
   VBUS 5V，fusb302 读到 VBUSOK=1，tcpm 认为 `vbus_vsafe0v=false`，`SRC_ATTACH_WAIT`
   永不转 `SRC_ATTACHED`，U 盘（sink）不供电。

## 部署注意：initramfs 里的旧 tcpm 会抢先生效

fnOS 官方内核包的 `uInitrd` 里 **initramfs 打包了原厂 tcpm.ko/fusb302.ko/typec.ko**。
开机时 initramfs 阶段（约 2.3s）就加载了旧版 tcpm，早于 rootfs 的 systemd，
导致 rootfs 里 `/lib/modules/*/updates/zt1/tcpm.ko` 永远不会被加载。

因此按本项目的既有做法（同 analogix_dp）：

- **镜像**：`scripts/prepare-boot.sh` 用 `scripts/uinitrd-tool.py repack` 把本目录编译出的
  `tcpm.ko` 直接替换进 `uInitrd` 内的 `usr/lib/modules/<ver>/kernel/drivers/usb/typec/tcpm/tcpm.ko`；
- **板端换内核**：`zt1-kernel-sync` 重编 tcpm.ko 后**覆盖 kernel 路径原文件**（而不只是
  `updates/zt1/`），再重建 uInitrd（`mkinitramfs` 生成的不含 typec 模块）。

## 编译

用目标内核的 headers（板端 `/lib/modules/$(uname -r)/build`，或解包的
`linux-headers-<ver>`）：

```sh
make -C /lib/modules/$(uname -r)/build M=$PWD modules
```

产物 `tcpm.ko` 的 `MODULE_VERSION` 为 `zt1-defer-fix`，加载后 `dmesg` 会打印
`tcpm: zt1 defer-fix build loaded`，可用 `/sys/module/tcpm/version` 确认当前运行的版本。

## 上游状态

- 主线 tcpm 至今仍用 `IS_ERR_OR_NULL()` 吞 defer（Linux 6.18.18 基线）；
- 本补丁等价于把 fallback 逻辑改为「defer 透传、其它错误再 fallback」，可作为上游
  提交候选；在本项目内先以独立外挂模块形式解耦维护。
