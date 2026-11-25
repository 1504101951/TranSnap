import 'dart:math' as math;
import 'dart:ui';

import '../common/utils/geometry.dart';

enum BoxHandle {
  nw,
  n,
  ne,
  e,
  se,
  s,
  sw,
  w,
  move,
  rotate;

  BoxHandle get widthOnly => this == n || this == s ? move : this;
}

class BoxFrame {
  const BoxFrame(this.rect, [this.rotation = 0]);
  final Rect rect;
  final double rotation;

  @override
  bool operator ==(Object other) =>
      other is BoxFrame && other.rect == rect && other.rotation == rotation;

  @override
  int get hashCode => Object.hash(rect, rotation);

  @override
  String toString() => 'BoxFrame($rect, $rotation)';
}

class BoxRules {
  const BoxRules({
    this.area,
    this.minSide = 0,
    this.ratio,
    this.keepRatio = false,
    this.snapRotation = false,
  });
  final Rect? area;
  final double minSide;
  final double? ratio;
  final bool keepRatio;
  final bool snapRotation;
}

const _rotationSnap = math.pi / 12;

Offset _rotate(Offset point, Offset center, double angle) {
  final dx = point.dx - center.dx;
  final dy = point.dy - center.dy;
  final cos = math.cos(angle);
  final sin = math.sin(angle);
  return Offset(
    center.dx + dx * cos - dy * sin,
    center.dy + dx * sin + dy * cos,
  );
}

Offset _local(BoxFrame frame, Offset point) =>
    _rotate(point, frame.rect.center, -frame.rotation);

BoxHandle? hitBoxHandle(
  BoxFrame frame,
  Offset point, {
  required double pad,
  double? edgePad,
  double? rotateDistance,
}) {
  final local = _local(frame, point);
  final rect = frame.rect;
  bool near(Offset target) =>
      (target.dx - local.dx).abs() <= pad &&
      (target.dy - local.dy).abs() <= pad;
  if (rotateDistance != null &&
      near(Offset(rect.center.dx, rect.top - rotateDistance))) {
    return BoxHandle.rotate;
  }
  final points = {
    BoxHandle.nw: rect.topLeft,
    BoxHandle.ne: rect.topRight,
    BoxHandle.sw: rect.bottomLeft,
    BoxHandle.se: rect.bottomRight,
    BoxHandle.n: rect.topCenter,
    BoxHandle.s: rect.bottomCenter,
    BoxHandle.w: rect.centerLeft,
    BoxHandle.e: rect.centerRight,
  };
  for (final entry in points.entries) {
    if (near(entry.value)) return entry.key;
  }
  final edge = edgePad ?? pad;
  final withinX = local.dx >= rect.left && local.dx <= rect.right;
  final withinY = local.dy >= rect.top && local.dy <= rect.bottom;
  if ((local.dy - rect.top).abs() <= edge && withinX) return BoxHandle.n;
  if ((local.dy - rect.bottom).abs() <= edge && withinX) return BoxHandle.s;
  if ((local.dx - rect.left).abs() <= edge && withinY) return BoxHandle.w;
  if ((local.dx - rect.right).abs() <= edge && withinY) return BoxHandle.e;
  if (rect.contains(local)) return BoxHandle.move;
  return null;
}

