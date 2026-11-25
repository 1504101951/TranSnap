import '../common/constants/method_names.dart';
import '../common/constants/bridge_event_types.dart';

sealed class PlatformEvent {
  const PlatformEvent({required this.sessionId});

  final String sessionId;

  factory PlatformEvent.fromMap(Map<Object?, Object?> map) {
    final type = map['type'] as String;
    final sessionId = map['sessionId'] as String;
    switch (type) {
      case BridgeEventTypes.selectionCaptured:
        return SelectionCaptured(
          sessionId: sessionId,
          text: map['text'] as String,
          gesture: map['gesture'] as String,
          readFailure: map['readFailure'] as String?,
          sourceAppName: map['sourceAppName'] as String?,
          x: (map['x'] as num).toDouble(),
          y: (map['y'] as num).toDouble(),
        );
      case BridgeEventTypes.selectionInvalidated:
        return SelectionInvalidated(sessionId: sessionId);
      case MethodNames.escapePressed:
        return EscapePressed(sessionId: sessionId);
      default:
        return UnknownBridgeEvent(sessionId: sessionId, type: type);
    }
  }
}

final class SelectionCaptured extends PlatformEvent {
  const SelectionCaptured({
    required super.sessionId,
    required this.text,
    required this.gesture,
    this.readFailure,
    required this.x,
    required this.y,
    this.sourceAppName,
  });

  final String text;
  final String gesture;

  final String? readFailure;
  final double x;
  final double y;

  final String? sourceAppName;
}

final class SelectionInvalidated extends PlatformEvent {
  const SelectionInvalidated({required super.sessionId});
}

final class EscapePressed extends PlatformEvent {
  const EscapePressed({required super.sessionId});
}

final class UnknownBridgeEvent extends PlatformEvent {
  const UnknownBridgeEvent({required super.sessionId, required this.type});

  final String type;
}
