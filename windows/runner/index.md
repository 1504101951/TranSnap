# windows/runner目录索引

Windows 应用入口、主窗口与可执行文件资源。

1. [resources/](resources/index.md)：可执行文件图标资源。
2. [auxiliary_window.cpp](auxiliary_window.cpp)：设置、翻译历史等附属窗口：每个窗口一个 Flutter 引擎，收到 windowReady 后显示，5 秒未就绪关闭并提示，Windows 11 22H2 及以上使用系统亚克力背景，重复打开合并为激活已有窗口，窗口请求本地处理或转给主引擎。
3. [auxiliary_window.h](auxiliary_window.h)：声明附属窗口及其入口点、标题、尺寸与刷新方法。
4. [CMakeLists.txt](CMakeLists.txt)：定义 Windows 可执行文件的源文件、编译选项与链接库。
5. [credentials.cpp](credentials.cpp)：以 Windows 凭据管理器读取、保存与删除翻译服务凭据。
6. [credentials.h](credentials.h)：声明凭据读取结果与读写接口。
7. [file_dialogs.cpp](file_dialogs.cpp)：以系统文件对话框选择要导入的术语表（CSV、JSON）与导出保存位置，取消时不返回路径。
8. [file_dialogs.h](file_dialogs.h)：声明术语表打开与保存位置选择接口。
9. [flutter_window.cpp](flutter_window.cpp)：以隐藏主窗口承载主引擎 Flutter 视图，创建主引擎平台通道、设置与翻译历史窗口及托盘图标并转发窗口消息。
10. [flutter_window.h](flutter_window.h)：声明承载 Flutter 视图的主窗口。
11. [index.md](index.md)：索引本目录直接子文件和子目录的用途。
12. [json_codec.cpp](json_codec.cpp)：在 JSON 文本与 Flutter 通道值之间转换，保留整数与小数类型。
13. [json_codec.h](json_codec.h)：声明 JSON 解析与序列化接口。
14. [language_detection.cpp](language_detection.cpp)：以 Win32 扩展语言服务（ELS）返回至多 3 个不带置信度的候选语言，以及简繁转换后不变的中文书写体系。
15. [language_detection.h](language_detection.h)：声明候选语言识别接口。
16. [main.cpp](main.cpp)：Windows 应用入口：初始化 COM、创建主窗口并运行消息循环。
17. [platform_bridge.cpp](platform_bridge.cpp)：主引擎平台通道：能力声明、设置读取与应用（偏好文件、凭据、登录时启动及失败回滚）、凭据查询、字体状态、外观快照与预览及向所有引擎广播、附属窗口请求转发、候选语言识别、朗读、术语表文件导入导出、历史变化通知与事件流。
18. [platform_bridge.h](platform_bridge.h)：声明主引擎平台通道。
19. [preferences_store.cpp](preferences_store.cpp)：读取与原子写入偏好 JSON 文件，文件缺失时为空偏好，格式错误时报错。
20. [preferences_store.h](preferences_store.h)：声明偏好文件读写接口。
21. [protocol.h](protocol.h)：定义与 Dart 共用的通道名、方法名、错误码、偏好键及 Windows 数据位置。
22. [resource.h](resource.h)：定义资源脚本使用的资源编号。
23. [runner.exe.manifest](runner.exe.manifest)：声明每显示器 DPI 感知与支持的 Windows 版本。
24. [Runner.rc](Runner.rc)：声明可执行文件的图标、版本与产品信息。
25. [speech_service.cpp](speech_service.cpp)：以 WinRT 语音合成朗读文字，按语言选择系统声音，同一段再次请求即停止。
26. [speech_service.h](speech_service.h)：声明朗读开关与停止接口。
27. [text_file.cpp](text_file.cpp)：读取 UTF-8 文本文件（非 UTF-8 时报错）并以临时文件加改名原子写入。
28. [text_file.h](text_file.h)：声明文本文件读取与原子写入接口。
29. [tray_icon.cpp](tray_icon.cpp)：通知区域托盘图标与菜单（设置…、翻译历史…、仅使用快捷键、退出），资源管理器重启后重新添加图标。
30. [tray_icon.h](tray_icon.h)：声明托盘图标与菜单动作。
31. [utils.cpp](utils.cpp)：控制台附加、命令行参数读取与 UTF-8、UTF-16 互转。
32. [utils.h](utils.h)：声明控制台、命令行参数与编码转换工具函数。
33. [win32_window.cpp](win32_window.cpp)：创建支持高 DPI 与深浅色标题栏的 Win32 窗口。
34. [win32_window.h](win32_window.h)：声明 Win32 窗口基类。
35. [windows_system.cpp](windows_system.cpp)：取得应用数据目录、系统语言与强调色，判断并为窗口应用系统亚克力背景，读写登录时启动项，并显示警告与启动失败提示。
36. [windows_system.h](windows_system.h)：声明 Windows 系统信息与登录时启动接口。
