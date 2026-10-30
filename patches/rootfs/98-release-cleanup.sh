#!/usr/bin/env bash
# 98-release-cleanup.sh —— 发布镜像清理：删掉开发期临时诊断产物与个人残留
#
# 用户要求：交付的镜像必须是「功能完整、干净的系统」，不能有 /root/zt1-gfx.txt
# 这类开发残留。本补丁最后执行（98 号最大），把以下东西清掉：
#   - 95/96 号临时诊断补丁的产物：zerot1-gfx.{sh,service}、zerot1-diag.{sh,service}、
#     /etc/zerot1-diag.enable、/root/zt1-*.txt、/var/log/zt1-*.log（运行期日志）
#   - 系统/构建期垃圾：/tmp、/var/tmp、apt 缓存与 lists（保险起见再清一次）、
#     dpkg 旧信息、bash/yaml 历史、root 个人历史文件（.lesshst/.viminfo/.psql_history）
#   - 任何遗留的 /home/*（首启向导会自己建管理员家目录）
# 注意：功能脚本（zt1-wifi-connect / zt1-jack / zt1-adb-gadget / zt1-usb-role /
#       zt1-audio-* / zt1-ssh-guard / zt1-boot-diag 等）都保留，它们不是残留。
#
# 用法: 98-release-cleanup.sh <rootfs-dir>
set -euo pipefail
ROOTFS="${1:?usage: $0 <rootfs-dir>}"
source "$(dirname "$0")/../../scripts/lib-common.sh"

echo "[98-cleanup] 开始清理开发残留"

# 1) 临时诊断补丁 95/96 的产物
rm -f "$ROOTFS/usr/local/sbin/zerot1-gfx.sh" \
      "$ROOTFS/usr/local/sbin/zerot1-diag.sh" \
      "$ROOTFS/etc/systemd/system/zerot1-gfx.service" \
      "$ROOTFS/etc/systemd/system/zerot1-diag.service" \
      "$ROOTFS/etc/zerot1-diag.enable"
rm -f "$ROOTFS"/etc/systemd/system/*.wants/zerot1-gfx.service \
      "$ROOTFS"/etc/systemd/system/*.wants/zerot1-diag.service 2>/dev/null || true

# 2) 调试输出文件 / 运行期日志
rm -f "$ROOTFS"/root/zt1-*.txt
rm -f "$ROOTFS"/var/log/zt1-*.log

# 3) 个人/历史残留
rm -f "$ROOTFS"/root/.lesshst "$ROOTFS"/root/.viminfo "$ROOTFS"/root/.psql_history \
      "$ROOTFS"/root/.wget-hsts "$ROOTFS"/root/.bash_history \
      "$ROOTFS"/root/.python_history "$ROOTFS"/root/.node_repl_history
rm -rf "$ROOTFS"/root/.cache "$ROOTFS"/root/.config "$ROOTFS"/root/.local \
       "$ROOTFS"/root/.docker "$ROOTFS"/root/.gnupg "$ROOTFS"/root/.pki

# 4) 清空 /home（首启向导/manual 用户自建），保证出厂干净
find "$ROOTFS/home" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true

# 5) 构建/系统垃圾
rm -rf "$ROOTFS"/tmp/* "$ROOTFS"/var/tmp/* 
rm -rf "$ROOTFS"/var/cache/apt/archives/*.deb "$ROOTFS"/var/lib/apt/lists/* \
       "$ROOTFS"/var/cache/apt/pkgcache.bin "$ROOTFS"/var/cache/apt/srcpkgcache.bin
rm -rf "$ROOTFS"/var/log/*.gz "$ROOTFS"/var/log/*.1 "$ROOTFS"/var/log/apt/*
: > "$ROOTFS/var/log/lastlog" 2>/dev/null || true

log "[98-cleanup] 完成（保留功能脚本；/root、/home、/tmp、/var/log 已清）"
