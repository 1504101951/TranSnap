# TranSnap 系统架构

**TranSnap** 采用 **Flutter/Dart + macOS 原生 Swift** 双层架构：
- **Dart 层**：承载多窗口 UI、翻译编排、历史/生词本、截图标注与编辑文档状态，以及设置事务与校验。
- **Swift 原生层**：负责 macOS 系统权限、全局事件监控、非激活悬浮面板、ScreenCaptureKit 采集与编码、Vision OCR / 条码识别、系统离线翻译 / 语音朗读，以及液态玻璃材料桥接。

> 协议约束：跨模块通道名、方法名、偏好键、错误码与枚举在 Dart 端集中定义于 `lib/src/common/constants/`，在 Swift 端统一定义于 `macos/Runner/Common/Constants.swift`，两端字面量保持严格一致。

---

## 一、多引擎与进程窗口模型

### 1. 主引擎与附属引擎分工
| 窗口 / 模块 | 引擎归属 | 说明 |
| --- | --- | --- |
| 选区划词 / 翻译浮层 / 输入替换气泡 | 主引擎（`TranSnapApp`） | 持有唯一偏好状态、当前 `SelectionSession`、主翻译队列与实时翻译 `LiveRegionSession` |
| 设置窗口（`settingsMain`） | 独立附属引擎 | 按需创建并预热，配置变更经 `transnap/settings` 通道提交到主引擎 |
| 权限向导（`permissionWizardMain`） | 独立附属引擎 | 独立引导权限授权；授权完成直接进入主应用状态 |
| 历史管理窗口（`historyMain`） | 独立附属引擎 | 承载翻译历史、生词本与截图历史三大分段，由数据库变更事件自动刷新 |
| 截图与图片编辑（`screenshotMain`） | 独立附属引擎 | 承载 `ScreenshotApp` 画布与工具栏，文字识别与贴图等系统调用经控制器路由 |
| 采集控制与结果窗（`captureMain`） | 独立附属引擎 | 承载录制悬浮四气泡控制条，以及视频与长截图结果窗 |

### 2. 请求路由与数据唯一所有权
- Swift 侧所有附属窗口由 `WindowEngine.start` 统一创建引擎、安装通道与注册原生玻璃平台视图。
- `MacPlatformBridge.routeWindowRequest` 路由规则：**优先交由当前控制器处理本地系统能力，未实现的方法转发至主 Dart 引擎**，保证偏好写入、翻译服务调用与历史持久化只有一个写入源头。
- 所有独立窗口均通过 `transnap/appearance` 通道接收来自 `NativeGlassFactory` 的外观快照（浅/深外观、`accentLight`/`accentDark` 系统强调色、透明度等）。

---

## 二、核心通道与原生服务清单

### 1. 平台通道（`lib/src/common/constants/channel_names.dart` ↔ `AppConstants`）
- `transnap/platform` & `transnap/platform/events`：主引擎核心请求（能力声明、权限、选区读取、替换输入、浮层尺寸与显隐、系统翻译、语音朗读、历史读写、热键状态、性能打点）。
- 能力声明：原生以 `capabilities` 上报支持的能力（`PlatformCapability`：Apple 系统翻译、词典、权限、截图、录制、MCP）；主引擎、设置窗口与历史窗口启动时读取，按声明隐藏不支持的入口，内置翻译服务由 `ServiceConfig.builtins` 按能力列出，首项为默认服务。macOS 上报全部能力。
- 快捷键表示：全局翻译、输入翻译、区域截图快捷键在偏好中各存为 `{key, modifiers, label}`，`key` 为 W3C UI Events `code` 键名（如 `KeyT`、`Digit1`），`modifiers` 为 `control`、`alt`、`shift`、`meta` 名称列表；截图工具栏列的组合同样以名称列表保存。Dart 端以 `Shortcut` 记录与 `ShortcutModifiers` 位（control 1、alt 2、shift 4、meta 8）校验与比较；原生端以 `ShortcutNames` 在键名与本平台键码、修饰键之间转换。macOS 启动时把以键码保存的旧偏好规范化一次。
- `transnap/settings`：设置页面草稿读取与序列化自动保存。
- `transnap/screenshot`：截图快照、本地图片导入、OCR/条码、图内段落翻译、贴图、标注保存与确认操作。
- `transnap/capture` & `transnap/capture_video_preview`：录制/长截图会话控制、实时帧预览与结果导出。
- `transnap/appearance`：跨引擎实时外观与强调色快照广播。
- `transnap/window_startup`：附属窗口首帧就绪握手。

