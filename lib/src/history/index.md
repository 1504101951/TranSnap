# lib/src/history目录索引

翻译记录、生词本与截图历史的SQLite存储、分页与历史窗口。

1. [history_app.dart](history_app.dart)：展示历史卡片、搜索筛选、分页、刷新、删除、保留期限与记录开关，并以分段切换生词本与截图历史。
2. [history_empty_state.dart](history_empty_state.dart)：历史窗口三段共用的居中空状态组件，支持内嵌快捷键键帽。
3. [history_list_card.dart](history_list_card.dart)：历史与生词本共用的日期分组圆角卡片、悬停感知行容器与普通图标按钮。
4. [index.md](index.md)：索引本目录直接子文件和子目录的用途。
5. [translation_history.dart](translation_history.dart)：定义翻译记录并管理SQLite写入、组合游标查询、删除、保留期限与记录设置。
6. [history_requests.dart](history_requests.dart)：处理主引擎历史查询、删除、保留期限与记录开关请求，不依赖设置提交队列。
7. [vocabulary.dart](vocabulary.dart)：定义生词条目，管理生词本表的增改删、CSV 导出与历史窗口请求。
8. [vocabulary_page.dart](vocabulary_page.dart)：历史窗口的生词本分段，展示、删除生词并经保存面板导出 CSV。
9. [screenshot_history.dart](screenshot_history.dart)：定义截图历史记录，管理历史图片目录与SQLite元数据的写入、清理、删除及请求处理。
10. [screenshot_history_page.dart](screenshot_history_page.dart)：历史窗口的截图历史分段，展示缩略图并提供开关、勾选、打开、复制、在 Finder 中显示、删除及拼接、拆分与比较入口。
11. [screenshot_compose_dialogs.dart](screenshot_compose_dialogs.dart)：截图拼接方向、拆分段数与并排差异比较的弹窗。
