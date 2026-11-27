# windows/test目录索引

Windows 原生代码的 GoogleTest 单元测试，由 CI 在 Flutter Windows 构建后编译运行。

1. [CMakeLists.txt](CMakeLists.txt)：拉取 GoogleTest，编译被测的 runner 源文件与测试并注册到 CTest。
2. [index.md](index.md)：索引本目录直接子文件和子目录的用途。
3. [json_codec_test.cpp](json_codec_test.cpp)：验证 JSON 编解码保留整数与小数类型、转义与代理对解码，以及拒绝格式错误的文档。
4. [language_detection_test.cpp](language_detection_test.cpp)：验证系统语言检测返回不带置信度的候选（法语文本首位为 fr），以及简体、繁体中文文本各自报告转换后不变的书写体系。
5. [preferences_store_test.cpp](preferences_store_test.cpp)：验证偏好文件缺失时为空、保存后读回相同内容并不留临时文件，以及格式错误或非对象文件报错。
