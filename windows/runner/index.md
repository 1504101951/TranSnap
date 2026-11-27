# windows/runner目录索引

Windows 应用入口、主窗口与可执行文件资源。

1. [resources/](resources/index.md)：可执行文件图标资源。
2. [auxiliary_window.cpp](auxiliary_window.cpp)：设置、翻译历史等附属窗口：每个窗口一个 Flutter 引擎，收到 windowReady 后显示，5 秒未就绪关闭并提示，Windows 11 22H2 及以上使用系统亚克力背景，重复打开合并为激活已有窗口，窗口请求本地处理或转给主引擎。
3. [auxiliary_window.h](auxiliary_window.h)：声明附属窗口及其入口点、标题、尺寸与刷新方法。
4. [clipboard.cpp](clipboard.cpp)：剪贴板全部格式的快照与还原、序号与 Unicode 文本读取，以及发送复制后 250ms 内每 20ms 检查一次、取得文本即还原原剪贴板的复制读取。
5. [clipboard.h](clipboard.h)：声明剪贴板快照、文本读取与复制读取接口。
6. [CMakeLists.txt](CMakeLists.txt)：定义 Windows 可执行文件的源文件、编译选项与链接库。
7. [credentials.cpp](credentials.cpp)：以 Windows 凭据管理器读取、保存与删除翻译服务凭据。
8. [credentials.h](credentials.h)：声明凭据读取结果与读写接口。
9. [file_dialogs.cpp](file_dialogs.cpp)：以系统文件对话框选择要导入的术语表（CSV、JSON）、要排除的应用程序（.exe，默认打开 Program Files）与导出保存位置，取消时不返回路径。
10. [file_dialogs.h](file_dialogs.h)：声明术语表打开、排除应用选择与保存位置选择接口。
11. [flutter_window.cpp](flutter_window.cpp)：以主窗口承载主引擎 Flutter 视图并作为浮层（点击不激活），启动主线程调度，创建主引擎平台通道、设置与翻译历史窗口及托盘图标并转发窗口消息。
12. [flutter_window.h](flutter_window.h)：声明承载 Flutter 视图的主窗口。
13. [index.md](index.md)：索引本目录直接子文件和子目录的用途。
14. [json_codec.cpp](json_codec.cpp)：在 JSON 文本与 Flutter 通道值之间转换，保留整数与小数类型。
15. [json_codec.h](json_codec.h)：声明 JSON 解析与序列化接口。
16. [key_names.cpp](key_names.cpp)：扫描码（扩展键带 0xE000）与协议逻辑键名（W3C 键码名）互查、修饰键名排序，以及 Ctrl+A 上报为 `SelectAll`。
17. [key_names.h](key_names.h)：声明键名互查、修饰键与选区键名接口。
18. [language_detection.cpp](language_detection.cpp)：以 Win32 扩展语言服务（ELS）返回至多 3 个不带置信度的候选语言，以及简繁转换后不变的中文书写体系。
19. [language_detection.h](language_detection.h)：声明候选语言识别接口。
20. [main.cpp](main.cpp)：Windows 应用入口：初始化 COM、创建主窗口并运行消息循环。
21. [main_thread.cpp](main_thread.cpp)：以消息专用窗口在主线程执行其他线程投递的任务与毫秒定时任务，并在后台线程（多线程套间）执行阻塞任务。
22. [main_thread.h](main_thread.h)：声明主线程调度、后台执行与消息窗口接口。
23. [overlay_window.cpp](overlay_window.cpp)：把主窗口设为不激活、置顶、不进任务栏的弹出窗口作为触发按钮与翻译卡片，在鼠标右下 8pt 处按会话显示并夹取到工作区内缩 8pt，调整尺寸保持左上角，按住左键时进入系统拖动；悬停提示气泡为点击穿透的圆角置顶窗口，12pt 文字、左右共 16pt 与上下共 8pt 内边距，深浅色与外观设置一致，浮层显示、隐藏、调整尺寸或拖动时收起。
24. [overlay_window.h](overlay_window.h)：声明浮层显示、隐藏、调整尺寸、拖动、命中判断与悬停提示接口。
25. [platform_bridge.cpp](platform_bridge.cpp)：主引擎平台通道：能力声明、设置读取与应用（偏好文件、凭据、登录时启动及失败回滚）、凭据查询、字体状态、外观快照与预览及向所有引擎广播、附属窗口请求转发、划词采集与保留结果、快捷键翻译的选区读取（密码框报 secureField）、浮层显示隐藏与尺寸拖动、浮层悬停提示、候选语言识别、朗读、术语表文件导入导出、排除应用选择（标识为可执行文件路径，名称取文件说明）、历史变化通知与事件流。
26. [platform_bridge.h](platform_bridge.h)：声明主引擎平台通道。
27. [preferences_store.cpp](preferences_store.cpp)：读取与原子写入偏好 JSON 文件，文件缺失时为空偏好，格式错误时报错。
28. [preferences_store.h](preferences_store.h)：声明偏好文件读写接口。
29. [protocol.h](protocol.h)：定义与 Dart 共用的通道名、方法名、错误码、偏好键及 Windows 数据位置。
30. [resource.h](resource.h)：定义资源脚本使用的资源编号。
31. [runner.exe.manifest](runner.exe.manifest)：声明每显示器 DPI 感知与支持的 Windows 版本。
32. [Runner.rc](Runner.rc)：声明可执行文件的图标、版本与产品信息。
33. [selection_capture.cpp](selection_capture.cpp)：划词采集：按手势读取来源应用选区（自动手势先等 80ms），经 Dart 决定复制兜底与是否采用复制结果，发出选区捕获与失效事件；跳过本应用与排除应用（按可执行文件路径），来源名取可执行文件的文件说明；前台应用切换、Esc 与按下鼠标使选区失效，展开卡片后保留结果；为快捷键翻译按会话读取来源选区（允许复制兜底）。
34. [selection_capture.h](selection_capture.h)：声明划词采集与其委托（请求 Dart、发送事件、自动模式、排除判断）。
35. [selection_context.cpp](selection_context.cpp)：把 UI Automation 控件类型归一为文本、非文本、网页内容（Chromium、Gecko 文档）、其他四类，并按最近的文本或非文本祖先决定是否读取选中文字。
36. [selection_context.h](selection_context.h)：声明选区上下文类别、祖先层数上限与判定接口。
37. [selection_monitor.cpp](selection_monitor.cpp)：低级鼠标与键盘钩子：左键按下与抬起附连击次数、逻辑坐标交给 Dart 判定划词手势，键盘选区键串行请求 Dart 并在同键抬起时采集；Esc 与按下鼠标使当前选区失效，忽略落在浮层内或本应用在前台时的鼠标手势与自身合成事件。
38. [selection_monitor.h](selection_monitor.h)：声明划词监控与其委托（请求 Dart、自动模式、采集、失效、选区校验）。
39. [speech_service.cpp](speech_service.cpp)：以 WinRT 语音合成朗读文字，按语言选择系统声音，同一段再次请求即停止。
40. [speech_service.h](speech_service.h)：声明朗读开关与停止接口。
41. [synthetic_input.cpp](synthetic_input.cpp)：发送带本应用标记的 Ctrl 组合键，先抬起仍按住的 Alt、Shift、Win，避免组合变形。
42. [synthetic_input.h](synthetic_input.h)：声明合成按键接口。
43. [text_file.cpp](text_file.cpp)：读取 UTF-8 文本文件（非 UTF-8 时报错）并以临时文件加改名原子写入。
44. [text_file.h](text_file.h)：声明文本文件读取与原子写入接口。
45. [tooltip_layout.cpp](tooltip_layout.cpp)：计算悬停提示气泡位置：优先放在锚点上方或下方 6pt，放不下时换到另一侧，水平居中于锚点并夹取到屏幕工作区内缩 6pt。
46. [tooltip_layout.h](tooltip_layout.h)：声明提示气泡布局接口。
47. [tray_icon.cpp](tray_icon.cpp)：通知区域托盘图标与菜单（设置…、翻译历史…、仅使用快捷键、退出），资源管理器重启后重新添加图标。
48. [tray_icon.h](tray_icon.h)：声明托盘图标与菜单动作。
49. [uia_selection.cpp](uia_selection.cpp)：以 UI Automation（连接与事务超时 1 秒）读取前台进程焦点控件及其祖先的选中文字，未读到时于 80ms、180ms 后重试；判断密码框、选区上下文与键盘手势是否可触发。
50. [uia_selection.h](uia_selection.h)：声明选区读取结果与读取、密码框、键盘触发判断接口。
51. [utils.cpp](utils.cpp)：控制台附加、命令行参数读取与 UTF-8、UTF-16 互转。
52. [utils.h](utils.h)：声明控制台、命令行参数与编码转换工具函数。
53. [win32_window.cpp](win32_window.cpp)：创建支持高 DPI 与深浅色标题栏的 Win32 窗口。
54. [win32_window.h](win32_window.h)：声明 Win32 窗口基类。
55. [windows_system.cpp](windows_system.cpp)：取得应用数据目录、系统语言、强调色与深浅色，判断并为窗口应用系统亚克力背景，在屏幕像素坐标与所在显示器的逻辑坐标间换算，读写登录时启动项，取得进程可执行文件路径与文件说明，并显示警告与启动失败提示。
56. [windows_system.h](windows_system.h)：声明 Windows 系统信息与登录时启动接口。