BoxFrame dragBox(
  BoxFrame start,
  BoxHandle handle, {
  required Offset from,
  required Offset to,
  required BoxRules rules,
}) {
  final rect = start.rect;
  if (handle == BoxHandle.move) {
    final next = rect.shift(to - from);
    final area = rules.area;
    if (area == null) return BoxFrame(next, start.rotation);
    return BoxFrame(
      Rect.fromLTWH(
        next.left
            .clamp(area.left, math.max(area.left, area.right - next.width))
            .toDouble(),
        next.top
            .clamp(area.top, math.max(area.top, area.bottom - next.height))
            .toDouble(),
        next.width,
        next.height,
      ),
      start.rotation,
    );
  }
  if (handle == BoxHandle.rotate) {
    final center = rect.center;
    final turned =
        start.rotation + (to - center).direction - (from - center).direction;
    return BoxFrame(
      rect,
      rules.snapRotation
          ? (turned / _rotationSnap).round() * _rotationSnap
          : turned,
    );
  }
  final point = _local(start, to);
  final ratio =
      rules.ratio ?? (rules.keepRatio ? rect.width / rect.height : null);
  final next = ratio == null
      ? _freeResize(rect, handle, point, rules.minSide)
      : _ratioResize(rect, handle, point, ratio, rules);
  if (start.rotation == 0) return BoxFrame(next, 0);
  final anchor = _opposite(rect, handle);
  final anchorNext = _opposite(next, handle);
  final world = _rotate(anchor, rect.center, start.rotation);
  final placed = _rotate(anchorNext, next.center, start.rotation);
  return BoxFrame(next.shift(world - placed), start.rotation);
}

Offset _opposite(Rect rect, BoxHandle handle) => switch (handle) {
  BoxHandle.nw => rect.bottomRight,
  BoxHandle.ne => rect.bottomLeft,
  BoxHandle.sw => rect.topRight,
  BoxHandle.se => rect.topLeft,
  BoxHandle.n => rect.bottomCenter,
  BoxHandle.s => rect.topCenter,
  BoxHandle.w => rect.centerRight,
  BoxHandle.e => rect.centerLeft,
  _ => rect.center,
};

Rect _freeResize(Rect rect, BoxHandle handle, Offset point, double minSide) {
  var left = rect.left;
  var top = rect.top;
  var right = rect.right;
  var bottom = rect.bottom;
  if (const {BoxHandle.nw, BoxHandle.w, BoxHandle.sw}.contains(handle)) {
    left = point.dx;
  }
  if (const {BoxHandle.ne, BoxHandle.e, BoxHandle.se}.contains(handle)) {
    right = point.dx;
  }
  if (const {BoxHandle.nw, BoxHandle.n, BoxHandle.ne}.contains(handle)) {
    top = point.dy;
  }
  if (const {BoxHandle.sw, BoxHandle.s, BoxHandle.se}.contains(handle)) {
    bottom = point.dy;
  }
  return Rect.fromLTRB(
    left <= right - minSide ? left : right - minSide,
    top <= bottom - minSide ? top : bottom - minSide,
    right,
    bottom,
  );
}

Rect _ratioResize(
  Rect rect,
  BoxHandle handle,
  Offset point,
  double ratio,
  BoxRules rules,
) {
  final (anchor, toward, byHeight) = switch (handle) {
    BoxHandle.nw => (rect.bottomRight, point, false),
    BoxHandle.ne => (rect.bottomLeft, point, false),
    BoxHandle.sw => (rect.topRight, point, false),
    BoxHandle.e => (rect.topLeft, Offset(point.dx, rect.bottom), false),
    BoxHandle.w => (rect.topRight, Offset(point.dx, rect.bottom), false),
    BoxHandle.s => (rect.topLeft, Offset(rect.right, point.dy), true),
    BoxHandle.n => (rect.bottomLeft, Offset(rect.right, point.dy), true),
    _ => (rect.topLeft, point, false),
  };
  final area = rules.area;
  if (area != null) {
    return ratioRect(
      anchor: anchor - area.topLeft,
      toward: toward - area.topLeft,
      ratio: ratio,
      byHeight: byHeight,
      bounds: area.size,
      minSide: rules.minSide,
    ).shift(area.topLeft);
  }
  final right = toward.dx >= anchor.dx;
  final down = toward.dy >= anchor.dy;
  var width = byHeight
      ? (toward.dy - anchor.dy).abs() * ratio
      : (toward.dx - anchor.dx).abs();
  width = math.max(width, rules.minSide * math.max(1, ratio));
  final height = width / ratio;
  return Rect.fromLTWH(
    right ? anchor.dx : anchor.dx - width,
    down ? anchor.dy : anchor.dy - height,
    width,
    height,
  );
}
