# config.env —— 构建与首启配置

仓库根目录的 **`config.env`** 是整套镜像的配置入口：构建脚本、GitHub Actions、镜像里的开机脚本
都读它。它**不入库**（内含 WiFi/root 密码），模板是 `config.env.example`：

```bash
cp config.env.example config.env   # 填自己的 WiFi 与 root 密码（可留空）
```

改完重新打包镜像即生效，不需要改任何 `.sh`。

## 变量一览

| 变量 | 默认 | 作用 |
|---|---|---|
| `WIFI_SSID` | 空 | 首启自动连接的 WiFi 名称 |
| `WIFI_PASSWORD` | 空 | 对应密码（WPA/WPA2-PSK） |
| `WIFI_FALLBACK_SSID` | 空 | 主 SSID 连不上时的备用 |
| `WIFI_FALLBACK_PASSWORD` | 空 | 备用密码 |
| `WIFI_HIDDEN` | `0` | 隐藏 SSID 时改 `1` |
| `WIFI_COUNTRY` | `US` | 射频国家码。默认 **US**：本板 BCM43455 固件在 world/CN 域下不扫描 5GHz DFS 信道（ch52-64），国内 5G 常用 5250-5350 DFS，表现为「5G 搜不到/连不上」；开机由 `zt1-wifi-regdom.service` 在 NetworkManager 前设置。需要严格 CN 域可改回 CN（DFS 信道 5G 将不可用） |
| `ENABLE_WIFI` | `1` | `0` = 不启用首启 WiFi 脚本 |
| `ENABLE_SSH` | `1` | `1` = 开机自启 sshd 且允许 root 密码登录 |
| `ROOT_PASSWORD` | 空 | root 密码（SSH + 串口 console 登录用）；**留空 = 默认 `root`**（与 fnOS 官方镜像一致） |
| `DEVICE_HOSTNAME` | 空 | 空 = 出厂态 `fnnas`（由 Web 向导设置）；填了则固定 |
| `SKIP_XFCE` | `0` | `1` = 跳过 XFCE 桌面（纯 NAS） |
| `ENABLE_ADB` | `1` | `1` = 打开 USB adb（USB3 SuperSpeed） |
| `DEBUG_ETH_IP` | 空 | 有线调试静态 IP（如 `192.168.1.100/24`），空 = 不配置 |
| `DEBUG_ETH_IFACE` | `eth0` | 上面的网卡名 |

## 三个消费点

1. **构建期（主机）**：`scripts/lib-common.sh` 的 `load_config_env()` 在每次构建时 source
   `config.env`，所有 `scripts/*.sh`、`patches/rootfs/*.sh` 都能直接读变量。
   *外部环境变量优先* —— 命令行或 CI 传同名变量会覆盖文件值。
2. **镜像内**：`patches/rootfs/43-config-env.sh` 把配置写进 `/etc/zerot1/config.env`（root 600），
   并安装 `zt1-wifi-connect.service`。
3. **首启（设备上）**：`/usr/local/sbin/zt1-wifi-connect.sh` 读 `/etc/zerot1/config.env`，
   等 NetworkManager + `wlan0` 就绪后用 `nmcli` 连接（主 SSID 3 次重试 → 备用 SSID），
   成功后设为自动连接并确保 ssh 已启动。

## GitHub Actions 中的密码

工作流不会读仓库里的 `config.env`（它不入库），而是在构建前用
**Repository Secrets** 生成临时文件，变量名与上表同名：

| Secret | 说明 |
|---|---|
| `WIFI_SSID` / `WIFI_PASSWORD` | 首启自动连接的 WiFi |
| `WIFI_FALLBACK_SSID` / `WIFI_FALLBACK_PASSWORD` | 备用 WiFi（可只填一个） |
| `ROOT_PASSWORD` | root 密码（留空 = `root`） |

Secret 留空时对应项保持 `config.env.example` 里的空值（镜像仍可用，只是不会自动连 WiFi、
root 密码回落到默认 `root`）。**不要**把真实密码写进 `config.env.example` 或任何仓库文件。

## Type-C 角色切换（tcpm 原生，自动 + defer 修复模块）

本板 Type-C（唯一 OTG 口）角色由内核 tcpm（`fcs,fusb302` + `usb-role-switch`）**原生自动切换**，
无需任何用户态命令：

- 插 U 盘/键鼠 → tcpm 自动切 **host**（USB2 480Mbps）并自动挂载到 `/vol00/USB*`
- 插 PC → tcpm 自动切 **device**，`adbd` 绑定 UDC，adb 可用
- 拔掉 → 回到无连接状态，等待下次插入

DTS 两处关键修复（见 `dts/mainline-6.18/rk3588-aiot3588a.dts` 注释）：

1. `usb-role-switch` 端点挂在 `usbc0_con: connector` 的 `port@2`（原先挂在 `usb-typec@22` 节点下，
   tcpm 从 connector 的 fwnode 遍历不到，`port->role_sw` 为 NULL，内核永不切角色）；
2. 删除 `&usbdp_phy1` 误绑的 `phy-supply = <&vbus5v0_typec>`（否则 PHY 上电即打开 Type-C VBUS，
   fusb302 报 VBUSOK=1 → tcpm 认为 `vbus_vsafe0v=false` → U 盘场景永远卡在 `SRC_ATTACH_WAIT`）。

**第三个修复：tcpm defer 外挂模块**（`kernel-modules/tcpm-defer-fix/`，2026-11-10）

主线 tcpm 在 `tcpm_register_port()` 里用 `IS_ERR_OR_NULL()` 把 `fwnode_usb_role_switch_get()`
返回的 `-EPROBE_DEFER` 也吞掉了：dwc3 的 usb_role_switch 比 fusb302 晚注册时，probe 仍"成功"但
`port->role_sw == NULL`，之后只在 sysfs 更新 data_role 显示、从不切 dwc3，**同一镜像不同重启
结果随机**（有时 host 正常、有时永远 device）。补丁把 defer 透传出去让驱动核心重试。

⚠️ 部署位置很关键：fnOS 官方 `uInitrd` 的 **initramfs 里打包了原厂 tcpm.ko**，开机 ~2.3s 的
initramfs 阶段就抢先加载，rootfs 里 `updates/zt1/tcpm.ko` 永远不会生效（这是最初"修复不生效"
的真正原因）——与 eDP analogix_dp 同一个坑。因此：

- 镜像：`scripts/prepare-boot.sh` 用 `uinitrd-tool.py repack --replace` 把修复版 tcpm.ko 换进
  uInitrd；`patches/rootfs/58-kernel-sync.sh` 同时覆盖 rootfs 的 kernel 路径；
- 板端换内核：`zt1-kernel-sync` 重编 tcpm.ko 后覆盖 `$KDIR/kernel/drivers/usb/typec/tcpm/tcpm.ko`
  （并保留 `updates/zerot1/` 副本），kernel-sync marker 新增第三位校验该模块 md5。

> 旧方案（`zt1-usb-role` 覆盖 dtb 切角色、`zt1-otg-autoswitch` 用户态守护）已归档到
> `archive/rootfs/`，不再安装。
