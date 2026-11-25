import 'package:flutter/services.dart';

import '../constants/method_names.dart';

class NativeBrushCursor extends MouseCursor {
  const NativeBrushCursor({
    required this.diameter,
    required this.color,
    required this.channel,
  });

  static const minimumDiameter = 6.0;
  final double diameter;
  final int? color;
  final MethodChannel channel;

  @override
  MouseCursorSession createSession(int device) =>
      _NativeBrushCursorSession(this, device);

  @override
  String get debugDescription => 'native-brush-$diameter-$color';

  @override
  bool operator ==(Object other) =>
      other is NativeBrushCursor &&
      other.diameter == diameter &&
      other.color == color &&
      other.channel.name == channel.name;

  @override
  int get hashCode => Object.hash(diameter, color, channel.name);
}

class _NativeBrushCursorSession extends MouseCursorSession {
  _NativeBrushCursorSession(NativeBrushCursor super.cursor, super.device);

  @override
  Future<void> activate() {
    final brush = cursor as NativeBrushCursor;
    return brush.channel.invokeMethod<void>(MethodNames.setBrushCursor, {
      'diameter': brush.diameter,
      'color': brush.color,
    });
  }

  @override
  void dispose() {}
}
