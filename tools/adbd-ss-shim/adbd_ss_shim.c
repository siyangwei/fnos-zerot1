/*
 * adbd_ss_shim.c - 让老版 adbd（android-tools 4.2.2，只有 FunctionFS v1 描述符）
 * 也能在 USB SuperSpeed 下工作。
 *
 * 原理：adbd 启动时向 /dev/usb-ffs/adb 的 ep0 写一段 v1 格式描述符块
 *      (usb_functionfs_descs_head: magic=1, length, fs_count, hs_count + fs/hs 描述符)。
 *      FunctionFS 只有在收到 v2 格式描述符且 flags 含 FUNCTIONFS_HAS_SS_DESC 时
 *      才会生成 SS 配置（否则 composite 里 c->superspeed=0，主机枚举到
 *      bNumConfigurations=0 -> "no configurations, error -22"）。
 *
 *      本 shim 用 LD_PRELOAD 拦截 write()，识别这段 v1 描述符块，就地重写为 v2：
 *        v2 头(12B) + 原 FS 描述符 + 原 HS 描述符 + 新构造的 SS 描述符
 *      SS 描述符 = 接口描述符(复制 FS 的) + 每个端点一个 SS 端点描述符
 *                 (wMaxPacketSize=1024, bLength=7) + 对应的 SS 端点伴随描述符(6B)。
 *
 * 编译：gcc -shared -fPIC -O2 -o libadbd_ss_shim.so adbd_ss_shim.c -ldl
 * 使用：LD_PRELOAD=/usr/local/lib/libadbd_ss_shim.so /usr/bin/adbd
 *      （仅当 UDC 的 max_speed=super-speed 时才需要；high-speed 下 shim 不影响）
 */
#define _GNU_SOURCE
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <stdio.h>
#include <errno.h>

#define FFS_MAGIC_V1 1u
#define FFS_MAGIC_V2 3u
#define FFS_HAS_FS   1u
#define FFS_HAS_HS   2u
#define FFS_HAS_SS   4u

#define LOG_PATH "/tmp/adbd-ss-shim.log"

static ssize_t (*real_write)(int, const void *, size_t);

static void shim_log(const char *msg)
{
    int fd = open(LOG_PATH, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        write(fd, msg, strlen(msg));
        write(fd, "\n", 1);
        close(fd);
    }
}

