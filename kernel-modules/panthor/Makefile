# SPDX-License-Identifier: GPL-2.0
#
# panthor（Mali-G610 开源 GPU 驱动）外挂模块编译
# 用法（必须在目标内核的 headers 下编译）：
#   make -C /lib/modules/$(uname -r)/build M=$PWD modules
#
# 源码基 mainline 6.18.18 drivers/gpu/drm/panthor，未做功能修改；
# 仅作为 zt1-kernel-sync 的换内核重编输入（见 docs/CONFIG.md「GPU」章节）。

obj-m := panthor.o

panthor-y := \
	panthor_devfreq.o \
	panthor_device.o \
	panthor_drv.o \
	panthor_fw.o \
	panthor_gem.o \
	panthor_gpu.o \
	panthor_heap.o \
	panthor_hw.o \
	panthor_mmu.o \
	panthor_sched.o
