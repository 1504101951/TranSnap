import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../common/constants/screenshot_enums.dart';
import '../common/utils/geometry.dart';
import 'beautify.dart';
import 'drawing_style.dart';
import '../common/constants/drawing_metrics.dart';

class EditAnnotation {
  EditAnnotation({
    required this.id,
    required this.kind,
    required this.bounds,
    this.start,
    this.end,
    this.points = const [],
    this.text = '',
    Color color = ScreenshotDefaults.strokeColor,
    double strokeWidth = 3,
    DrawingStyle? style,
    this.shapeMode = ShapeMode.solid,
    this.shape = ShapeVariant.rectangle,
    this.fontSize = ScreenshotDefaults.fontSize,
    this.rotation = 0,
    this.stickerId,
  }) : style = style ?? DrawingStyle(color: color, strokeWidth: strokeWidth);

  final double rotation;

  final String? stickerId;

  final String id;

  final AnnotationKind kind;
  final Rect bounds;
  final Offset? start;
  final Offset? end;
  final List<Offset> points;
  final String text;
  final DrawingStyle style;
  Color get color => style.color;
  double get strokeWidth => style.strokeWidth;
  final ShapeMode shapeMode;
  final ShapeVariant shape;
  final double fontSize;

  EditAnnotation copyWith({
    Rect? bounds,
    Offset? start,
    Offset? end,
    List<Offset>? points,
    String? text,
    Color? color,
    double? strokeWidth,
    double? fontSize,
    DrawingStyle? style,
    ShapeMode? shapeMode,
    ShapeVariant? shape,
    double? rotation,
  }) {
    return EditAnnotation(
      id: id,
      kind: kind,
      bounds: bounds ?? this.bounds,
      start: start ?? this.start,
      end: end ?? this.end,
      points: points ?? this.points,
      text: text ?? this.text,
      style:
          style ?? this.style.copyWith(color: color, strokeWidth: strokeWidth),
      shapeMode: shapeMode ?? this.shapeMode,
      shape: shape ?? this.shape,
      fontSize: fontSize ?? this.fontSize,
      rotation: rotation ?? this.rotation,
      stickerId: stickerId,
    );
  }
}

abstract class _EditCommand {
  void apply(EditDocument document);

  void revert(EditDocument document);
}

class _AddAnnotationCommand extends _EditCommand {
  _AddAnnotationCommand(this.annotation);

  final EditAnnotation annotation;

  @override
  void apply(EditDocument document) => document._annotations.add(annotation);

  @override
  void revert(EditDocument document) =>
      document._annotations.removeWhere((item) => item.id == annotation.id);
}

class _UpdateAnnotationCommand extends _EditCommand {
  _UpdateAnnotationCommand(this.before, this.after);

  final EditAnnotation before;
  final EditAnnotation after;

  @override
  void apply(EditDocument document) => document._replaceAnnotation(after);

  @override
  void revert(EditDocument document) => document._replaceAnnotation(before);
}

class _RemoveAnnotationCommand extends _EditCommand {
  _RemoveAnnotationCommand(this.annotation, this.index);

  final EditAnnotation annotation;
  final int index;

  @override
  void apply(EditDocument document) =>
      document._annotations.removeWhere((item) => item.id == annotation.id);

  @override
  void revert(EditDocument document) =>
      document._annotations.insert(index, annotation);
}

ui.Paragraph layoutTextBox({
  required String text,
  required double fontSize,
  required double width,
  Color color = const Color(0xFF000000),
  Paint? foreground,
}) {
  final builder =
      ui.ParagraphBuilder(ui.ParagraphStyle(fontSize: fontSize))
        ..pushStyle(
          ui.TextStyle(
            color: foreground == null ? color : null,
            foreground: foreground,
            fontSize: fontSize,
          ),
        )
        ..addText(text.isEmpty ? ' ' : text);
  return builder.build()
    ..layout(ui.ParagraphConstraints(width: width.clamp(1, 4000).toDouble()));
}

double textBoxHeight({
  required String text,
  required double fontSize,
  required double width,
}) => layoutTextBox(text: text, fontSize: fontSize, width: width).height;

Map<String, int> stepNumbers(Iterable<EditAnnotation> annotations) {
  var next = 0;
  return {
    for (final annotation in annotations)
      if (annotation.kind == AnnotationKind.step) annotation.id: ++next,
  };
}