### 2. Swift 原生核心模块（`macos/Runner/`）
- **选区与输入替换**：`SelectionMonitor` + `SelectionGestureDetector` + `TextSelectionContext` + `AccessibilitySelection`；输入替换时保持来源焦点并记录阶段耗时（`os_log` `subsystem=TranSnap`、`category=Performance`）。
- **浮层与贴图**：`OverlayPanel` 管理非激活面板防抢焦定位与淡入/缩放；`PinOverlayController` 管理多个独立置顶贴图的命中、拖动与 Esc 单窗关闭。
- **采集与导出流水线**：
  - `ScreenCaptureService`：ScreenCaptureKit 截图、图像解码、Vision 文档 OCR（保留表格/列表 Markdown 结构）与并行二维码/条码解码。
  - `MediaCaptureService` + `ApplicationRecorder`：区域/窗口/应用多屏合成录制与音频静音编码，启动耗时记入 `subsystem=TranSnap`、`category=CaptureStartup`。
  - `GIFExporter` & `WebMExporter`：基于裁剪起止时间生成有限宽高 GIF/APNG 或无窗口 WebKit VP8 WebM（保证源帧时间戳与丢帧报错）。
  - `ScrollStitcher` & `AutoScroll`：缩略图静止帧过滤、上下固定区与纵向位移匹配、辅助功能滚动条自动步进。
  - `ScreenshotComposer`：截图历史多图原始像素拼接、拆分与逐像素差异比较。
  - `ScreenshotStorage`：统一管理 `~/Library/Application Support/TranSnap/` 下分类日期目录与防重名写入。
  - `RecordingClickOverlay`：采集期间透明点击穿透层，绘制光学点击波纹与拖动轨迹。
  - `LiveRegionCapture` & `LiveRegionCoordinator`：实时区域画面采集（画面不变时跳过识别）、段落按阅读顺序回传与原位译文叠加渲染；OCR 结果以 `ScreenCaptureService.OCRBlock` 流转（段落位置及按空白与字符类别切出的分段位置），只在 Flutter 通道出口转为字典。
- **系统服务**：`SystemTranslationService`（Apple 离线翻译会话与语言包检查）、`SpeechService`（离线 TTS）。

---

## 三、选区翻译与结果浮层架构

1. **会话生命周期（`SelectionSession`）**：每次划词或快捷键触发创建冻结会话身份（锁定来源服务与语言方向），按分段并发或流式更新 `TranslationProgress`（保存已完成分段与双尾上下文，支持失败片单独 `retry`）。
2. **智能上下文与防误触**：`SelectionMonitor` 过滤非文本焦点及排除应用；仅在确实产生有效选区且内容变化时展示触发按钮（`84×32` 命中窗）或直接展开译文。
3. **译文浮层（`TranslationOverlay`）**：
   - 使用 `TranslationOverlay.layoutFor` 统一 Dart 布局与原生窗口尺寸契约：单栏卡片固定 `560pt` 宽、高度随内容自适应（上译文、下原文）；双语对照（左译右原）与单词词典模式采用 `720×420`。
   - 底部操作栏与各栏朗读/复制控件按悬停交互呈现，避免静态遮挡正文阅读区。

---

## 四、截图编辑、工具栏与统一结果窗

### 1. 编辑文档与渲染一致（`EditDocument`）
- **矢量标注与撤销栈**：图形（矩形/椭圆/箭头/直线）、普通/荧光/马赛克画笔、序号、文本、贴纸与渐变美化样式均使用同一条基于命令历史的 `EditDocument`；拖动预览层与 `Export` 使用统一 `paintAnnotation`、`paintBeautifyBackdrop`（渐变背景 + 外圆角阴影）和 `ratioRect`（`lib/src/common/utils/geometry.dart`）。
- **性能隔离**：画布绘制使用 `RepaintBoundary` 隔离，马赛克针对每张源图仅做一次 12px 对齐整图栅格化缓存；取色器基于缓存非预乘 RGBA 读取像素，标尺与取色悬停状态不进入撤销历史。
- **对角光标桥接**：斜向缩放命中由 `NativeResizeCursor` 通知 Swift 通过 `NSCursor.frameResize` 渲染原生双向光标。

