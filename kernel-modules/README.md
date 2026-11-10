# kernel-modules/ —— out-of-tree 内核模块完整源码

fnOS 官方内核是**预编译**的，不能改内核源码树。所以对某个内核模块的修改方式：
**维护一份完整源文件 → 用目标内核 headers 重编出同名 `.ko` → 覆盖 initramfs 与 rootfs 里的原厂模块。**

## 模块清单

| 模块 | 源文件 | 作用 | 产物去向 |
|---|---|---|---|
| `analogix-dp-6.18.18/` | `analogix_dp_core.c/.h`、`analogix_dp_reg.c/.h` | eDP 显示点亮（fnOS 内核无板级 eDP 支持） | `assets/modules/6.18.18-trim/analogix_dp.ko`，`prepare-boot.sh` 替换进 uInitrd |
| `smdt-mcu-wdt/` | `smdt_mcu_wdt.c` | MCU（STM8S00K3，i2c-6 0x62）看门狗：不 kick 则 ~603s 复位 SoC，shutdown 时 disarm | `assets/modules/6.18.18-trim/smdt_mcu_wdt.ko`，58 补丁装进 rootfs |
| `tcpm-defer-fix/` | `tcpm.c` | Type-C 角色切换：原厂 tcpm 用 `IS_ERR_OR_NULL()` 吞掉 `-EPROBE_DEFER`，dwc3 晚注册时 `role_sw=NULL` 且 probe 成功 → 角色切换随机失效 | `assets/modules/6.18.18-trim/tcpm.ko`，同时进 uInitrd 与 rootfs kernel 路径 |

## 编译（必须用目标内核 headers）

```bash
# 板端（最准）
make -C /lib/modules/$(uname -r)/build M=$PWD modules
# 主机侧用 work/ 下解包的 linux-headers-<ver>，不要用主机内核 headers
strip --strip-debug <name>.ko
```

每个模块目录三件套：**源码 + Makefile + README.md**（写清根因、与哪些 DTS/补丁配合、验证方法）。模块内加 `MODULE_VERSION("zt1-*")`，运行时 `/sys/module/<name>/version` 可验证。

## 与 patches/kernel/ 的关系

- 这里 = **实际参与构建的完整源码**（构建脚本读它：`58-kernel-sync.sh`、`build-analogix-dp.sh`）。
- `patches/kernel/` = **diff 记录**（给人看/提上游参考，**不参与构建**）。
- 改模块行为时两处保持一致：改源码 + 重新 `diff -u` 生成/更新对应 patch。

## 约定

- 新增模块：建目录（三件套）→ 编译 → 产物进 `assets/modules/<ver>/` → 更新 `patches/rootfs/58-kernel-sync.sh`（板端换内核重编）与 `scripts/prepare-boot.sh`（如进 initramfs）。
- 不要提交 `.o/.ko/.cmd` 等中间产物（`.gitignore` 已覆盖，本地编译后随手 `rm`）。
- 被淘汰的模块（如 `rk806-rstfix`，RK806 复位改由 DTB 接管）移入 `archive/kernel-modules/`。
