import 'dart:math' as math;
import 'dart:ui';

Rect boundsForPoints(List<Offset> points) {
  var minX = points.first.dx;
  var minY = points.first.dy;
  var maxX = minX;
  var maxY = minY;
  for (final point in points) {
    minX = minX < point.dx ? minX : point.dx;
    minY = minY < point.dy ? minY : point.dy;
    maxX = maxX > point.dx ? maxX : point.dx;
    maxY = maxY > point.dy ? maxY : point.dy;
  }
  return Rect.fromLTRB(
    minX,
    minY,
    maxX == minX ? minX + 1 : maxX,
    maxY == minY ? minY + 1 : maxY,
  );
}

Rect mapRectToFitted(Rect src, Size image, Rect fitted) {
  return Rect.fromLTRB(
    fitted.left + src.left / image.width * fitted.width,
    fitted.top + src.top / image.height * fitted.height,
    fitted.left + src.right / image.width * fitted.width,
    fitted.top + src.bottom / image.height * fitted.height,
  );
}

Offset pinOriginAppKit({
  required Rect crop,
  required Rect display,
  required Size image,
}) {
  final scaleX = display.width / image.width;
  final scaleY = display.height / image.height;
  return Offset(
    display.left + crop.left * scaleX,
    display.top + (image.height - crop.bottom) * scaleY,
  );
}

Rect ratioRect({
  required Offset anchor,
  required Offset toward,
  required double ratio,
  required bool byHeight,
  required Size bounds,
  required double minSide,
}) {
  final right = toward.dx >= anchor.dx;
  final down = toward.dy >= anchor.dy;
  var width = byHeight
      ? (toward.dy - anchor.dy).abs() * ratio
      : (toward.dx - anchor.dx).abs();
  width = math.max(width, minSide * math.max(1, ratio));
  width = math.min(
    width,
    math.min(
      right ? bounds.width - anchor.dx : anchor.dx,
      (down ? bounds.height - anchor.dy : anchor.dy) * ratio,
    ),
  );
  final height = width / ratio;
  return Rect.fromLTWH(
    right ? anchor.dx : anchor.dx - width,
    down ? anchor.dy : anchor.dy - height,
    width,
    height,
  );
}
