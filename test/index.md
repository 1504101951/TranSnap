# test目录索引

Dart业务逻辑和Flutter界面行为回归测试。

1. [api_translation_provider_test.dart](api_translation_provider_test.dart)：验证官方翻译服务和模型适配的请求与响应契约、模型服务未填 API Key 时不带认证头，术语表命中与未命中时的请求内容，以及按思考开关的请求体：DeepSeek 发送 enabled 或 disabled、Anthropic 发送 2048 预算且最大输出不大于预算时连接前失败、OpenAI 官方不发送思考参数，以及服务菜单先列谷歌翻译与Apple系统翻译、Apple对应本机Provider且无润色Provider，以及预热地址跟随默认服务、Apple不预热。
2. [flutter_test_config.dart](flutter_test_config.dart)：统一初始化Flutter测试所需的运行配置。
3. [glass_appearance_test.dart](glass_appearance_test.dart)：验证玻璃主题和跨窗口外观设置。
4. [history_app_test.dart](history_app_test.dart)：验证历史筛选、单条删除与清空、期限确认及刷新/分页失败后的重试。
5. [history_channel_test.dart](history_channel_test.dart)：验证截图翻译与设置提交等待期间，历史分页和记录开关仍可独立完成。
6. [index.md](index.md)：索引本目录直接子文件和子目录的用途。
7. [language_direction_test.dart](language_direction_test.dart)：验证主要语言、次要语言及未知检测结果的翻译方向。
8. [platform_event_test.dart](platform_event_test.dart)：验证原生选区事件的解析与字段传递。
9. [native_glass_controls_test.dart](native_glass_controls_test.dart)：验证共享玻璃控件的输入、布局与命中行为。
10. [paragraph_translation_test.dart](paragraph_translation_test.dart)：验证段落结构、翻译配对与失败边界，以及按段落分批的上限、整片失败与同语言直通。
11. [permission_wizard_app_test.dart](permission_wizard_app_test.dart)：验证权限向导显示、状态刷新与完成行为。
12. [permission_wizard_test.dart](permission_wizard_test.dart)：验证两项权限齐备后的进入条件。
13. [screenshot_app_test.dart](screenshot_app_test.dart)：验证无屏幕权限的导入图片编辑、OCR/翻译及屏幕采集禁用，截图标注、导出与识别结果中的二维码、条码及链接打开行为，以及美化行背景调色盘、「无背景」与下拉可用状态，贴纸下拉框的 Emoji 段放置、两段「管理贴纸…」与下拉框高度不变，贴纸经美化子级放置、导出与 Delete 删除。
14. [screenshot_controls_test.dart](screenshot_controls_test.dart)：验证截图工具快捷键、选择、拉伸、方向键微调、固定比例及确认行为，以及常用与完整工具栏切换、再点回到光标和液态分裂动效。
15. [screenshot_toolbar_preferences_test.dart](screenshot_toolbar_preferences_test.dart)：验证截图工具栏网格与常用组的默认布局与格位快捷键、保存往返、旧配置重置、缺失功能补位、组合与格数校验、全局与系统快捷键的格位换算和互斥，以及网格编辑器的拖动交换、增删列、列顺序拖动、子级拖入拖出、隐藏与方向键移动和常用组与网格之间的移动、常用内交换与方向键排序。
16. [selection_history_test.dart](selection_history_test.dart)：验证选区翻译成功、失败和取消时的历史记录边界，以及输入翻译不显示卡片、替换成功结束会话与未替换原因交给失败气泡。
17. [selection_session_test.dart](selection_session_test.dart)：验证选区翻译生命周期、取消和状态变化，以及卡片服务菜单只影响本卡片、非模型服务的润色失败、输入翻译使用独立语言方向。
18. [settings_app_test.dart](settings_app_test.dart)：验证设置页面侧边栏切换子页与保留草稿、默认翻译服务含Apple系统翻译、通用页语言包状态、服务显示、术语表增删改、提示词弹窗的四个字段、恢复默认与空值校验、思考开关随提示词保存、翻译语言分段只改输入翻译一组、贴纸添加与删除、确认截图动作、长截图滚动方式及配置更新。
19. [settings_autosave_test.dart](settings_autosave_test.dart)：验证后台自动保存的串行、冲突和失败处理。
20. [settings_spec_test.dart](settings_spec_test.dart)：验证设置界面是否符合数值、密度与交互规格，含侧边栏固定、权限卡片下方的离线翻译语言入口和新建服务四类且不含Apple。
21. [settings_test.dart](settings_test.dart)：验证设置数据往返与配置校验，含模型服务 API Key 可留空、四种模式提示词的默认值和空值拒绝、思考开关缺省全关与往返，以及输入翻译语言的复制、隔离与往返，Apple系统翻译作为内置默认服务的校验，以及快捷键记录的往返、名称列表存储与组合校验。
22. [translation_history_test.dart](translation_history_test.dart)：验证翻译历史组合查询、时间边界、游标分页、期限确认与清理事务、删除及记录开关。
23. [translation_overlay_test.dart](translation_overlay_test.dart)：验证翻译按钮、双语结果与失败界面行为，以及服务菜单在润色模式只列模型服务。
24. [translation_resume_test.dart](translation_resume_test.dart)：验证分片失败恢复、进度保留及取消边界。
25. [unofficial_google_provider_test.dart](unofficial_google_provider_test.dart)：验证零配置Google翻译的解析、失败处理（含限流可重试）与单篇请求超时。

