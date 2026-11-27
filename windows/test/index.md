# windows/test目录索引

Windows 原生代码的 GoogleTest 单元测试，由 CI 在 Flutter Windows 构建后编译运行。

1. [CMakeLists.txt](CMakeLists.txt)：拉取 GoogleTest，编译被测的 runner 源文件与测试并注册到 CTest。
2. [index.md](index.md)：索引本目录直接子文件和子目录的用途。
3. [json_codec_test.cpp](json_codec_test.cpp)：验证 JSON 编解码保留整数与小数类型、转义与代理对解码，以及拒绝格式错误的文档。
4. [key_names_test.cpp](key_names_test.cpp)：验证扩展标志区分导航键与小键盘键、未知扫描码无键名、键名与扫描码互逆、修饰键按协议顺序，以及只有单独 Ctrl+A 上报为 SelectAll。
5. [language_detection_test.cpp](language_detection_test.cpp)：验证系统语言检测返回不带置信度的候选（法语文本首位为 fr），以及简体、繁体中文文本各自报告转换后不变的书写体系。
6. [preferences_store_test.cpp](preferences_store_test.cpp)：验证偏好文件缺失时为空、保存后读回相同内容并不留临时文件，以及格式错误或非对象文件报错。
7. [selection_context_test.cpp](selection_context_test.cpp)：验证 Chromium 与 Gecko 文档归为网页内容、各控件类型归入文本、非文本或其他，以及最近的文本或非文本祖先决定是否读取。
8. [text_file_test.cpp](text_file_test.cpp)：验证文本原子写入后读回相同内容且不留临时文件、空文件读为空文本、非 UTF-8 文件报错以及文件缺失报告读取失败。
9. [tooltip_layout_test.cpp](tooltip_layout_test.cpp)：验证提示气泡优先在上方并水平居中、上方超出内缩区域时改到下方、偏好下方时贴近底边改到上方、水平夹取到内缩区域，以及内缩与间距随显示缩放放大；边界取 6pt 内缩与 6pt 间距。
