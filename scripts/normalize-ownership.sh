#!/usr/bin/env bash
# normalize-ownership.sh —— 把 rootfs 的 uid/gid 校正回官方底稿（official-base.img）的值
#
# 背景（2026-10-30）：rootfs-official 里有 31,346 个文件属主被改成了 uid 1000（构建机用户 zero），
# 后果很隐蔽：
#   * /var/lib/postgresql/15/main 变成 1000:1000 700 → postgres(105) 无法读数据目录 → 集群起不来
#     → fnOS web 向导「注册管理员」报 errno 4208 数据库读写错误（前端只显示"参数错误"）
#   * /etc/ssh/sshd_config 变成非 root 所有 → sshd 拒绝启动（Bad owner or permissions）
#   * /etc/passwd、/etc/shadow 等同样被改属主
# 所以打包 rootfs.img 之前必须跑一遍本脚本，保证镜像里的属主与官方底稿一致。
#
# 规则：
#   1) 基础镜像里存在的路径 → 强制用基础镜像的 uid:gid
#   2) 基础镜像里没有、但属主/属组是 1000 的（我们补丁新建的文件）→ root:root
#   3) 其它新文件保持原样（例如 /home/<用户> 由系统运行时创建）
#
# 用法：sudo ./scripts/normalize-ownership.sh [rootfs目录]
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib-common.sh"

ROOTFS="${1:-${ROOTFS:-$WORK_DIR/rootfs}}"
# 参照镜像：优先 BASE_IMG；否则用 build-rootfs.sh 下载的 fnOS 底稿镜像
BASE_IMG="${BASE_IMG:-${FNOS_IMG:-$WORK_DIR/official-base.img}}"
BASE_MNT="${BASE_MNT:-$WORK_DIR/mnt-base-root}"

need_root

[ -d "$ROOTFS" ] || { log "ERROR: rootfs 不存在: $ROOTFS"; exit 1; }
[ -f "$BASE_IMG" ] || { log "WARN: 找不到基础镜像 $BASE_IMG，跳过属主归一"; exit 0; }

# 挂基础镜像（只读，loop 自动分区映射）
CLEANUP_LOOP=""
cleanup() {
    mountpoint -q "$BASE_MNT" && umount "$BASE_MNT" 2>/dev/null || true
    [ -n "$CLEANUP_LOOP" ] && losetup -d "$CLEANUP_LOOP" 2>/dev/null || true
}
trap cleanup EXIT

if ! mountpoint -q "$BASE_MNT"; then
    mkdir -p "$BASE_MNT"
    CLEANUP_LOOP="$(losetup -Pf --show "$BASE_IMG")"
    PART="$(lsblk -lnpo NAME,TYPE "$CLEANUP_LOOP" | awk '$2=="part" && $1 ~ /p2$/ {print $1; exit}')"
    [ -n "$PART" ] || PART="$(lsblk -lnpo NAME,TYPE "$CLEANUP_LOOP" | awk '$2=="part" {print $1; exit}')"
    [ -n "$PART" ] || { log "ERROR: 基础镜像没有分区"; exit 1; }
    mount -o ro "$PART" "$BASE_MNT"
    log "基础镜像已挂载: $PART -> $BASE_MNT"
fi

python3 - "$BASE_MNT" "$ROOTFS" <<'PY'
import os, sys, collections

base, root = sys.argv[1], sys.argv[2]

mapping = {}
for dirpath, dirnames, filenames in os.walk(base):
    rel = os.path.relpath(dirpath, base)
    rel = "" if rel == "." else rel
    for name in dirnames + filenames:
        p = os.path.join(rel, name) if rel else name
        try:
            st = os.lstat(os.path.join(base, p))
        except FileNotFoundError:
            continue
        mapping[p] = (st.st_uid, st.st_gid)

fixed = failed = 0
restored = collections.Counter()
for dirpath, dirnames, filenames in os.walk(root):
    rel = os.path.relpath(dirpath, root)
    rel = "" if rel == "." else rel
    for name in dirnames + filenames:
        p = os.path.join(rel, name) if rel else name
        full = os.path.join(root, p)
        try:
            st = os.lstat(full)
        except FileNotFoundError:
            continue
        want = mapping.get(p)
        if want is None:
            if st.st_uid == 1000 or st.st_gid == 1000:
                try:
                    os.lchown(full, 0, 0); fixed += 1; restored["0:0"] += 1
                except OSError:
                    failed += 1
            continue
        if (st.st_uid, st.st_gid) != want:
            try:
                os.lchown(full, *want); fixed += 1
                restored[f"{want[0]}:{want[1]}"] += 1
            except OSError:
                failed += 1

print(f"[normalize-ownership] 修正 {fixed} 项, 失败 {failed} 项")
for k, v in restored.most_common(5):
    print(f"  -> {k}: {v}")
if failed:
    sys.exit(1)
PY

log "属主归一完成: $ROOTFS"