### 2. 工具栏网格与多级托盘
- 工具动作登记在 `ScreenshotActions.composable`，通过 `hostsChildren` 区分父级能力（默认「截图」挂接「录制」「滚动长截图」）。
- 设置端与编辑端共用 `ToolbarModifiers.allowed` 与 `ToolbarGrid`（每组 6 格对应物理键 `1–6`，最多 8 组，主行每行最多 `ToolbarGrid.groupsPerLine = 2` 组，无修饰符行不显示前置符号）。
- 选中父工具、工具属性或点击需要附加参数的动作时，由 `LiquidSplit` 渲染统一的**二级/三级托盘**（带指向锚点按钮的 `4pt` 指示三角与流体合并动画），动态行与托盘按钮共用统一轻量样式而非嵌套原生玻璃。

### 3. 统一结果窗骨架（`result_window.dart`）
录制、长截图与「打开方式」导入图片复用 `ResultWindowCanvas`、`ResultWindowBar`、`ResultBarDivider`、`ResultTextButton`、`ResultIconButton` 与 `ResultUpwardTray`：
- **画布与底栏**：媒体四周固定 `24pt` 中性衬底留白，底部工具栏固定 `52pt` 高度；最小窗口尺寸为录制 `600×200`、长截图与导入图片 `600×240`。
- **播放器集成**：录制结果内嵌 `AVPlayerView` 并设置 `controlsStyle = .none`，由自定义进度条与 KVO 播放观察器同步时长与循环播放。
- **截图历史入库条件**：仅当用户保存成功或主动选择「保留在历史」时写入 SQLite 历史表与归档目录；列表使用共享只读卡片容器 `HistoryGroupCard` 与统一悬浮操作按钮，保证大数据量下滚动稳定。

---

## 五、视觉体系、动效与图标系统

- **视觉规范集中**：`GlassMetrics`（`lib/src/common/constants/glass_metrics.dart`）与 `MotionMetrics`（`motion_metrics.dart`）集中管理圆角、间距、字体尺寸与弹簧阻尼。
- **跨层材料原则**：外层容器由 `NativeGlassSurface` 提供单层原生玻璃或 `NativeReadingCanvas` 绘制连续 sRGB 阅读底色（`contentLayoutGuide` 仅避让红绿灯等安全区），禁止嵌套多层玻璃导致双重折射。
- **统一图标体系**：全局功能图标统一使用 **`lucide_icons_flutter`（`LucideIcons`）**；翻译状态、声波、生词收藏、复制打勾、录制脉冲与 `BusyRing` 加载环由纯 Dart `CustomPainter` 驱动；所有动效遵循系统「减少动态效果」设置（无应用内开关）。
- **逐字显影与棱镜高光**：译文与实时翻译分别由 Dart `CharReveal` 与 Swift `LiveFitTextView` 按相同节奏逐字显影；`OpticalPrismOverlay` 在前景叠加 Impeller 着色器 `shaders/optical_prism.frag` 实现随指针变动的 `1.25pt` 银白倒角与完成扫光。

---

## 六、本地 MCP 接口设计

- **独立可信 helper**：位于 `TranSnap.app/Contents/MacOS/transnap-mcp`（由 Xcode 目标 `TranSnapMCP` 构建），通过 stdio 处理 JSON-RPC 最小子集（`initialize`、`tools/list`、`tools/call`、`ping`、`notifications/cancelled`），并与主 App 共用 `AppConstants`。
- **安全校验链路**：`MCPCaptureServer` 随主 App 启动监听本地 Unix socket；接入前由 `MCPPeer` 按进程审计令牌校验对端是否为本 App 包内签名一致的 helper（Bundle ID 为 `com.coolyang.transnap.mcp` 且叶证书匹配）。
- **权限分层与隔离**：所有工具受设置项「允许 agent 截图」控制；点击/输入/快捷键/滚动/拖拽等界面操作受独立开关「允许操控电脑」二次隔离，并在首次操控目标应用时弹出人工授权面板；客户端设置页通过 `mcp_platforms.dart` 注册表读写 `mcpServers.transnap`。
