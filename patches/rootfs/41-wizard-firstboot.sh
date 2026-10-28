#!/usr/bin/env bash
# 41-wizard-firstboot.sh —— 恢复"出厂未初始化"状态，保证 Web 向导能注册管理员
#
# 背景（2026-10-29 实机 binutils 反汇编 sysinfo_service 定位）：
#   fnOS 前端首屏先调 appcgi.sysinfo.getHostName，tsysinfo::BaseHandler::OnGetHostName
#   会把全局标志 systemInited = !CheckRegisteredUsers() 缓存下来；
#   CheckRegisteredUsers() = "是否存在主组为 Users(gid 1001) 的用户"。
#   随后向导依次调 user.add1000({setAdmin:true}) → sysinfo.initHostName() → user.login()。
#   因此镜像里只要预置了任何 uid>=1000 的普通用户（本项目旧版预建了 zero/uid1000），
#   就会出现：add1000 因 uid 1000 被占 → exit 4（前端 toast「参数错误」）；
#   getHostName 判定 hasUsers=true → OnInitHostName 直接返回「Host name had been inited!!」
#   （前端 toast「系统内部错误」）→ 向导永远进不去。
#
# 本补丁把镜像还原成官方出厂语义：无普通用户、主机名 fnnas、无初始化时间戳。
# 管理员由 Web 向导注册时动态创建（uid 1000，主组 Users，附加组 Administrators）。
#
# 用法: 41-wizard-firstboot.sh <rootfs-dir>
set -euo pipefail
ROOTFS="${1:?usage: $0 <rootfs-dir>}"

echo "  [41-wizard] 清理预置用户 / 还原出厂主机名"

# 1) 删除预置普通用户（passwd/shadow/group 成员/家目录/邮件池一起清）
for u in zero weisiyang anna abc; do
    # 无论 /etc/passwd 里是否还有该用户，都把各处残留清一遍（幂等）
    sed -i "/^${u}:/d" "$ROOTFS/etc/passwd" "$ROOTFS/etc/shadow" "$ROOTFS/etc/gshadow" 2>/dev/null || true
    # 组文件里去掉该成员（形如 "sudo:x:27:zero,weisiyang"）
    if [ -f "$ROOTFS/etc/group" ]; then
        awk -F: -v u="$u" 'BEGIN{OFS=":"} {
            n=split($4, a, ",");
            out="";
            for (i=1;i<=n;i++) if (a[i] != "" && a[i] != u) out = out (out==""?"":",") a[i];
            $4=out; print
        }' "$ROOTFS/etc/group" > "$ROOTFS/etc/group.tmp" && mv "$ROOTFS/etc/group.tmp" "$ROOTFS/etc/group"
    fi
    # 同名私有组（形如 "zero:x:1002:"）
    sed -i "/^${u}:/d" "$ROOTFS/etc/group" "$ROOTFS/etc/group-" 2>/dev/null || true
    # 备份文件（passwd- / shadow- …）也要清，避免 useradd -u1000 与人工排查被误导
    for f in passwd- shadow- group- gshadow- subuid subgid; do
        [ -f "$ROOTFS/etc/$f" ] && sed -i "/^${u}:/d" "$ROOTFS/etc/$f" 2>/dev/null || true
    done
    rm -rf "$ROOTFS/home/$u" "$ROOTFS/var/mail/$u" "$ROOTFS/var/spool/mail/$u"
done

# 2) 恢复官方出厂主机名语义（官方底稿 /etc/hostname=fnnas，/etc/hosts 127.0.1.1 fnnas）
printf 'fnnas\n' > "$ROOTFS/etc/hostname"
if [ -f "$ROOTFS/etc/hosts" ]; then
    if grep -q '^127\.0\.1\.1' "$ROOTFS/etc/hosts"; then
        sed -i 's/^127\.0\.1\.1.*/127.0.1.1\tfnnas/' "$ROOTFS/etc/hosts"
    else
        printf '127.0.1.1\tfnnas\n' >> "$ROOTFS/etc/hosts"
    fi
fi

# 3) 清掉"已初始化"痕迹，保证首屏走初始化向导
rm -f "$ROOTFS/usr/trim/etc/system_inited_timestamp" \
      "$ROOTFS/usr/trim/etc/trim_sysinfo.json" 2>/dev/null || true

# 4) 遗留的免密 sudo 配置（zero 专用）一并清理
rm -f "$ROOTFS/etc/sudoers.d/90-zero-nopasswd" 2>/dev/null || true

# 5) 校验：镜像里不应再有 uid>=1000 的普通用户
leftover="$(awk -F: '$3>=1000 && $3<60000 {print $1":"$3}' "$ROOTFS/etc/passwd" 2>/dev/null || true)"
if [ -n "$leftover" ]; then
    echo "  [41-wizard] WARN: 仍有普通用户: $leftover" >&2
else
    echo "  [41-wizard] OK: 无预置普通用户（管理员由 Web 向导创建）"
fi
