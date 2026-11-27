# windows/flutter目录索引

Flutter 引擎构建配置与插件注册入口。

1. [CMakeLists.txt](CMakeLists.txt)：引入 Flutter 工具生成的引擎库、头文件与 C++ 封装。
2. [generated_plugin_registrant.cc](generated_plugin_registrant.cc)：注册 Flutter 工具根据依赖生成的 Windows 插件。
3. [generated_plugin_registrant.h](generated_plugin_registrant.h)：声明 Windows 插件注册入口。
4. [generated_plugins.cmake](generated_plugins.cmake)：列出 Flutter 工具根据依赖生成的 Windows 插件构建目标。
5. [index.md](index.md)：索引本目录直接子文件和子目录的用途。
