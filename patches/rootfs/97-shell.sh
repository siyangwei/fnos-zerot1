#!/usr/bin/env bash
# 97-shell.sh —— 把 /bin/sh 指向 bash，让 adb shell 也有 Tab 补全
#
# 背景：厂商 adbd 是硬编码 execve("/bin/sh")（strings /usr/bin/adbd 只有 "/bin/sh"，
# 不认 SHELL 环境变量），而 Debian 的 /bin/sh 是 dash —— dash 没有 Tab 补全，
# 所以 adb shell 里体验很差。Debian 官方支持把 /bin/sh 切到 bash
# （等价 `dpkg-reconfigure dash` 选 No），bash 以 sh 兼容模式运行，POSIX 脚本无碍。
#
# 实测（2026-10-31，板上验证）：切换后 adb shell 里 BASH_VERSION=5.2.15(1)-release，
# 命令/路径补全恢复；systemctl、/etc/init.d/* 脚本 `sh -n` 全通过、systemctl --failed 为空、
# 重启两次均正常。
#
# 用法: 97-shell.sh <rootfs-dir>
set -euo pipefail
ROOTFS="${1:?usage: $0 <rootfs-dir>}"
source "$(dirname "$0")/../../scripts/lib-common.sh"

# /bin 在 Debian 12 上是 -> usr/bin 的符号链接，写 "$ROOTFS/bin/sh" 会落到 usr/bin/sh
ln -sfn bash "$ROOTFS/bin/sh"
log "[97-shell] /bin/sh -> bash（$(readlink "$ROOTFS/bin/sh")）"
