# 板载STM8S00K3 MCU看门狗驱动（out-of-tree）
#
# 编译（需要 fnOS 官方内核 6.18.18-trim 的 headers，见 docs/BUILD.md）：
#   make -C /path/to/kernel-headers M=$PWD ARCH=arm64 \
#        CROSS_COMPILE=aarch64-linux-gnu- modules
obj-m += smdt_mcu_wdt.o