26. [drawing_style_test.dart](drawing_style_test.dart)：验证马赛克像素、样式隔离、撤销及调色盘与粗细的提交边界，以及调色盘渐变页签、渐变像素与渐变偏好往返。
27. [capture_app_test.dart](capture_app_test.dart)：验证录制目标与应用图标动态行、录制选项的保存与延时提交、倒计时状态气泡、安全区域布局和选择状态、长截图直启选区、四气泡暂停恢复与立即放弃、长图等比预览和原尺寸导出、视频内容区六个操作的布局、裁剪等待、GIF/APNG导出与按类型取消转换及工具栏外的一秒响应。
28. [settings_controller_test.dart](settings_controller_test.dart)：验证配置快照隔离、设置提交顺序、真实文件存储失败恢复、过期修订拒绝、录制选项保存与延时校验和Apple系统翻译语言包检查。
29. [live_region_session_test.dart](live_region_session_test.dart)：验证实时翻译的段落块缓存、批次调度、四类失败（含频率受限退避）、暂停恢复、迟到事件，以及目标语言段落中外文片段的译文盖板定位。
30. [live_block_cache_test.dart](live_block_cache_test.dart)：验证段落块缓存的预算淘汰、最近使用顺序和失败记录。
31. [numbered_batch_test.dart](numbered_batch_test.dart)：验证批次编号文本与流式输出按编号归属的边界。
32. [mcp_settings_page_test.dart](mcp_settings_page_test.dart)：验证设置 MCP 页的侧边栏行、开关自动保存、「允许操控电脑」依赖 MCP 开关的禁用与保存、helper 路径与配置复制、平台状态与按钮可用性、安装失败原文及删除二次确认。
33. [mcp_platforms_test.dart](mcp_platforms_test.dart)：用模拟 CLI 与临时主目录验证接入平台的检测、安装、重复安装、路径变化、删除、配置备份与隔离属性清除。
34. [markdown_view_test.dart](markdown_view_test.dart)：验证识别结果 Markdown 的块拆分、表格分隔行与转义竖线、块间距及宽表格横向滚动。
35. [apple_translation_provider_test.dart](apple_translation_provider_test.dart)：用假原生通道验证Apple系统翻译的段落配对、错误文案与类别及取消后的输出。
36. [vocabulary_test.dart](vocabulary_test.dart)：验证生词本的增改删、排序、CSV 转义与查词判定边界。
37. [vocabulary_page_test.dart](vocabulary_page_test.dart)：验证生词本分段的展示、删除、导出反馈与空列表状态。
38. [beautify_test.dart](beautify_test.dart)：按像素验证截图美化的导出尺寸、背景、圆角与阴影，以及不美化时与原图一致。
39. [screenshot_history_test.dart](screenshot_history_test.dart)：用内存SQLite与临时目录验证截图历史的默认关闭、同截图覆盖、100条与30天清理、缺失文件及拼接拆分结果的入库顺序。
40. [screenshot_history_page_test.dart](screenshot_history_page_test.dart)：验证截图历史分段的缺失文件只能删除、清空后的空状态、关闭记录提示，以及勾选决定拼接、拆分、比较可用性与结果反馈。
41. [glossary_test.dart](glossary_test.dart)：验证术语的整词与子串匹配、目标语言筛选、保留原文输出及偏好往返与重复校验。
42. [step_highlighter_test.dart](step_highlighter_test.dart)：验证步骤编号的顺序推导、撤销重做、数字颜色与缩小、连续单击放置，以及荧光笔的半透明叠加与默认样式。
43. [screenshot_measure_confirm_test.dart](screenshot_measure_confirm_test.dart)：验证截图编辑器取色复制源像素色值、标尺测量与不进入导出，以及确认截图动作。
44. [dictionary_definition_test.dart](dictionary_definition_test.dart)：验证词典释义按词条与音标、词性、义项、例句及分节标题拆行，汉语词典与未识别格式保留原文。
45. [box_transform_test.dart](box_transform_test.dart)：验证可拖动矩形的命中优先级、旋转后命中、移动限制、自由与比例拉伸、旋转吸附与旋转后拉伸保持对角。
46. [sticker_test.dart](sticker_test.dart)：按像素验证贴纸位图按范围绘制、旋转后的占位，开启美化时可画在背景留白区、不美化时裁到截图范围，以及贴纸默认大小的计算、往返与校验。
47. [support/](support/index.md)：测试共用夹具，提供测试图片解码与截图快照 BGRA 像素转换。
48. [date_text_test.dart](date_text_test.dart)：验证历史与生词本日期文本的补零。

