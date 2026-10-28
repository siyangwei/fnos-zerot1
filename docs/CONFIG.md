# config.env —— 构建与首启配置

仓库根目录的 **`config.env`** 是整套镜像的唯一配置入口：构建脚本、GitHub Actions、
以及镜像里的开机脚本都读它。改完重新打包镜像即生效，不需要改任何 `.sh`。

```bash
# 只改配置重打包（rootfs 与内核都复用缓存，约 2~3 分钟）
sudo env SKIP_ROOTFS=1 SKIP_KERNEL=1 \
     FNOS_BOOT=$PWD/work/boot-fix-2214 \
     IMAGE_DIR=$PWD/work/images \
     ROOTFS=$PWD/work/rootfs-official \
     bash scripts/build-all.sh
```

## 变量一览

| 变量 | 默认 | 作用 |
|---|---|---|
| `WIFI_SSID` | `CMCC-jRxU-5G` | 首启自动连接的 WiFi 名称 |
| `WIFI_PASSWORD` | `34qs75h2` | 对应密码（WPA/WPA2-PSK） |
| `WIFI_FALLBACK_SSID` | `CMCC-jRxU` | 主 SSID 连不上时的备用 |
| `WIFI_FALLBACK_PASSWORD` | 同主密码 | 备用密码 |
| `WIFI_HIDDEN` | `0` | 隐藏 SSID 时改 `1` |
| `WIFI_COUNTRY` | `CN` | 射频国家码（失败不影响连接） |
| `ENABLE_WIFI` | `1` | `0` = 不启用首启 WiFi 脚本 |
| `ENABLE_SSH` | `1` | `1` = 开机自启 sshd 且允许 root 密码登录 |
| `ROOT_PASSWORD` | `weisiyang` | root 密码（SSH + 串口 console 登录用） |
| `DEVICE_HOSTNAME` | 空 | 空 = 出厂态 `fnnas`（由 Web 向导设置）；填了则固定 |
| `SKIP_XFCE` | `0` | `1` = 跳过 XFCE 桌面（纯 NAS） |

## 三个消费点

1. **构建期（主机）**：`scripts/lib-common.sh` 里的 `load_config_env()` 在每次构建时
   source `config.env`，所有 `scripts/*.sh`、`patches/rootfs/*.sh` 都能直接读变量。
   *外部环境变量优先* —— 命令行或 CI 传同名变量会覆盖文件值。
2. **镜像内**：`patches/rootfs/43-config-env.sh` 把 `config.env` 原样写进
   `/etc/zerot1/config.env`（root 600），并安装 `zt1-wifi-connect.service`。
3. **首启（设备上）**：`/usr/local/sbin/zt1-wifi-connect.sh` 读
   `/etc/zerot1/config.env`，等 NetworkManager + `wlan0` 就绪后用 `nmcli` 连接
   （主 SSID 3 次重试 → 备用 SSID），成功后设为自动连接并确保 `ssh` 已启动。
   日志：`/var/log/zt1-wifi-connect.log`；无网也不影响开机（幂等，退出码 0）。

SSH 就绪后：

```bash
ssh root@<设备 IP>        # 密码 = ROOT_PASSWORD
```

## 新增变量（后续扩展）

在 `config.env` 里加一行 `KEY=value`，然后按需消费：

- **构建期**：脚本里直接用 `$KEY`（lib-common 已加载）。
- **镜像内**：`43-config-env.sh` 会把整个文件写进镜像，运行期脚本
  `. /etc/zerot1/config.env` 后即可读；若要在构建期生成别的配置文件，在
  `43-config-env.sh` 里加一段 `cat > ...` 即可。
- **GitHub Actions**：workflow 里「读取 config.env」步骤已把所有 `KEY=value`
  导出到 `$GITHUB_ENV`，后续步骤可直接用 `env.KEY`/shell `$KEY`；
  敏感值建议放仓库 Secrets（`WIFI_SSID`、`WIFI_PASSWORD`、`ROOT_PASSWORD`），
  同名 Secrets 会覆盖 config.env。

## 安全提示

- `config.env` 里有 WiFi 和 root 密码，**仓库请保持 private**；公开镜像用
  Actions Secrets 注入即可（去掉 config.env 里的真实值）。
- 镜像内的 `/etc/zerot1/config.env` 权限 600 root:root，普通用户读不到。
