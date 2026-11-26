# TranSnap

[中文](README.md) | [English](README.en.md)

**TranSnap** 是一款面向 **macOS 26+** 的桌面效率工具，集成了全局选区翻译与屏幕采集套件。应用采用 Flutter/Dart 实现界面与业务编排，由 Swift 原生层提供非激活悬浮面板、`macOS 26+` 液态玻璃材料与系统级屏幕采集能力。

> 当前版本专注于 **macOS 26+（Darwin 25+）**，仅支持 Apple 芯片（arm64）Mac。

![TranSnap 功能演示](docs/media/transnap-intro.gif)

---

## 核心能力

### 1. 全局选区翻译与写作助手
- **即时划词与快捷键唤起**：在任意应用中选中文本，或按下全局快捷键，不抢占来源窗口焦点，在选区附近弹出翻译卡片。
- **四种文本模式**：支持**翻译**、**润色**、**纠错**与**解释**，可在卡片内一键切换模式或临时切换翻译服务。
- **自适应卡片布局**：常规文本采用上下紧凑单栏卡片，支持**双语对照**（左译右原）与**单词词典**布局；内置系统离线语音朗读（TTS）与**生词本**收藏。
- **输入直译与原地替换**：在可编辑输入框中选中文本后触发快捷键，可在输入位置旁展开轻气泡直译并一键替换原文。
- **多引擎服务**：内置 Apple 原生离线翻译与网页端免配置翻译，同时支持配置 OpenAI 兼容接口及主流云翻译 API（按需配置凭据与术语表）。

### 2. 屏幕采集、标注与实时翻译
- **截图与标注编辑**：内置精准选区框选、矩形/椭圆/箭头/直线、画笔/荧光笔/马赛克、序号标记、文本、取色器、标尺、贴纸及渐变美化背景；可置顶为桌面**贴图**，或直接执行本地 **OCR 文档识别**与二维码/条码解析。
- **自定义工具栏**：每次截图先显示常用工具栏，最多 6 个工具，按数字键 `1–6` 选用；双击工具栏左侧的拖动区域或连按两次 `Tab` 展开完整工具栏，其余工具按修饰键分组（默认 `⌘`、`⌥`），每个工具只有一个键位。在设置中可拖拽排布、设置子菜单与修饰键分组。
- **屏幕录制与导出**：支持区域、窗口或应用维度录制与延时倒计时；录制完成后在统一结果窗内裁剪片段，导出 **MP4**、**GIF**、**APNG** 或 **WebM**。
- **滚动长截图与历史合图**：支持手动及自动辅助滚屏拼接长图，在「截图历史」中支持勾选多图纵向/横向拼接、拆分及逐像素差异比较。
- **实时区域翻译**：持续追踪屏幕选区或指定窗口内的画面文字，将翻译结果实时叠加于选区之上；画面不变时不重复识别。

### 3. 本地 MCP 服务
- 内置签名合规的 stdio helper（`TranSnap.app/Contents/MacOS/transnap-mcp`），可在「设置 → MCP」一键生成配置或安装至 Claude Code、Claude 桌面、Codex、Grok。
- 支持显示器/窗口枚举、受控截图、OCR 文档识别与可授权的界面元素读取及辅助操作。

---

## 快速开始

### 安装与运行
1. 从 GitHub Releases 获取构建产物，或自行通过打包脚本完成签名安装，将应用安装至固定路径 `/Applications/TranSnap.app`。
2. 直接打开或从终端启动：

```bash
open /Applications/TranSnap.app
```

首次运行请在顶部菜单栏或「设置 → 通用 → 权限与启动」按指引授予**辅助功能**与**屏幕录制**权限。

### 默认全局快捷键
| 动作 | 默认快捷键 |
| --- | --- |
| 翻译当前选区 | `⌘ + ⇧ + T` |
| 替换选中文本 / 翻译选区内容 | `⌘ + ⇧ + R` |
| 区域截图与采集 | `⌘ + ⇧ + S` |

所有快捷键均可在「设置 → 翻译 → 快捷键」与工具栏设置中自定义。

---

## 从源码构建与打包

### 环境要求
- macOS 26.0 或更高版本（SDK 26+），Apple 芯片 Mac
- Xcode 27+ 与对应 Command Line Tools
- Flutter SDK（Dart `^3.11.1`）
- 本机登录钥匙串中的 `TranSnap Local Signing` 代码签名证书（配置指南见 [macOS 构建与签名说明](docs/macos.md)）

### 常用命令

```bash
# 拉取依赖
flutter pub get

# 代码检查与 Dart 单元测试
flutter analyze && flutter test

# 构建 macOS 原生调试产物与 Swift 单测目标
xcodebuild build-for-testing -workspace macos/Runner.xcworkspace -scheme Runner -destination 'platform=macOS,arch=arm64'

# 固定签名打包 Release 版本、校验 ZIP 并安装至 /Applications/TranSnap.app
./scripts/package-and-install-macos.sh
```

> 请使用 `xcodebuild build-for-testing` 配合独立目标校验原生编译；日常开发避免运行会拉起全量 Runner UI 测试的 `xcodebuild test`。

---

## 文档导航

- [完整使用指南](docs/usage.md)：所有功能入口、浮层交互、截图工具栏、历史管理与设置详述
- [系统架构说明](docs/architecture.md)：双端（Dart / Swift）职责划分、通道协议与多引擎窗口模型
- [macOS 构建、权限与签名](docs/macos.md)：`package-and-install-macos.sh` 流程、权限排查与免弹窗钥匙串授权设置
- [领域术语表](docs/glossary.md)：项目核心概念与规范命名
- [目录索引](docs/index.md)：完整文档与子目录入口
