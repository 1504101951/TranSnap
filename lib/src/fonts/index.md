# lib/src/fonts目录索引

界面字体组合的状态、注册与下载管理。

1. [font_state.dart](font_state.dart)：已下载字体文件与当前下载进度的状态模型，经外观快照在各引擎间同步。
2. [font_registry.dart](font_registry.dart)：在当前引擎内用 FontLoader 注册所选组合中已下载的字体文件，文件缺失时返回失败以便退回内置组合。
3. [font_library.dart](font_library.dart)：主引擎字体模块：启动时扫描与校验字体目录，按文件下载并以 SHA-256 校验后原子移入，支持取消与卸载，并发布字体状态。
4. [index.md](index.md)：索引本目录直接子文件的用途。