/* 构造 v2 描述符块；成功返回 malloc 的缓冲区，*outlen 为长度 */
static unsigned char *build_v2(const unsigned char *buf, size_t len, size_t *outlen)
{
    const uint32_t *h = (const uint32_t *)buf;
    uint32_t fs_count = h[2], hs_count = h[3];
    const unsigned char *p = buf + 16;
    const unsigned char *end = buf + len;
    const unsigned char *fs_start = p, *fs_end;
    const unsigned char *hs_start, *hs_end;
    unsigned ss_len = 0, ss_count = 0;
    size_t total;
    unsigned char *out, *o;

    if (fs_count == 0 || fs_count > 32 || hs_count == 0 || hs_count > 32)
        return NULL;

    for (uint32_t i = 0; i < fs_count; i++) {
        if (p + 2 > end || p[0] < 2 || p + p[0] > end)
            return NULL;
        p += p[0];
    }
    fs_end = p;
    hs_start = p;
    for (uint32_t i = 0; i < hs_count; i++) {
        if (p + 2 > end || p[0] < 2 || p + p[0] > end)
            return NULL;
        p += p[0];
    }
    hs_end = p;

    /* 计算 SS 段长度：接口描述符 + 每个端点(SS 端点 7B + 伴随 6B) */
    for (const unsigned char *q = fs_start; q < fs_end; q += q[0]) {
        if (q[1] == 4) {         /* interface */
            ss_len += 9;
            ss_count += 1;
        } else if (q[1] == 5) {  /* endpoint + SS companion */
            ss_len += 7 + 6;
            ss_count += 2;
        }
    }
    if (ss_len == 0)
        return NULL;

    /* v2 头 = magic/length/flags + fs_count/hs_count/ss_count 三个 u32 */
    total = 24 + (size_t)(fs_end - fs_start) + (size_t)(hs_end - hs_start) + ss_len;
    if (total > 4096)
        return NULL;
    out = malloc(total);
    if (!out)
        return NULL;
    o = out;
    /* v2 header */
    uint32_t *vh = (uint32_t *)o;
    vh[0] = FFS_MAGIC_V2;
    vh[1] = (uint32_t)total;
    vh[2] = FFS_HAS_FS | FFS_HAS_HS | FFS_HAS_SS;
    vh[3] = fs_count;
    vh[4] = hs_count;
    vh[5] = ss_count;
    o += 24;
    memcpy(o, fs_start, (size_t)(fs_end - fs_start));
    o += (size_t)(fs_end - fs_start);
    memcpy(o, hs_start, (size_t)(hs_end - hs_start));
    o += (size_t)(hs_end - hs_start);

    /* SS 段 */
    for (const unsigned char *q = fs_start; q < fs_end; q += q[0]) {
        if (q[1] == 4) {
            memcpy(o, q, 9);    /* interface 描述符 9B，沿用 FS 内容 */
            o += 9;
        } else if (q[1] == 5) {
            /* SS 端点描述符：bLength=7, type=5, addr, attr, wMaxPacketSize=1024, bInterval */
            o[0] = 7;
            o[1] = 5;
            o[2] = q[2];        /* bEndpointAddress */
            o[3] = q[3];        /* bmAttributes (0x02 bulk) */
            o[4] = 0x00;        /* wMaxPacketSize = 1024 LE */
            o[5] = 0x04;
            o[6] = 0;           /* bInterval */
            o += 7;
            /* SS 端点伴随描述符：bLength=6, type=0x30, bMaxBurst=0, bmAttributes=0, wBytesPerInterval=0 */
            o[0] = 6;
            o[1] = 0x30;
            o[2] = 0;           /* bMaxBurst */
            o[3] = 0;           /* bmAttributes */
            o[4] = 0;
            o[5] = 0;
            o += 6;
        }
    }
    *outlen = total;
    return out;
}

ssize_t write(int fd, const void *buf, size_t count)
{
    if (!real_write)
        real_write = (ssize_t (*)(int, const void *, size_t))dlsym(RTLD_NEXT, "write");

    if (buf && count >= 16) {
        const uint32_t *h = (const uint32_t *)buf;
        if (h[0] == FFS_MAGIC_V1 && h[1] == count) {
            size_t nl = 0;
            unsigned char *nb = build_v2((const unsigned char *)buf, count, &nl);
            if (nb) {
                char msg[128];
                ssize_t r = real_write(fd, nb, nl);
                int e = errno;
                snprintf(msg, sizeof(msg),
                         "rewrote v1 descs (%zu B, fs=%u hs=%u) -> v2 %zu B, ret=%zd",
                         count, h[2], h[3], nl, r);
                if (r < 0) {
                    snprintf(msg, sizeof(msg), "write failed errno=%d (%s)", e, strerror(e));
                    shim_log(msg);
                    { /* dump v1 blob */
                        char hex[512]; int n = 0;
                        for (size_t i = 0; i < count && i < 64; i++) n += sprintf(hex+n, "%02x", ((const unsigned char*)buf)[i]);
                        shim_log(hex);
                    }
                    { char hex[512]; int n = 0;
                        for (size_t i = 0; i < nl && i < 96; i++) n += sprintf(hex+n, "%02x", nb[i]);
                        snprintf(hex+n, sizeof(hex)-n, "  (v2 len=%zu)", nl);
                        shim_log(hex);
                    }
                }
                shim_log(msg);
                free(nb);
                if (r >= 0)
                    return (ssize_t)count;   /* adbd 认为整段已写 */
                return r;
            } else {
                shim_log("v1 descs seen but build_v2 failed, passing through");
            }
        }
    }
    return real_write(fd, buf, count);
}
