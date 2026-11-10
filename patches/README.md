# patches/ —— 内核补丁记录 + rootfs 改动

## 结构

```
patches/
  kernel/6.18.18/     内核补丁记录（diff -u 形式，不参与构建）
    0001-analogix-dp-rockchip-edp-bringup.patch
    0002-tcpm-defer-role-switch.patch
  rootfs/             构建时对 rootfs 的全部改动（NN-*.sh，按文件名顺序执行）
```

## patches/kernel/ —— 补丁记录（不参与构建）

- 记录「相对上游 Linux 6.18.18 改了什么、为什么」：`0001` 是 eDP 点亮，`0002` 是 tcpm defer 修复。
- **构建脚本不会读取它**（`grep -rn "patches/kernel" scripts/` 仅命中注释）。真正参与构建的是 `kernel-modules/` 里的完整源码。
- 改模块时同步更新对应 patch（`diff -u` 原版 vs 改后），保证「源码 ↔ patch ↔ ko 产物」三者一致。

## patches/rootfs/ —— rootfs 补丁（NN- 顺序，必须幂等）

- `scripts/patch-rootfs.sh` 在 `build-rootfs` 阶段按文件名排序执行所有 `*.sh`（`.disabled` 跳过）。
- 覆盖：基础系统（10-19）、驱动模块（22/48/55/58/62）、服务与功能（50/53/59/61/…）、发布清理（98）。
- **幂等**：重复执行结果一致——用 `install`、`cat >`、`sed -i`，避免 `>>` 追加、`mkdir` 不带 `-p`。
- 新增补丁：选未占用号段，加文件后跑一次 `build-rootfs` 验证。
- 停用但保留历史的补丁：改名 `*.disabled` 并移入 `archive/rootfs/`（构建不再执行）。

## 约定

- 改 rootfs 后迭代：`sudo env SKIP_ROOTFS_EXTRACT=1 ROOTFS=$PWD/work/rootfs-official SKIP_BOOT=1 FNOS_BOOT=$PWD/work/boot-fnos SKIP_DTS=1 ./scripts/build-all.sh`。
- 已归档：`53-rk806-rstfix.sh`（RK806 复位改 DTB）、`59-otg-autoswitch.sh`（Type-C 改 tcpm 原生）、`55-usb-role.sh`（旧 dtb 切换方案，拆出 adb-watch 后归档）。
