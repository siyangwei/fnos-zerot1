# .github/ —— GitHub Actions 自动构建

`workflows/build.yml`：push 到 master（或手动 `workflow_dispatch`）时自动构建 `update.img`，
用 zstd 压缩后作为 artifact 上传；打 tag 时自动创建 Release 并附带镜像。

## 流程

1. 检出仓库，恢复 `assets/` 预编译产物（u-boot、模块 ko 已入库，不重新构建）。
2. 下载 fnOS 底稿镜像与官方内核包（缓存加速）。
3. 跑 `scripts/build-all.sh`（rootfs → boot → dts → pack）。
4. 产物 `output/fnos-aiot3588a-v1.1-update-<日期>.img` → `.img.zst` + `.zst.sha256` 上传。
5. tag（如 `v1.1.0`）→ 创建 GitHub Release，正文含构建信息与烧录命令。

## 约定

- CI 只构建，**不验证硬件**；烧录与板端验证（`zt1-check`、Type-C 双场景、eDP/WiFi/NPU 等）在本地做。
- 改构建流程时同步改 `scripts/build-all.sh` 与本文档；Secrets 通过仓库 Settings 注入，不写进仓库。
- 需要本地验证 CI 产物：下载 artifact → `zstd -d` → `sha256sum -c` → `upgrade_tool uf`。
