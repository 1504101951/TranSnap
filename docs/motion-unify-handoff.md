# 界面动效统一与设置页静态优化：交接文档

Claude-Thread: 3859dee0-9aa1-4095-ac4e-0a94c70c470e。2026-11-20 用户确认，执行工单 #142「第三期」。

本文是待实现方案，实现并验收后按「注释与文档同步」规则改写进 `docs/architecture.md`、`docs/usage.md`，并删除本文与索引条目。

## 1. 依据（实施前先读）

| 规格 | 位置 | 内容 |
| --- | --- | --- |
| [#1 功能与交互](https://github.com/1504101951/translateApp/issues/1) | 「界面动效与无障碍交互边界（#142）」第 6–9 条；「采集工具与媒体结果」中视频结果窗口一条 | 行为 |
| [#67 样式](https://github.com/1504101951/translateApp/issues/67) | 「界面动效规格（#142）」第 7、8、9、11–14 条；「录制裁剪、点击高亮与 APNG/WebM 导出（#110）」第 1 条 | 数值 |
| [#68 架构](https://github.com/1504101951/translateApp/issues/68) | 「界面动效架构约束（#142）」第 7–10 条 | 实现边界 |
| [#142 执行工单](https://github.com/1504101951/translateApp/issues/142) | 「第三期」 | 范围清单 |

已确认的预览：[动效预览](https://claude.ai/artifact/ApgMS2mcXXpm9WpRZj7HHR)、[设置页静态优化](https://claude.ai/artifact/HAmQ9pMuzkrjWp2D5HpWCe)。静态优化只采用：说明文字归位、状态标签、侧边栏图标块、行间细线；不加分组标题与页头说明。

## 2. 当前代码状态

1. `main` 上有未推送的提交：caa2685、c4780d6（#138），de47bb3（#142 一期），0adfbdc、72e7936（#141），625fe55（#142 二期）。推送需要用户授权。
2. 工作区有另一项工作 #143（录屏点击特效）的未提交改动，以下文件不要混进本任务的提交：
   - Dart：`method_names.dart`、`preference_keys.dart`、`screenshot_enums.dart`、`app_settings.dart`、`settings_app.dart`、`settings_controller.dart`。
   - 原生：`project.pbxproj`、`MediaCaptureService.swift`、`ScreenshotWindowController.swift`、`macos/Runner/index.md`、`CaptureMediaTests.swift`、`RecordingClickOverlay.swift`（未跟踪）。
   - 测试：`settings_app_test`、`settings_controller_test`、`settings_test`。
   - 另外 `screenshot_app.dart`、`Constants.swift`、`capture_app_test.dart`、`docs/usage.md`、`docs/architecture.md` 中有部分改动块属于 #143。
   
   本任务改到这些文件时，需要按改动块拆分提交。上一期的做法是：
   1. 在临时工作树中，把 HEAD 加上自己的改动块。
   2. 在临时工作树里跑 `flutter analyze` 和 `flutter test`。
   3. 在临时工作树提交。
   4. 回到主目录执行 `git reset --mixed <提交>`。
3. 规格已全部定稿。#67 中视频结果窗口的尺寸已改成底部工具栏的算法（智能体拟定、用户授权），#68 第 10 条已写明复制视频的临时拷贝方案，接手时不需要再向用户确认数值。

## 3. 任务清单

每项完成后补测试。测试只验证业务输入输出与状态，并写明用例目的和边界依据，不测下游调用。

### 3.1 修复截图工具栏动画重播与挤行（`lib/src/screenshot/screenshot_app.dart`）

1. **拖动后重播**
   - 原因：`_EditorSurface` 在 `widget.dragStart != null && !widget.textInputOpen` 时不挂载工具栏（搜索 `widget.dragStart == null || widget.textInputOpen`）。松手后 `LiquidSplit`、`BouncyPresence` 重新 `initState`，入场或收起动画从头再播。
   - 改法：始终挂载，改用 `Visibility(visible: …, maintainState: true, maintainAnimation: true)`。隐藏时不得接收点击。
2. **切换父级时新子级组被挤到第三行**
   - 原因：`_syncClosing` 在「换成别的父级」时也保留收起中的组，`_toolbarLines` 把它插在原父级行之后、新子级组之前。
   - 改法：只有收起后没有展开任何父级（`open == null`）时才记录 `_closing`；切换父级时旧组直接移除。
3. **测试**：在 `screenshot_controls_test.dart` 的「子级组从父级按钮液态展开…」用例旁补两个用例：
   - 切换父级时，新子级组紧跟新父级所在行。
   - 拖动选区并松手后，没有新的收起组，展开中的组也不再重新从父级位置开始。

### 3.2 截图编辑器去掉流光；区域录制边框流光（原生）

1. **Dart 侧**
   - 删除 `screenshot_app.dart` 中 `SelectionFlow` 的使用（`Positioned.fill(… SelectionFlow …)`）。
   - 删除 `app_motion.dart` 中的 `SelectionFlow`、`_SelectionFlowPainter`，以及 `motion_metrics.dart` 中的 `selectionFlow*` 常量。
   - 文档里相关描述一并删除，不留旧说法。
2. **Swift 侧**
   - 位置：`CaptureWindowController.swift` 的 `CaptureShadeView`。它在 `draw(_:)` 末尾用 `NSColor.controlAccentColor` 描选区边框。
   - 叠加一个 `CAShapeLayer`：
     - 路径为选区矩形；`lineDashPattern` 为 [周长×22%，周长×78%]；线宽 2pt。
     - `shadowColor` 用强调色，`shadowRadius` 4（外发光 8pt）。
     - 对 `lineDashPhase` 做 2.4s 无限循环。
   - 选区变化时更新路径和虚线长度。
   - 暂停与继续：把图层 `speed` 置 0，同时记录与恢复 `timeOffset`，让光段停在原处、继续时接着流。暂停状态取自现有的采集暂停流程。
   - 只用于区域录制（有 `contentRects` 的窗口录制不加）。
   - 开启「减少动态效果」（`NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`）时不添加图层。
   - 数值放进 `Constants.swift`。
3. **验证**：`RunnerTests` 只编译。实机验收由用户完成。

### 3.3 分段控件弹簧滑块（`native_glass.dart` 的 `NativeGlassSegments`）

1. 现状：每段各自绘制选中底色，切换时直接跳。
2. 改为一个共享选中底，位置和宽度都用 `SingleMotionBuilder` 加 `AppMotion.bouncy(context)` 驱动。做法参照同文件 `NativeGlassSidebar` 的选中滑块。
   - 各段宽度不等，需要测量各段的位置。
   - 选中段文字仍为白色。
3. 开启「减少动态效果」时直接切换。
4. 调用处共 6 处（设置外观、语言方向、贴纸面板、画笔颜色页签、历史分段、拼接对话框），不需要改调用方。
5. 测试：在 `native_glass_controls_test.dart` 补用例，切换后选中底的终点位置与选中段对齐。

### 3.4 等待进度环做进共享按钮层

1. **组件改造**
   - `BusyRing`（`app_motion.dart`）增加 `radius` 参数，现在固定为 `MotionMetrics.busyRingRadius`。
   - `NativeGlassSurface` 增加 `busy` 参数（bool，默认 false）。`material: true` 时内部始终包一层 `BusyRing(active: busy, radius: 按钮圆角 + 2)`，保证结构不随等待变化，原生材料不重建。
   - 截图工具栏 `button()` 里手写的 `BusyRing` 改为传 `busy:`。
2. **接入点**：要分清是哪个按钮发起的等待，只在那个按钮上显示进度环。

   | 窗口 | 等待标记 | 按钮 |
   | --- | --- | --- |
   | 录制结果 `capture_app.dart` | `_pending`；`converting` 与 `exporting` | 正在转换的那个导出按钮（转换中显示为「取消转换 / 取消保存」） |
   | 权限向导 `permission_wizard_app.dart` | `_busy` | 申请权限按钮 |
   | 术语表 `glossary_editor.dart` | `_working`（导入、导出）、`_saving` | 对应按钮 |
   | 历史 `history_app.dart` | `_savingRecording` | 保存录制按钮 |
   | 生词本 `vocabulary_page.dart` | `_exporting` | 导出按钮 |
   | 截图历史 `screenshot_history_page.dart` 与 `screenshot_compose_dialogs.dart` | 目前没有等待标记 | 拼接、拆分、比较 |

   截图历史这一行要先确认这些操作有没有可感知的等待；没有的话，向用户说明后不加。
3. **测试**：
   - 每类窗口挑一个用例，断言等待期间对应按钮的 `BusyRing.active` 为真、结束后为假。
   - 写法参考 `screenshot_app_test.dart` 的「等待中的功能按钮自身显示进度环…」。

### 3.5 设置页四项静态优化（数值见 #67 第 14 条）

1. **行间细线**
   - `NativeGlassGroup` 在设置行之间画 0.5pt 细线，与行文字左缘对齐。
   - 现有分组里夹着 `SizedBox` 间距和纯 `Text`，需要先在调用处（主要是 `settings_app.dart`）把它们整理成「行」，再统一由分组加线。
   - `settings_app.dart` 有 #143 的改动，提交时注意拆分。
2. **说明文字归位**
   - 把单独成段的长说明改为所属设置的 `caption`：`NativeGlassSettingRow.caption`，开关行用 `NativeGlassSwitchTile.subtitle`。
   - 例：通用页透明度下方「更改后自动保存并应用到所有窗口…」。逐页排查分组里独立的说明 `Text`。
3. **状态标签**
   - 新增共享组件（如 `NativeGlassStatus`），两种状态：已授权、未授权。
   - 替换通用页辅助功能、屏幕录制两行的「已授权 / 未授权」小字；权限向导中同类状态一并替换。
   - 颜色为固定语义色，不随强调色变化。
4. **侧边栏图标块**
   - `NativeGlassSidebar` 一级分组图标放进 22×22、圆角 6、强调色底的方块，图标为白色 12pt。
   - 选中条左右各留 6pt；子项缩进与图标块对齐。
   - 同步调整 `_selectedGeometry` 的位置计算，否则弹簧滑块会错位。
5. **测试**：
   - 状态标签：两种状态的文字与语义标签。
   - 分组：行数为 n 时有 n−1 条细线。
   - 侧边栏：选中滑块落点与选中行一致（`app_motion_test.dart` 已有侧边栏用例，可扩展）。

### 3.6 实时翻译盖层逐字显影（原生）

1. **位置**：`LiveRegionCoordinator.swift`。
   - `LiveFitTextView`（文件开头）负责绘制段落文字。
   - `LiveTextOverlay` 管理盖层。
   - `LiveRegionCoordinator` 在 `state["overlays"]` 处接收主引擎快照。
2. **规则与 Dart `CharReveal` 一致**（`app_motion.dart`）：
   - 文字在原内容后追加时，只显影新到达的字；内容被替换时，整段重新显影。
   - 单字 260ms，错峰 18ms，同段错峰总长不超过 600ms，模糊 3pt → 0。
3. **建议实现**
   - 每个 `LiveFitTextView` 记录已完整显示的字数和本批开始时间，用 `CADisplayLink` 或定时器在显影期间重画。
   - 绘制时按字生成属性串：前景色透明度取 t，「模糊」用同色 `NSShadow`（blurRadius = 3×(1−t)、偏移 0）近似。用户已同意用这种近似（2026-11-20）。
   - 字号按完整文字计算，显影过程中不改变排版。开启「减少动态效果」时直接显示。
   - 数值放进 `Constants.swift`。
4. **验证**：`RunnerTests` 补纯函数测试，例如「追加 / 替换时本批起点」的计算，只编译。

### 3.7 录制结果栏移到底部，并支持复制视频

1. **尺寸**（#67「采集工具与媒体结果」视频结果窗口一条）：
   - 上边距和左右边距 8pt；视频下方隔 8pt 是 48pt 厚的工具栏。
   - 工具栏长 356pt（8 个 32pt 按钮、7 个 12pt 间隔、两侧各 8pt），水平居中。
   - 媒体缩放：fit = min(1, (可用宽 − 16) / 媒体宽, (可用高 − 64) / 媒体高)。
   - 初始内容区：宽为 max(媒体宽 + 16, 356)，高为媒体高 + 64。
   - 最小内容区：356×65。
2. **Dart（`capture_app.dart`，`build` 中 `actions` 与 `LayoutBuilder` 一段）**
   - 工具栏从右侧纵列改为视频下方、水平居中的横排。
   - 视频区预留底部 48pt 加 8pt 间隔。
   - 按钮顺序：播放视频、裁剪、复制视频（`content_copy`）、保存 MP4、导出 GIF、导出 APNG、导出 WebM、关闭当前采集。
   - 转换中的取消规则不变。
   - 窗口获得焦点时，⌘C 等同点「复制视频」；转换中与等待中不可用。
   - 成功后沿用现有反馈显示「已复制视频」，失败显示原生给出的原因。
3. **常量**：在 `method_names.dart` 和 `Constants.swift` 新增 `copyRecording`（`method_names.dart` 有 #143 改动，提交时拆分）。
4. **Swift（`CaptureWindowController.swift`）**
   - 在 `saveRecordingMethod` 一段旁处理 `copyRecording`。
   - 媒体源取 `service.recordingURL()`；已裁剪时取裁剪结果，与保存 MP4 用同一份来源，不转码。
   - 写剪贴板：`NSPasteboard.general.clearContents()` 后 `writeObjects([url as NSURL])`。
   - 剪贴板只保存文件引用，而采集临时文件在结束采集时会被清理，所以不能直接把临时文件放进剪贴板，要先拷一份：
     - 拷到 `NSTemporaryDirectory()` 下本应用的剪贴板子目录，文件名为「录屏-yyyyMMdd-HHmmss.mp4」，再把它的文件 URL 写入剪贴板。
     - 用户不需要选择位置；结果窗口关闭后仍可粘贴。
     - 下次启动应用时清空该子目录（#68 第 10 条）。
     - 不要只写视频数据：访达和多数聊天应用不会把它识别为文件。
   - 结果窗口尺寸：改 `resultFrame`（第 251 行起，`reservedWidth` 算法）和 `recordingResultMinimumSize`（第 429 行起），按第 1 条的数值实现。常量在 `Constants.swift` 中把 `captureResultToolbarWidth`、`captureResultToolbarHeight` 换成工具栏长度 356 和厚度 48，不保留旧值。
5. **测试**：
   - `capture_app_test.dart`：按钮顺序；⌘C 与按钮在转换中均不可用；复制成功后出现「已复制视频」。
   - 原生侧只编译。

## 4. 约束（照做）

1. 改代码前先更新受影响的规格；规格编辑按以下顺序做：
   1. 拉取，失败时重试。
   2. 确认文件大小超过阈值（#1、#67、#68 都在 60KB 以上）。
   3. 编辑，失败时重试。
   4. 回读并比对。
   
   `gh` 常出现 `Post …/graphql: EOF`，拉取失败时写回会清空正文。
2. 不运行 `xcodebuild test`。原生验证用 `xcodebuild build-for-testing -workspace macos/Runner.xcworkspace -scheme Runner -destination 'platform=macOS,arch=arm64'`。编译后删除 `~/Library/Developer/Xcode/DerivedData/Runner-haipzxkdudkfgggkmdoxpldvzioh/Build/Products/Debug/translate_app.app`。
3. 不要对 `lib/src/screenshot/screenshot_app.dart` 与 `lib/src/screenshot/edit_document.dart` 运行 `dart format`，其他改动文件可以格式化。
4. 通道名、方法名与键只放在 `common/constants` 和 `Constants.swift`。每个函数写明作用、参数与返回值；关键步骤加注释；文档只描述当前行为。
5. 所有动效在开启「减少动态效果」时降级。Flutter 侧动画必须有限时长（等待中的进度环除外），保证 `pumpAndSettle` 能收敛。
6. 提交信息用中文，一个提交只对应一个 Issue，结尾加 `Co-Authored-By`。显式暂存文件，不混入 #143。推送和打包都需要用户授权。
7. 不关闭 Issue；进度用评论和中文标签记录。不使用 computer-use，界面效果由用户实机验收。
