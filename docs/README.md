# docs/ —— 项目文档

| 文档 | 内容 |
|---|---|
| `GUIDE.md` | **总览**：技术路线、引导链（上游 U-Boot v2026.10）、功能状态、仓库结构、构建脚本、使用、分区布局 |
| `BUILD.md` | 构建细节：依赖、四阶段、u-boot 重编、救砖流程 |
| `CONFIG.md` | `config.env` 全部配置项 + 关键修复说明（Type-C tcpm 三层修复、显示等） |
| `UBOOT.md` | 上游 u-boot 的改动与验证（BL31/TPL/LDR、bootstd+extlinux） |
| `AUDIO.md` | ES8388 音频拓扑与 MCLK 门控坑 |
| `VPU.md` | 视频编解码现状（H.264/HEVC 硬解可用、AV1 硬解未通） |
| `ADB-USB3.md` | adb SuperSpeed 描述符 shim 原理与实测 |

项目根目录另有 `AGENTS.md`（AI/协作者规范与编译约定）、`archive/README.md`（淘汰方案清单）。
各一级目录下 `README.md` 介绍该目录内容（assets/dts/kernel-modules/patches/scripts/docs）。

约定：改动涉及功能/构建/目录结构时**同步更新对应文档**，文档与代码同批提交。
