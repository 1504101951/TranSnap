import 'package:flutter/services.dart';

import '../constants/method_names.dart';

class NativeResizeCursor extends MouseCursor {
  const NativeResizeCursor(this.direction, {required this.channel});

  final String direction;
  final MethodChannel channel;

  @override
  MouseCursorSession createSession(int device) =>
      _NativeResizeCursorSession(this, device);

  @override
  String get debugDescription => 'native-resize-$direction';

  @override
  bool operator ==(Object other) =>
      other is NativeResizeCursor &&
      other.direction == direction &&
      other.channel.name == channel.name;

  @override
  int get hashCode => Object.hash(direction, channel.name);
}

class _NativeResizeCursorSession extends MouseCursorSession {
  _NativeResizeCursorSession(NativeResizeCursor super.cursor, super.device);

  @override
  Future<void> activate() {
    final resizeCursor = cursor as NativeResizeCursor;
    return resizeCursor.channel.invokeMethod<void>(
      MethodNames.setResizeCursor,
      {'direction': resizeCursor.direction},
    );
  }

  @override
  void dispose() {}
}
