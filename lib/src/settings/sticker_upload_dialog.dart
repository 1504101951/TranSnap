import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../common/constants/drawing_metrics.dart';
import '../common/constants/glass_metrics.dart';
import '../common/widgets/native_glass.dart';
import '../screenshot/stickers.dart';

class StickerUploadDialog extends StatefulWidget {
  const StickerUploadDialog({
    super.key,
    required this.bytes,
    required this.pixelWidth,
    required this.pixelHeight,
  });
  final Uint8List bytes;
  final int pixelWidth;
  final int pixelHeight;

  static final previewScale = math.min(
    (StickerMetrics.previewWidth - 24) / StickerMetrics.maxDefaultSize,
    (StickerMetrics.previewHeight - 24) / StickerMetrics.maxDefaultSize,
  );

  @override
  State<StickerUploadDialog> createState() => _StickerUploadDialogState();
}

class _StickerUploadDialogState extends State<StickerUploadDialog> {
  late (double, double) _size = initialStickerSize(
    widget.pixelWidth,
    widget.pixelHeight,
  );

  void _setLongSide(double targetLong) {
    final (width, height) = _size;
    final currentLong = math.max(width, height);
    if (currentLong <= 0) return;
    final clamped = targetLong.clamp(16.0, StickerMetrics.maxDefaultSize);
    final ratio = clamped / currentLong;
    setState(() => _size = (width * ratio, height * ratio));
  }

  void _drag(Offset local) {
    final scale = StickerUploadDialog.previewScale;
    final center = const Offset(
      StickerMetrics.previewWidth / 2,
      StickerMetrics.previewHeight / 2,
    );
    final (width, height) = _size;
    final factor = math.max(
      (local.dx - center.dx).abs() * 2 / (width * scale),
      (local.dy - center.dy).abs() * 2 / (height * scale),
    );
    _setLongSide(math.max(width, height) * factor);
  }

  @override
  Widget build(BuildContext context) {
    final scale = StickerUploadDialog.previewScale;
    final (width, height) = _size;
    final shown = Size(width * scale, height * scale);
    final rect = Rect.fromCenter(
      center: const Offset(
        StickerMetrics.previewWidth / 2,
        StickerMetrics.previewHeight / 2,
      ),
      width: shown.width,
      height: shown.height,
    );
    final dark = Theme.of(context).brightness == Brightness.dark;
    final handleOffset = GlassMetrics.minTouchTarget / 2;
    return NativeGlassDialog(
      title: const Text('添加贴纸'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Center(
              child: SizedBox(
                key: _previewKey,
                width: StickerMetrics.previewWidth,
                height: StickerMetrics.previewHeight,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: CustomPaint(painter: _CheckerPainter(dark: dark)),
                    ),
                    Positioned.fromRect(
                      rect: rect,
                      child: Image.memory(widget.bytes, fit: BoxFit.fill),
                    ),
                    for (final (index, corner) in [
                      rect.topLeft,
                      rect.topRight,
                      rect.bottomLeft,
                      rect.bottomRight,
                    ].indexed)
                      Positioned(
                        left: corner.dx - handleOffset,
                        top: corner.dy - handleOffset,
                        child: GestureDetector(
                          key: ValueKey('sticker-handle-$index'),
                          behavior: HitTestBehavior.opaque,
                          onPanUpdate: (details) =>
                              _drag(_previewLocal(details.globalPosition)),
                          child: SizedBox(
                            width: GlassMetrics.minTouchTarget,
                            height: GlassMetrics.minTouchTarget,
                            child: Center(
                              child: Container(
                                width: 12,
                                height: 12,
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  border: Border.all(
                                    color: NativeGlassTheme.accentOf(context),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: GlassMetrics.space12),
            Row(
              children: [
                Text('默认长边', style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(width: GlassMetrics.space8),
                Expanded(
                  child: Semantics(
                    label: '贴纸默认长边尺寸',
                    child: Slider(
                      value: math
                          .max(width, height)
                          .clamp(16.0, StickerMetrics.maxDefaultSize),
                      min: 16.0,
                      max: StickerMetrics.maxDefaultSize,
                      onChanged: _setLongSide,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: GlassMetrics.space4),
            Text(
              '拖动四角设置默认大小（长边最大 512pt）',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            Text(
              '默认大小 ${width.round()} × ${height.round()} pt',
              key: const ValueKey('sticker-size'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        NativeGlassSurface(
          material: true,
          child: TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
        ),
        NativeGlassSurface(
          material: true,
          child: FilledButton(
            onPressed: () => Navigator.pop(context, _size),
            child: const Text('添加'),
          ),
        ),
      ],
    );
  }

  final _previewKey = GlobalKey();

  Offset _previewLocal(Offset global) =>
      (_previewKey.currentContext!.findRenderObject() as RenderBox)
          .globalToLocal(global);
}

class _CheckerPainter extends CustomPainter {
  const _CheckerPainter({required this.dark});

  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    const cell = StickerMetrics.checker;
    final lightSquare = dark ? const Color(0xFF2C2C2E) : Colors.white;
    final altSquare = dark ? const Color(0xFF3A3A3C) : const Color(0xFFE5E5E5);
    canvas.drawRect(Offset.zero & size, Paint()..color = lightSquare);
    final altPaint = Paint()..color = altSquare;
    for (var y = 0; y * cell < size.height; y++) {
      for (var x = 0; x * cell < size.width; x++) {
        if ((x + y).isOdd) {
          canvas.drawRect(
            Rect.fromLTWH(x * cell, y * cell, cell, cell),
            altPaint,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(_CheckerPainter oldDelegate) => oldDelegate.dark != dark;
}
