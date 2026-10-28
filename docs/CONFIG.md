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

## 首启 WiFi 的射频国家码（5G 必需）

brcmfmac 固件默认用 "world" 法规域，**5G 只剩 2.4G + 5.8G 可用**，路由器的
5.15–5.35 GHz（信道 36–64）AP 根本扫不到。首启脚本会执行：

```bash
iw reg set "$WIFI_COUNTRY"     # 默认 CN
```

设置成功后 `iw dev wlan0 scan` 才能看到 5G AP（实测 5300 MHz 的 AP 出现，
连接后 390/263 Mbps）。因此镜像里必须带 `iw`（43-config-env 会自动 chroot 安装）。
若 `iw` 缺失或国家码设置失败，脚本会退回只用 2.4G 备用 SSID，不影响能上网。

> 说明：之前 5G 连接不上、2.4G 连接后又被踢掉，是因为 5G profile 反复 autoconnect
> 失败；现在连接成功后会把**当前** profile 的 autoconnect-priority 设为 20，并把其它
> WiFi profile 的 autoconnect 关掉，避免网卡在两个频段之间来回跳。

## HDMI 音频与日志

DT 里 `&hdmi1_sound = okay`（能用 HDMI 音频的代价：无显示器时 hdmi-codec prepare 返回
-19，PulseAudio 启动瞬间内核会打约 240 行 `ASoC error (-19)`）。

镜像里用 udev 折中（`44-hdmi-audio-logfix.sh`）：

- 无 HDMI 显示器 → 给 HDMI 声卡加 `PULSE_IGNORE=1`，PA 不探测 ⇒ 日志 0 条；
- 接显示器 → `PULSE_IGNORE=0`，PA 正常接管，HDMI 音频可用；
- HDMI 插拔时重新触发 sound add，属性与 PA 状态实时刷新。

手动强制让 PA 认 HDMI 卡（插着显示器但没识别时）：

```bash
sudo udevadm trigger --subsystem-match=sound --action=add
```
