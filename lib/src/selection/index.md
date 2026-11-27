# lib/src/selection目录索引

选区翻译会话状态、取消和失败恢复。

1. [index.md](index.md)：索引本目录直接子文件和子目录的用途。
2. [selection_session.dart](selection_session.dart)：管理选区会话的激活、翻译、取消与失败重试。
3. [selection_translation_app.dart](selection_translation_app.dart)：连接选区事件、翻译浮层和完整成功后的历史记录。
4. [selection_context.dart](selection_context.dart)：按原生上报的四类选区上下文与读到的文本，判定是否复制兜底以及是否采用复制结果。
5. [selection_gestures.dart](selection_gestures.dart)：按原生上报的指针按下与抬起（按下到抬起位移不小于 4pt 为拖选，否则按点击次数判定双击、三击）及按键逻辑键名识别划词手势。
6. [paste_target.dart](paste_target.dart)：按原生上报的焦点事实与可写输入框数量，判定输入翻译直接粘贴、先查找输入框、设焦点到唯一候选后粘贴或不粘贴。
