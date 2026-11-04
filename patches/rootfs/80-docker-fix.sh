#!/usr/bin/env bash
# 80-docker-fix.sh —— 修复飞牛自带 docker.service 的 ExecStop bug + 配置国内镜像源
#
# 问题 1（docker 服务 failed）：
#   飞牛自带 /etc/systemd/system/docker.service 里
#       ExecStop=/bin/sh -c "docker stop --time 3 $(docker ps -a -q)"
#   当没有任何容器时，$(docker ps -a -q) 展开为空，变成 `docker stop --time 3`，
#   docker 报 "requires at least 1 argument" 退出码 1 ⇒ systemd 判定服务 failed。
#   修法：改用 `docker ps -a -q | xargs -r docker stop --time 3`（-r 空输入不执行）。
#
# 问题 2（拉不到镜像）：默认 Docker Hub 在国内不可达，需要 registry-mirrors。
#   这里写入 /etc/docker/daemon.json（多个镜像源按顺序尝试）。
#
# 用法: 80-docker-fix.sh <rootfs-dir>
set -euo pipefail

ROOTFS="${1:?usage: $0 <rootfs-dir>}"

UNIT="$ROOTFS/etc/systemd/system/docker.service"
if [ -f "$UNIT" ]; then
    if grep -q 'docker stop --time 3 \$(docker ps -a -q)' "$UNIT"; then
        sed -i 's#ExecStop=/bin/sh -c "docker stop --time 3 \$(docker ps -a -q)"#ExecStop=/bin/sh -c "docker ps -a -q | xargs -r docker stop --time 3"#' "$UNIT"
        echo "[80-docker] 已修复 docker.service ExecStop"
    else
        echo "[80-docker] docker.service 的 ExecStop 不需修改（可能已是修复版）"
    fi
else
    echo "[80-docker] WARN: 未找到 $UNIT（跳过 ExecStop 修复）"
fi

# 国内镜像源（2026 年可用的几个公共 mirror，可在部署后按需增删）
mkdir -p "$ROOTFS/etc/docker"
cat > "$ROOTFS/etc/docker/daemon.json" <<'EOF'
{
  "registry-mirrors": [
    "https://docker.m.daocloud.io",
    "https://dockerproxy.net",
    "https://docker.1ms.run",
    "https://docker.xuanyuan.me"
  ]
}
EOF

echo "[80-docker] 完成: ExecStop 修复 + 4 个国内 mirror"

# 问题 3（docker.socket failed）：
#   fnOS 镜像同时 enable docker.service 和 docker.socket；docker.service 先起来时
#   守护进程自己创建 /run/docker.sock，socket 单元再 bind 会 EADDRINUSE 被 systemd
#   标记 failed（首次开机 docker 因存储空间未建还会反复失败，被 start-limit 限流）。
#   修法：去掉 sockets.target.wants 里的 docker.socket 软链，只保留 docker.service。
for d in "$ROOTFS/etc/systemd/system/sockets.target.wants" "$ROOTFS/usr/lib/systemd/system/sockets.target.wants" "$ROOTFS/lib/systemd/system/sockets.target.wants"; do
    [ -L "$d/docker.socket" ] && rm -f "$d/docker.socket" && echo "[80-docker-fix] 已移除 docker.socket 的 enable 软链"
done
