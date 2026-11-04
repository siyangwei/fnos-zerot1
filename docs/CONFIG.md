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
| `USB_ROLE` | `auto` | Type-C 默认角色：`auto`（默认，device+自动判断插设备）、`device`（固定 peripheral）、`host`（固定主机） |

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

## 运行时切换（设备上）

```bash
zt1-usb-role status              # 当前角色（dtb 角色 + 运行时 mode）
zt1-usb-role auto                # 默认：dtb 用 auto/otg（device + adb，插设备由 autoswitch 自动切 host）
zt1-usb-role device --reboot     # 固定 device（adb 常开）
zt1-usb-role host --reboot       # 固定 host（adb 不可用，插 U 盘/键鼠）
zt1-usb-role host --now          # 本次开机立即切 host，不改 dtb（重启回原角色）
```

镜像默认带 `zt1-otg-autoswitch` 守护进程：`auto` 角色下每 0.5s 检查 fusb302 `STATUS0` 与 xhci 设备表，
插上 sink 设备（U 盘等）自动切 host，拔掉约 9s 自动回 device（恢复 adb）。手动 `--now` 切换后
10 分钟内 autoswitch 不干预。

> 注意：定制 u-boot 直接加载固定路径的 dtb，不读 `extlinux.conf`，所以角色切换是**覆盖该 dtb 文件**，
> 而不是像旧版那样改 `extlinux.conf` 的 `fdt` 行。
