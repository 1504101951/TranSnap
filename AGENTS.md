# 智能体工作规范

## Issue 跟踪

规格与执行工单统一在本仓库 GitHub Issues 中维护，操作约定见 [Issue 跟踪规则](docs/agents/issue-tracker.md)。

## 领域文档

本仓库采用单一领域上下文，术语以 [领域术语表](docs/glossary.md) 为准，代码与文档中保持一致；同一术语定义冲突时，先向用户确认以哪一份为准。

## 代码约定

通道名、方法名、UserDefaults 键与共享枚举只在 `common/constants` 定义，共享工具放 `common/utils`；细则见 [代码约定](docs/agents/coding-conventions.md)。

## 注释

不写、不维护任何代码注释，包括文档注释（`///`）、行内与块注释、测试说明与脚本说明。意图由命名、测试名称和规格 Issue 表达；理解行为以代码与 Issue 为准。新增或修改代码时不得添加注释，遇到残留注释直接删除。仅保留 Dart 分析器指令（`// ignore:`、`// ignore_for_file:`）与脚本首行 shebang；第三方或工具生成的文件（如 `macos/Flutter/GeneratedPluginRegistrant.swift`、`macos/Runner/Configs/*.xcconfig`）不在此列。

## 界面设计

设计、实现、重构或审查界面前，读取并遵守：

1. [样式规格 #67](https://github.com/1504101951/TranSnap/issues/67)全文及当前功能 Issue 的样式约束；组件尺寸、圆角、配色和命中区以 Issue 的明确规定为准，调色盘、线宽和图形模式按样式规格中的确定数值实现。
2. 操作行为、编辑对象选择、保存、键盘与验收边界读取[功能与交互规格 #1](https://github.com/1504101951/TranSnap/issues/1)及当前功能 Issue。
3. 材料接入职责、共享绘制样式、颜色／粗细控件边界读取[架构设计约束 #68](https://github.com/1504101951/TranSnap/issues/68)及当前功能 Issue；仅实际选用 liquid_glass_widgets 时应用其“liquid_glass_widgets 专项规则”小节。
4. 液态玻璃设计资料的来源与使用边界见样式规格“来源与改编说明”，许可证原文保存在 [liquid-glass-source-license.txt](docs/agents/liquid-glass-source-license.txt)。

## 并行会话

使用所用智能体框架的完整会话 ID 隔离临时产物，并以 `<框架名>-Thread` 标记 Issue 输出，具体规则见 [会话隔离规范](docs/agents/session.md)。

## 先更新规格，再开发

开发依据分为三类：[功能与交互规格 #1](https://github.com/1504101951/TranSnap/issues/1)、[样式规格 #67](https://github.com/1504101951/TranSnap/issues/67)、[架构设计约束 #68](https://github.com/1504101951/TranSnap/issues/68)。实施已批准需求前，先更新受影响的 GitHub Issue。本地规格副本与用户指定保留的澄清记录的保留或删除，统一按 [Issue 跟踪规则](docs/agents/issue-tracker.md)「三类规格与执行工单」处理。界面数值必须明确，不得擅自偏离规格或将待确认参数视为已批准值。

## 零警告

交付前，本次改动不得在以下输出中留下警告：`flutter analyze` 无 issue；`xcodebuild build-for-testing` 输出中没有 `warning:`（含 Swift 并发警告）；`./scripts/package-and-install-macos.sh` 的标准错误只允许出现 [macOS 构建说明](docs/macos.md)「允许保留的工具提示」中登记的条目。发现警告时从源头修改代码或配置，不用 `// ignore`、`@preconcurrency`、`nonisolated(unsafe)` 等方式压制，也不整段重定向丢弃输出；确实无法在项目内消除的工具提示，登记到该表并写明来源与保留原因。

## 目录索引

项目维护的每个目录通过 `index.md` 说明直接子文件和子目录的作用，每项一句话；新增、删除或重命名项目文件时同步所在目录索引。Git 元数据、依赖缓存、构建产物、个人工作区目录，以及 Xcode 自动生成或维护的目录（`*.xcodeproj/`、`*.xcworkspace/`、`*.xcassets/`、`*.lproj/` 及其子目录）不建 `index.md`，由上级索引一句话说明整个目录。

## Issue 状态权限

智能体不得关闭 Issue；实现、测试和验收结果仅通过评论与中文标签记录，操作见 [Issue 跟踪规则](docs/agents/issue-tracker.md)。用户指出未完成时，按实际进度标记待实现或待验收并记录未完成项，不将已关闭状态视为验收通过。

## 验收方式

禁止使用 computer-use。界面效果验收由用户完成；智能体负责代码检查、自动化测试、构建与签名核验，不能把自动化通过等同于用户验收。
