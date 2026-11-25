import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../constants/method_names.dart';

class WindowDragArea extends StatelessWidget {
  const WindowDragArea({super.key, required this.channel, required this.child});

  final MethodChannel channel;
  final Widget child;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onPanStart: (_) => channel.invokeMethod<void>(MethodNames.startWindowDrag),
    child: child,
  );
}
