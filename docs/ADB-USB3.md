# adb over USB 3.0（SuperSpeed）—— 实现说明

## 问题
厂商提供的 `/usr/bin/adbd` 来自 **android-tools 4.2.2**（Android 4.2 时代），它给
FunctionFS 写的描述符是 **v1 格式**（只有 FS + HS），没有 SuperSpeed 描述符集合。

fnOS 内核（6.18.18-trim）的 `composite.c` 在 USB3 速度下只统计 `c->superspeed`
（由函数的 ss_descs 决定）。ffs.adb 没有 SS 描述符 ⇒ `bNumConfigurations = 0` ⇒ 主机
枚举时报：

    usb 4-1.2: no configurations
    usb 4-1.2: can't read configurations, error -22

所以之前只能在 gadget 里强制 `max_speed=high-speed`（USB2 480M）。

## 解法
`assets/adbd-ss-shim/adbd_ss_shim.c`：LD_PRELOAD 小 shim，拦截 adbd 对
`/dev/usb-ffs/adb/ep0` 的 `write()`：

- 识别 v1 描述符块（magic=1, length, fs_count, hs_count + FS 描述符 + HS 描述符）；
- 重写为 **v2 块**：
  - 12 字节头：magic=3 / length / flags=`FS|HS|SS`(0x7)
  - 3 个计数字段：fs_count / hs_count / ss_count
  - 原 FS 描述符 + 原 HS 描述符
  - 新构造 SS 段：接口描述符（复制 FS 的）+ 每个端点一对
    （SS 端点描述符 bLength=7、wMaxPacketSize=1024 + 端点伴随描述符 bLength=6/type=0x30）
- 写入成功则向 adbd 返回原始长度（adbd 认为写完了）。

产物 `libadbd_ss_shim.so`（aarch64，板上 gcc 编译）随镜像装到 `/usr/local/lib/`，
`/usr/local/sbin/zt1-adbd-gadget.sh` 启动 adbd 时用
`LD_PRELOAD=/usr/local/lib/libadbd_ss_shim.so`，并把 `max_speed` 设为 `super-speed`。

## 实测（2026-11-02）
- 板端：`current_speed=super-speed`、`bcdUSB=0x0320`
- 主机：`usb 4-1.2: new SuperSpeed USB device number 14 using xhci_hcd`，
  `lsusb` 可见 `Bus 004 Device 014: ID 2207:0006 ... zeroT1 fnOS`，
  `/sys/bus/usb/devices/4-1.2/speed = 5000`
- `adb devices` 正常；`adb push` 200MB 约 18.4MB/s（受限于老 adbd 协议包大小，不是链路；链路 5Gbps）

## 重新编译
    cd assets/adbd-ss-shim
    gcc -shared -fPIC -O2 -o libadbd_ss_shim.so adbd_ss_shim.c -ldl
（板上验证时可直接在 zeroT1 上编译；构建机交叉编译时用同一套 aarch64 工具链）

## 回退
把 `/usr/local/sbin/zt1-adbd-gadget.sh` 里
`LD_PRELOAD=... start-stop-daemon` 恢复成不带 LD_PRELOAD，并把 `super-speed` 改回
`high-speed` 即可退回 USB2。
