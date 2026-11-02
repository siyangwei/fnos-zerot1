#!/usr/bin/env python3
"""检查 ophub/fnnas 上游是否有更新的底稿镜像 / 内核包。

脚本里的 FNOS_IMG_URL（scripts/lib-common.sh）与内核包 URL（scripts/prepare-boot.sh）
都指向固定版本；上游更新时用本脚本对比，再决定是否升级版本号。

用法:
    ./scripts/check-upstream.py           # 人类可读
    ./scripts/check-upstream.py --json    # 机器可读（CI 用）
"""

import argparse
import json
import re
import sys
import urllib.request

REPO = "ophub/fnnas"
API = f"https://api.github.com/repos/{REPO}/releases"

# 与 build-image.sh 的默认值保持一致
CURRENT_BOARD = "nanopc-t6"
CURRENT_TAG = "fnnas_rockchip_1253"
CURRENT_KERNEL = "6.18.18"
CURRENT_DATE = "2026.09.23"

IMG_RE = re.compile(
    r"fnnas_rockchip_(?P<board>.+?)_k(?P<kernel>[\d.]+)_(?P<date>\d{4}\.\d{2}\.\d{2})\.img\.gz"
)


def fetch(url: str):
    req = urllib.request.Request(url, headers={"User-Agent": "fnos-zerot1-check"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", action="store_true", help="输出 JSON")
    args = ap.parse_args()

    try:
        releases = fetch(f"{API}?per_page=30")
    except Exception as e:  # noqa: BLE001
        print(f"查询 GitHub API 失败: {e}", file=sys.stderr)
        return 2

    # 收集所有 rk3588 镜像，按日期倒序
    found = []
    for rel in releases:
        for asset in rel.get("assets", []):
            m = IMG_RE.match(asset.get("name", ""))
            if not m:
                continue
            found.append(
                {
                    "tag": rel["tag_name"],
                    "board": m.group("board"),
                    "kernel": m.group("kernel"),
                    "date": m.group("date"),
                    "url": asset["browser_download_url"],
                    "size_mb": round(asset["size"] / 1024 / 1024, 1),
                    "published_at": rel.get("published_at"),
                }
            )

    found.sort(key=lambda x: (x["date"], x["published_at"] or ""), reverse=True)

    if args.json:
        print(json.dumps({"current": {
            "board": CURRENT_BOARD,
            "tag": CURRENT_TAG,
            "kernel": CURRENT_KERNEL,
        }, "images": found}, indent=2, ensure_ascii=False))
        return 0

    cur = f"{CURRENT_BOARD} k{CURRENT_KERNEL} ({CURRENT_TAG})"
    print(f"当前配置: {cur}\n")
    if not found:
        print("未在最近 30 个 release 里找到 rockchip 镜像（ophub 仓库结构可能变了）")
        return 1

    same = [i for i in found if i["board"] == CURRENT_BOARD]
    others = [i for i in found if i["board"] != CURRENT_BOARD]

    print(f"底稿板 {CURRENT_BOARD} 可用镜像（最新 3 个，共 {len(same)} 个）:")
    for img in same[:3]:
        mark = " <= 当前" if img["kernel"] == CURRENT_KERNEL and img["date"] == CURRENT_DATE else ""
        print(f"  {img['date']}  k{img['kernel']:<8} {img['size_mb']:>7.1f}MB  {img['tag']}{mark}")

    print(f"\n其他板子最新 5 个（共 {len(others)} 个）:")
    for img in others[:5]:
        print(f"  {img['date']}  {img['board']:<16} k{img['kernel']:<8} {img['size_mb']:>7.1f}MB  {img['tag']}")

    if not same:
        print(f"\n⚠  上游没有 {CURRENT_BOARD} 的镜像！请换一个同 SoC 底稿板（BASE_BOARD）")
        return 1

    latest = same[0]
    if latest["kernel"] != CURRENT_KERNEL or latest["date"] != CURRENT_DATE:
        print(
            f"\n⚠  底稿板 {CURRENT_BOARD} 最新镜像: k{latest['kernel']} / {latest['date']} / {latest['tag']}\n"
            f"   当前脚本: k{CURRENT_KERNEL} / {CURRENT_DATE} / {CURRENT_TAG}\n"
            f"   如需升级，改 build-image.sh 的环境变量:\n"
            f"   KERNEL_VER={latest['kernel']} BASE_DATE={latest['date']} "
            f"FNOS_RELEASE_TAG={latest['tag']}"
        )
        return 1

    print(f"\n✓ 底稿镜像与脚本配置一致: {CURRENT_BOARD} k{CURRENT_KERNEL} / {CURRENT_DATE}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
