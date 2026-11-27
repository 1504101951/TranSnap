# lib/src/selection目录索引

选区翻译会话状态、取消和失败恢复。

1. [index.md](index.md)：索引本目录直接子文件和子目录的用途。
2. [selection_session.dart](selection_session.dart)：管理选区会话的激活、翻译、取消与失败重试。
3. [selection_translation_app.dart](selection_translation_app.dart)：连接选区事件、翻译浮层和完整成功后的历史记录。
4. [selection_context.dart](selection_context.dart)：按原生上报的四类选区上下文与读到的文本，判定是否复制兜底以及是否采用复制结果。