49. [glossary_import_test.dart](glossary_import_test.dart)：验证术语文件预览、重复处理、整批拒绝、导出、串行保存与失败后取消不污染设置。
50. [translation_http_test.dart](translation_http_test.dart)：验证连接预热发送不含原文的 HEAD、后续翻译请求复用同一条连接，以及预热失败不抛出。
51. [app_motion_test.dart](app_motion_test.dart)：验证界面动效公共组件的无障碍降级、光学棱镜着色器回退、五组纯 Dart 矢量状态机及侧边栏物理弹簧滑块。
52. [toolbar_feedback_test.dart](toolbar_feedback_test.dart)：验证工具栏反馈气泡的错误语义图标、悬停保活回调、关闭按钮、极窄视口安全夹紧及 liveRegion 开关。
53. [settings_sub_editors_test.dart](settings_sub_editors_test.dart)：验证设置子编辑器（提示词、贴纸上传、翻译服务、术语管理）的表单布局、内联报错、忙碌状态与破坏性确认交互。
54. [line_icon_test.dart](line_icon_test.dart)：验证线性图标按显示尺寸选字重与换用常量图标的结果。
55. [result_window_test.dart](result_window_test.dart)：验证结果窗口上弹托盘三角按托盘实际宽度对准锚点。
56. [click_effect_player_test.dart](click_effect_player_test.dart)：验证录制点击特效播放器的时间轴映射、自动循环高亮、单一动作循环、暂停与减少动态效果时只播放一次。
57. [toolbar_layout_test.dart](toolbar_layout_test.dart)：验证截图工具栏行布局：收起与展开的分组、子级托盘缩进对准锚点、忙碌状态组的追加条件。
58. [foreign_terms_test.dart](foreign_terms_test.dart)：验证外文片段提取：两类目标语言的文字划分、相邻单词合并、排除规则，以及每处片段的起止偏移。
59. [platform_capabilities_test.dart](platform_capabilities_test.dart)：验证按平台能力列出内置服务与卡片服务菜单，以及能力为空时设置窗口隐藏截图、MCP、权限、语言包与录制点击特效入口。
60. [shortcut_tokens_test.dart](shortcut_tokens_test.dart)：验证快捷键记录拆分为键帽序列的顺序，以及修饰键名称与位的互转和快捷键记录的解析往返。
61. [font_sets_test.dart](font_sets_test.dart)：验证主题按界面、正文、标题角色使用所选字体组合，显式样式继承主题字体，日文、韩文、繁体中文正文回退系统字体，组合文件与缺失体积计算，偏好往返，以及外观快照中所选组合文件缺失时退回中性。
62. [font_library_test.dart](font_library_test.dart)：经本机 HTTP 服务验证字体下载的进度、校验通过后移入并切换、校验不符与下载失败的清理、取消与并发限制、卸载时保留其他组合需要的文件，以及启动时校验不符切回中性与残留临时文件清理。