class EditDocument extends ChangeNotifier {
  ui.Image? _source;
  int _width = 0;
  int _height = 0;
  final Map<String, ui.Image> stickerImages = {};
  Rect _crop = Rect.zero;
  final List<EditAnnotation> _annotations = <EditAnnotation>[];
  final List<_EditCommand> _undo = <_EditCommand>[];
  final List<_EditCommand> _redo = <_EditCommand>[];
  int _nextId = 0;

  ui.Image? get source => _source;

  int get width => _width;

  int get height => _height;

  Size get imageSize => Size(_width.toDouble(), _height.toDouble());

  Rect get cropRect => _crop;

  List<EditAnnotation>? _annotationsView;

  List<EditAnnotation> get annotations =>
      _annotationsView ??= List.unmodifiable(_annotations);

  @override
  void notifyListeners() {
    _annotationsView = null;
    super.notifyListeners();
  }

  bool get canUndo => _undo.isNotEmpty;

  bool get canRedo => _redo.isNotEmpty;

  bool get hasImage => _source != null;

  void loadCapture(ui.Image image) {
    _source?.dispose();
    _source = image;
    _width = image.width;
    _height = image.height;
    _crop = Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble());
    _annotations.clear();
    _undo.clear();
    _redo.clear();
    _nextId = 0;
    notifyListeners();
  }

  @override
  void dispose() {
    _source?.dispose();
    super.dispose();
  }

  void clear() {
    _source?.dispose();
    _source = null;
    _width = 0;
    _height = 0;
    _crop = Rect.zero;
    _annotations.clear();
    _undo.clear();
    _redo.clear();
    _nextId = 0;
    notifyListeners();
  }

  void setCrop(Rect crop) {
    if (!hasImage) return;
    final next = _clampCrop(crop);
    if (_nearlySameRect(next, _crop)) return;
    _crop = next;
    notifyListeners();
  }

  String addAnnotation(EditAnnotation annotation) {
    final withId = annotation.id.isEmpty
        ? EditAnnotation(
            id: _allocateId(),
            kind: annotation.kind,
            bounds: annotation.bounds,
            start: annotation.start,
            end: annotation.end,
            points: annotation.points,
            text: annotation.text,
            shapeMode: annotation.shapeMode,
            shape: annotation.shape,
            style: annotation.style,
            strokeWidth: annotation.strokeWidth,
            fontSize: annotation.fontSize,
            rotation: annotation.rotation,
            stickerId: annotation.stickerId,
          )
        : annotation;
    _push(_AddAnnotationCommand(withId));
    return withId.id;
  }

  void updateAnnotation(EditAnnotation annotation) {
    final index = _annotations.indexWhere((item) => item.id == annotation.id);
    if (index < 0) return;
    final before = _annotations[index];
    _push(_UpdateAnnotationCommand(before, annotation));
  }

  void removeAnnotation(String id) {
    final index = _annotations.indexWhere((item) => item.id == id);
    if (index < 0) return;
    _push(_RemoveAnnotationCommand(_annotations[index], index));
  }

  void undo() {
    if (_undo.isEmpty) return;
    final command = _undo.removeLast();
    command.revert(this);
    _redo.add(command);
    notifyListeners();
  }

  void redo() {
    if (_redo.isEmpty) return;
    final command = _redo.removeLast();
    command.apply(this);
    _undo.add(command);
    notifyListeners();
  }

  Future<Uint8List> renderPng({BeautifyStyle? beautify, double unit = 1}) async {
    final source = _source;
    if (source == null) {
      throw StateError('没有可导出的截图');
    }
    final crop = _clampCrop(_crop);
    final outWidth = crop.width.round().clamp(1, _width);
    final outHeight = crop.height.round().clamp(1, _height);
    final srcRect = Rect.fromLTWH(
      crop.left.roundToDouble(),
      crop.top.roundToDouble(),
      outWidth.toDouble(),
      outHeight.toDouble(),
    );
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final dst = Rect.fromLTWH(0, 0, outWidth.toDouble(), outHeight.toDouble());
    canvas.drawImageRect(
      source,
      srcRect,
      dst,
      Paint()..filterQuality = ui.FilterQuality.none,
    );
    canvas.save();
    canvas.clipRect(dst);
    canvas.translate(-srcRect.left, -srcRect.top);
    final numbers = stepNumbers(_annotations);
    for (final annotation in _annotations) {
      if (beautify != null && annotation.kind == AnnotationKind.sticker) {
        continue;
      }
      paintAnnotation(
        canvas,
        annotation,
        sourceImage: source,
        stepNumber: numbers[annotation.id],
        stickers: stickerImages,
      );
    }
    canvas.restore();
    final content = recorder.endRecording();
    final padding = beautify == null ? 0 : (beautify.padding * unit).round();
    final picture = beautify == null
        ? content
        : _beautified(
            content,
            outWidth,
            outHeight,
            padding,
            beautify,
            unit,
            stickers: [
              for (final annotation in _annotations)
                if (annotation.kind == AnnotationKind.sticker) annotation,
            ],
            stickerImages: stickerImages,
            origin: Offset(
              padding - srcRect.left,
              padding - srcRect.top,
            ),
          );
    final image = await picture.toImage(
      outWidth + padding * 2,
      outHeight + padding * 2,
    );
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (!identical(picture, content)) picture.dispose();
    content.dispose();
    if (data == null) throw StateError('无法编码截图 PNG');
    return data.buffer.asUint8List();
  }

  static ui.Picture _beautified(
    ui.Picture content,
    int width,
    int height,
    int padding,
    BeautifyStyle style,
    double unit, {
    required List<EditAnnotation> stickers,
    required Map<String, ui.Image> stickerImages,
    required Offset origin,
  }) {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final area = Rect.fromLTWH(
      padding.toDouble(),
      padding.toDouble(),
      width.toDouble(),
      height.toDouble(),
    );
    paintBeautifyBackdrop(canvas, area, style, unit: unit);
    canvas.save();
    canvas.clipRRect(
      RRect.fromRectAndRadius(area, Radius.circular(style.cornerRadius * unit)),
    );
    canvas.translate(area.left, area.top);
    canvas.drawPicture(content);
    canvas.restore();
    canvas.save();
    canvas.translate(origin.dx, origin.dy);
    for (final sticker in stickers) {
      paintAnnotation(canvas, sticker, stickers: stickerImages);
    }
    canvas.restore();
    return recorder.endRecording();
  }

  static void paintAnnotation(
    Canvas canvas,
    EditAnnotation annotation, {
    ui.Image? sourceImage,
    int? stepNumber,
    Map<String, ui.Image> stickers = const {},
  }) {
    _paintAnnotation(
      canvas,
      annotation,
      sourceImage: sourceImage,
      stepNumber: stepNumber,
      stickers: stickers,
    );
  }

  void _push(_EditCommand command) {
    command.apply(this);
    _undo.add(command);
    _redo.clear();
    notifyListeners();
  }

  void _replaceAnnotation(EditAnnotation annotation) {
    final index = _annotations.indexWhere((item) => item.id == annotation.id);
    if (index < 0) return;
    _annotations[index] = annotation;
  }

  String _allocateId() {
    _nextId += 1;
    return 'a$_nextId';
  }

  Rect _clampCrop(Rect crop) {
    final left = crop.left.clamp(0, _width.toDouble()).toDouble();
    final top = crop.top.clamp(0, _height.toDouble()).toDouble();
    final right = crop.right.clamp(left + 1, _width.toDouble()).toDouble();
    final bottom = crop.bottom.clamp(top + 1, _height.toDouble()).toDouble();
    return Rect.fromLTRB(left, top, right, bottom);
  }

  static bool _nearlySameRect(Rect a, Rect b) {
    return (a.left - b.left).abs() < 0.5 &&
        (a.top - b.top).abs() < 0.5 &&
        (a.right - b.right).abs() < 0.5 &&
        (a.bottom - b.bottom).abs() < 0.5;
  }

  static final Expando<ui.Image> _mosaicImages = Expando();

  static void _paintMosaic(
    Canvas canvas,
    ui.Image source,
    Path clip,
    Rect bounds,
  ) {
    final sourceRect = Rect.fromLTWH(
      0,
      0,
      source.width.toDouble(),
      source.height.toDouble(),
    );
    final area = bounds.intersect(sourceRect);
    if (area.isEmpty) return;
    const block = DrawingMetrics.mosaicPixels;
    final region = Rect.fromLTRB(
      (area.left / block).floor() * block,
      (area.top / block).floor() * block,
      math.min((area.right / block).ceil() * block, sourceRect.right),
      math.min((area.bottom / block).ceil() * block, sourceRect.bottom),
    );
    final tiles = _mosaicImages[source] ??= _rasterMosaic(source, sourceRect, block);
    canvas.save();
    canvas.clipPath(clip);
    canvas.drawImageRect(
      tiles,
      region,
      region,
      Paint()
        ..filterQuality = FilterQuality.none
        ..isAntiAlias = false,
    );
    canvas.restore();
  }

  static ui.Image _rasterMosaic(ui.Image source, Rect region, double block) {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final paint = Paint()
      ..filterQuality = FilterQuality.none
      ..isAntiAlias = false;
    for (var y = region.top; y < region.bottom; y += block) {
      for (var x = region.left; x < region.right; x += block) {
        final tile = Rect.fromLTWH(x, y, block, block).intersect(region);
        canvas.drawImageRect(
          source,
          Rect.fromLTWH(
            tile.center.dx.floorToDouble(),
            tile.center.dy.floorToDouble(),
            1,
            1,
          ),
          tile.shift(-region.topLeft),
          paint,
        );
      }
    }
    final picture = recorder.endRecording();
    final image = picture.toImageSync(
      region.width.toInt(),
      region.height.toInt(),
    );
    picture.dispose();
    return image;
  }

  static ui.Paragraph _stepLabel(String text, double fontSize, Color color) {
    final builder =
        ui.ParagraphBuilder(
            ui.ParagraphStyle(fontSize: fontSize, fontWeight: FontWeight.w700),
          )
          ..pushStyle(
            ui.TextStyle(
              color: color,
              fontSize: fontSize,
              fontWeight: FontWeight.w700,
            ),
          )
          ..addText(text);
    return builder.build()
      ..layout(const ui.ParagraphConstraints(width: double.infinity));
  }

  static Paint _fillPaint(
    EditAnnotation annotation,
    Rect bounds, {
    double opacity = 1,
  }) {
    final paint = Paint()
      ..color = annotation.color.withValues(alpha: opacity);
    final gradient = annotation.style.gradient;
    if (gradient != null) {
      paint.shader = gradient.shader(
        annotation.color,
        bounds,
        opacity: opacity,
      );
    }
    return paint;
  }

  static void _paintAnnotation(
    Canvas canvas,
    EditAnnotation annotation, {
    ui.Image? sourceImage,
    int? stepNumber,
    Map<String, ui.Image> stickers = const {},
  }) {
    switch (annotation.kind) {
      case AnnotationKind.sticker:
        final center = annotation.bounds.center;
        canvas.save();
        canvas.translate(center.dx, center.dy);
        canvas.rotate(annotation.rotation);
        canvas.translate(-center.dx, -center.dy);
        final id = annotation.stickerId;
        if (id != null) {
          final image = stickers[id]!;
          canvas.drawImageRect(
            image,
            Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
            annotation.bounds,
            Paint()..filterQuality = ui.FilterQuality.medium,
          );
        } else {
          _paintEmoji(canvas, annotation.text, annotation.bounds);
        }
        canvas.restore();
      case AnnotationKind.rectangle:
        final paint = _fillPaint(annotation, annotation.bounds)
          ..style = annotation.shape.filled
              ? PaintingStyle.fill
              : PaintingStyle.stroke
          ..strokeWidth = annotation.strokeWidth;
        if (annotation.shape.circular) {
          canvas.drawOval(annotation.bounds, paint);
        } else {
          canvas.drawRect(annotation.bounds, paint);
        }
      case AnnotationKind.mask:
        if (annotation.shapeMode == ShapeMode.solid) {
          canvas.drawRect(
            annotation.bounds,
            _fillPaint(annotation, annotation.bounds),
          );
        } else if (sourceImage != null) {
          _paintMosaic(
            canvas,
            sourceImage,
            Path()..addRect(annotation.bounds),
            annotation.bounds,
          );
        }
      case AnnotationKind.arrow:
        final start = annotation.start;
        final end = annotation.end;
        if (start == null || end == null) return;
        final arrowBounds = Rect.fromPoints(
          start,
          end,
        ).inflate(annotation.strokeWidth * 2 + 8);
        final paint = _fillPaint(annotation, arrowBounds)
          ..strokeWidth = annotation.strokeWidth
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..isAntiAlias = false;
        canvas.drawLine(start, end, paint);
        final direction = end - start;
        if (direction.distance < 1) return;
        final unit = direction / direction.distance;
        final tipSize = 8 + annotation.strokeWidth * 2;
        final left = end - unit * tipSize + _perp(unit) * (tipSize * 0.45);
        final right = end - unit * tipSize - _perp(unit) * (tipSize * 0.45);
        final tip = _fillPaint(annotation, arrowBounds)
          ..style = PaintingStyle.fill;
        final path = Path()
          ..moveTo(end.dx, end.dy)
          ..lineTo(left.dx, left.dy)
          ..lineTo(right.dx, right.dy)
          ..close();
        canvas.drawPath(path, tip);
      case AnnotationKind.stroke:
        if (annotation.points.length < 2) return;
        if (annotation.shapeMode == ShapeMode.mosaic) {
          if (sourceImage == null) return;
          final clip = Path();
          final radius = annotation.strokeWidth / 2;
          for (final point in annotation.points) {
            clip.addOval(Rect.fromCircle(center: point, radius: radius));
          }
          for (var i = 1; i < annotation.points.length; i++) {
            final a = annotation.points[i - 1], b = annotation.points[i];
            final delta = b - a;
            if (delta.distance == 0) continue;
            final normal =
                Offset(-delta.dy, delta.dx) / delta.distance * radius;
            clip.addPolygon([
              a + normal,
              a - normal,
              b - normal,
              b + normal,
            ], true);
          }
          _paintMosaic(canvas, sourceImage, clip, clip.getBounds());
          return;
        }
        final paint =
            _fillPaint(
                annotation,
                boundsForPoints(
                  annotation.points,
                ).inflate(annotation.strokeWidth / 2),
                opacity: annotation.shapeMode == ShapeMode.highlighter
                    ? DrawingMetrics.highlighterOpacity
                    : 1,
              )
              ..strokeWidth = annotation.strokeWidth
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..isAntiAlias = true;
        final path = Path()
          ..moveTo(annotation.points.first.dx, annotation.points.first.dy);
        for (final point in annotation.points.skip(1)) {
          path.lineTo(point.dx, point.dy);
        }
        canvas.drawPath(path, paint);
      case AnnotationKind.step:
        final diameter = annotation.bounds.width;
        canvas.drawCircle(
          annotation.bounds.center,
          diameter / 2,
          _fillPaint(annotation, annotation.bounds),
        );
        final digits =
            annotation.color.computeLuminance() >
                DrawingMetrics.stepLightThreshold
            ? const Color(0xFF000000)
            : const Color(0xFFFFFFFF);
        final fontSize = diameter * DrawingMetrics.stepFontRatio;
        final maxWidth = diameter * DrawingMetrics.stepTextMaxRatio;
        var label = _stepLabel('${stepNumber!}', fontSize, digits);
        if (label.maxIntrinsicWidth > maxWidth) {
          label = _stepLabel(
            '$stepNumber',
            fontSize * maxWidth / label.maxIntrinsicWidth,
            digits,
          );
        }
        canvas.drawParagraph(
          label,
          annotation.bounds.center -
              Offset(label.maxIntrinsicWidth / 2, label.height / 2),
        );
      case AnnotationKind.text:
        canvas.drawParagraph(
          layoutTextBox(
            text: annotation.text,
            fontSize: annotation.fontSize,
            width: annotation.bounds.width,
            color: annotation.color,
            foreground: annotation.style.gradient == null
                ? null
                : _fillPaint(annotation, annotation.bounds),
          ),
          annotation.bounds.topLeft,
        );
    }
  }

  static void _paintEmoji(Canvas canvas, String emoji, Rect bounds) {
    final paragraph =
        (ui.ParagraphBuilder(ui.ParagraphStyle(fontSize: bounds.height))
              ..pushStyle(ui.TextStyle(fontSize: bounds.height))
              ..addText(emoji))
            .build()
          ..layout(const ui.ParagraphConstraints(width: double.infinity));
    final size = Size(paragraph.maxIntrinsicWidth, paragraph.height);
    if (size.isEmpty) return;
    final scale = math.min(bounds.width / size.width, bounds.height / size.height);
    canvas.save();
    canvas.translate(bounds.center.dx, bounds.center.dy);
    canvas.scale(scale);
    canvas.drawParagraph(paragraph, Offset(-size.width / 2, -size.height / 2));
    canvas.restore();
  }

  static Offset _perp(Offset unit) => Offset(-unit.dy, unit.dx);
}
