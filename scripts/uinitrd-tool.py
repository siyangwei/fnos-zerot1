#!/usr/bin/env python3
"""uinitrd-tool.py —— 读写 U-Boot legacy uImage 格式的 uInitrd（无外部依赖）

本项目的 fnOS 内核包（ophub kernel_fnnas）里的 uInitrd 是
「64 字节 legacy uImage 头 + zstd 压缩的 cpio(newc) initramfs」，
头部 comp=0（不做二次压缩，由内核 initramfs 解压器识别 zstd）。

用途：把仓库里自编译的 analogix_dp.ko 换进 uInitrd —— eDP 在启动早期就由
initramfs 里的模块驱动，只改 rootfs 里的同名模块不会生效（见 docs/EDP.md）。

子命令：
  info  <uInitrd>                              打印头部字段
  list  <uInitrd> [pattern]                    列出 initramfs 内容（cpio -t）
  repack <src> <out> [--replace 路径=本地文件]...  解包→替换→重新压缩打包

依赖：python3（标准库 zlib）、zstd 命令（压缩用）、cpio（仅 list 用）。
"""
import argparse
import os
import struct
import subprocess
import sys
import tempfile
import zlib

HDR = struct.Struct(">IIIIIIIBBBB32s")
MAGIC = 0x27051956
IH_OS_LINUX = 5
IH_ARCH_ARM64 = 22
IH_TYPE_RAMDISK = 3


def read_header(path):
    with open(path, "rb") as f:
        raw = f.read(64)
    if len(raw) != 64:
        raise SystemExit(f"{path}: 文件太短，不是 uImage")
    fields = HDR.unpack(raw)
    magic = fields[0]
    if magic != MAGIC:
        raise SystemExit(f"{path}: magic=0x{magic:08x}，不是 legacy uImage")
    return raw, fields


def write_image(path, orig_raw, orig_fields, payload):
    """orig_fields: (magic,hcrc,ts,size,load,ep,dcrc,os,arch,type,comp,name)"""
    _, _, ts, _size, load, ep, _dcrc, os_, arch, typ, comp, name = orig_fields
    hdr = bytearray(orig_raw)
    # size / dcrc
    struct.pack_into(">I", hdr, 12, len(payload))
    struct.pack_into(">I", hdr, 24, zlib.crc32(payload) & 0xFFFFFFFF)
    # 头部 CRC：hcrc 字段先清零再算
    struct.pack_into(">I", hdr, 4, 0)
    struct.pack_into(">I", hdr, 4, zlib.crc32(bytes(hdr)) & 0xFFFFFFFF)
    with open(path, "wb") as f:
        f.write(bytes(hdr))
        f.write(payload)


def decompress(payload):
    if payload[:4] == b"\x28\xb5\x2f\xfd":
        return subprocess.run(["zstd", "-d", "-c"], input=payload,
                              check=True, stdout=subprocess.PIPE).stdout
    raise SystemExit("暂不支持的压缩格式（只支持 zstd，magic 28 b5 2f fd）")


def compress(data, level=19):
    return subprocess.run(["zstd", "-%d" % level, "-c", "-q"],
                          input=data, check=True, stdout=subprocess.PIPE).stdout


def cpio_extract(cpio_blob, dest):
    """解包到 dest。initramfs 里有设备节点，非 root 会因 mknod 失败，故需 root。"""
    os.makedirs(dest, exist_ok=True)
    subprocess.run(["cpio", "-idmu", "--no-absolute-filenames", "--quiet"],
                   input=cpio_blob, cwd=dest, check=True)
    return dest


def cpio_pack(srcdir):
    listing = subprocess.run(["find", ".", "-mindepth", "1"],
                             cwd=srcdir, check=True,
                             stdout=subprocess.PIPE).stdout
    with open(os.path.join(srcdir, ".cpio-list"), "wb") as f:
        f.write(listing)
    return subprocess.run(["cpio", "-o", "-H", "newc", "--quiet",
                           "--owner=0:0", "--reproducible"],
                          cwd=srcdir, check=True,
                          stdin=open(os.path.join(srcdir, ".cpio-list"), "rb"),
                          stdout=subprocess.PIPE).stdout


def cmd_info(args):
    raw, f = read_header(args.image)
    magic, hcrc, ts, size, load, ep, dcrc, os_, arch, typ, comp, name = f
    print(f"文件      : {args.image} ({os.path.getsize(args.image)} B)")
    print(f"magic     : 0x{magic:08x}")
    print(f"hcrc      : 0x{hcrc:08x}")
    print(f"timestamp : {ts}")
    print(f"size      : {size} B")
    print(f"load/ep   : 0x{load:08x} / 0x{ep:08x}")
    print(f"dcrc      : 0x{dcrc:08x}")
    print(f"os/arch   : {os_} / {arch}")
    print(f"type/comp : {typ} / {comp}  (0=none)")
    print(f"name      : {name.rstrip(bytes([0])).decode(errors='replace')}")


def cmd_list(args):
    raw, f = read_header(args.image)
    payload = open(args.image, "rb").read()[64:]
    blob = decompress(payload)
    res = subprocess.run(["cpio", "-it", "--quiet"], input=blob,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    names = res.stdout.decode(errors="replace").split()
    pat = args.pattern or ""
    for n in sorted(names):
        if pat in n:
            print(n)


def cmd_repack(args):
    raw, f = read_header(args.src)
    payload = open(args.src, "rb").read()[64:]
    blob = decompress(payload)
    with tempfile.TemporaryDirectory() as td:
        cpio_extract(blob, td)
        for spec in args.replace or []:
            inner, local = spec.split("=", 1)
            dst = os.path.join(td, inner.lstrip("/"))
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            print(f"  替换 {inner} <- {local}")
            subprocess.run(["cp", "-f", local, dst], check=True)
            os.chmod(dst, 0o644)
        newblob = cpio_pack(td)
    newpayload = compress(newblob, level=args.level)
    write_image(args.out, raw, f, newpayload)
    print(f"写出 {args.out}: payload {len(payload)} -> {len(newpayload)} B "
          f"(cpio {len(newblob)} B)")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("info")
    p.add_argument("image")
    p.set_defaults(func=cmd_info)

    p = sub.add_parser("list")
    p.add_argument("image")
    p.add_argument("pattern", nargs="?")
    p.set_defaults(func=cmd_list)

    p = sub.add_parser("repack")
    p.add_argument("src")
    p.add_argument("out")
    p.add_argument("--replace", action="append", metavar="INNER=LOCAL")
    p.add_argument("--level", type=int, default=19)
    p.set_defaults(func=cmd_repack)

    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
