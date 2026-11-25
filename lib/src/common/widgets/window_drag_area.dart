import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../constants/method_names.dart';

/// 通顶窗口标题栏带的拖动区（#67）：Flutter 视图盖住了系统标题栏，空白处按下拖动时
/// 请所属原生窗口执行 performDrag；子控件（分段、开关等）照常响应点击。
class WindowDragArea extends StatelessWidget {
  /// channel 为所在窗口引擎与原生窗口控制器之间的通道，child 为标题栏带内容（可为空白占位）。
  const WindowDragArea({super.key, required this.channel, required this.child});

  final MethodChannel channel;
  final Widget child;

  /// context 未使用；返回在空白处接收拖动手势、把拖动交给原生窗口的容器。
  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onPanStart: (_) => channel.invokeMethod<void>(MethodNames.startWindowDrag),
    child: child,
  );
}
