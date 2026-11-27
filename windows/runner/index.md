# windows/runner目录索引

Windows 应用入口、主窗口与可执行文件资源。

1. [resources/](resources/index.md)：可执行文件图标资源。
2. [CMakeLists.txt](CMakeLists.txt)：定义 Windows 可执行文件的源文件、编译选项与链接库。
3. [Runner.rc](Runner.rc)：声明可执行文件的图标、版本与产品信息。
4. [flutter_window.cpp](flutter_window.cpp)：在主窗口中承载 Flutter 引擎视图并转发窗口消息。
5. [flutter_window.h](flutter_window.h)：声明承载 Flutter 视图的主窗口。
6. [index.md](index.md)：索引本目录直接子文件和子目录的用途。
7. [main.cpp](main.cpp)：Windows 应用入口：初始化 COM、创建主窗口并运行消息循环。
8. [resource.h](resource.h)：定义资源脚本使用的资源编号。
9. [runner.exe.manifest](runner.exe.manifest)：声明每显示器 DPI 感知与支持的 Windows 版本。
10. [utils.cpp](utils.cpp)：控制台附加与命令行参数的 UTF-8 转换。
11. [utils.h](utils.h)：声明控制台与命令行参数工具函数。
12. [win32_window.cpp](win32_window.cpp)：创建支持高 DPI 与深浅色标题栏的 Win32 窗口。
13. [win32_window.h](win32_window.h)：声明 Win32 窗口基类。
