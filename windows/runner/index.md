# windows/runner目录索引

Windows 应用入口、主窗口与可执行文件资源。

1. [resources/](resources/index.md)：可执行文件图标资源。
2. [CMakeLists.txt](CMakeLists.txt)：定义 Windows 可执行文件的源文件、编译选项与链接库。
3. [credentials.cpp](credentials.cpp)：以 Windows 凭据管理器读取、保存与删除翻译服务凭据。
4. [credentials.h](credentials.h)：声明凭据读取结果与读写接口。
5. [flutter_window.cpp](flutter_window.cpp)：在主窗口中承载 Flutter 引擎视图并转发窗口消息。
6. [flutter_window.h](flutter_window.h)：声明承载 Flutter 视图的主窗口。
7. [index.md](index.md)：索引本目录直接子文件和子目录的用途。
8. [json_codec.cpp](json_codec.cpp)：在 JSON 文本与 Flutter 通道值之间转换，保留整数与小数类型。
9. [json_codec.h](json_codec.h)：声明 JSON 解析与序列化接口。
10. [main.cpp](main.cpp)：Windows 应用入口：初始化 COM、创建主窗口并运行消息循环。
11. [preferences_store.cpp](preferences_store.cpp)：读取与原子写入偏好 JSON 文件，文件缺失时为空偏好，格式错误时报错。
12. [preferences_store.h](preferences_store.h)：声明偏好文件读写接口。
13. [protocol.h](protocol.h)：定义与 Dart 共用的通道名、方法名、错误码、偏好键及 Windows 数据位置。
14. [resource.h](resource.h)：定义资源脚本使用的资源编号。
15. [runner.exe.manifest](runner.exe.manifest)：声明每显示器 DPI 感知与支持的 Windows 版本。
16. [Runner.rc](Runner.rc)：声明可执行文件的图标、版本与产品信息。
17. [utils.cpp](utils.cpp)：控制台附加、命令行参数读取与 UTF-8、UTF-16 互转。
18. [utils.h](utils.h)：声明控制台、命令行参数与编码转换工具函数。
19. [win32_window.cpp](win32_window.cpp)：创建支持高 DPI 与深浅色标题栏的 Win32 窗口。
20. [win32_window.h](win32_window.h)：声明 Win32 窗口基类。
