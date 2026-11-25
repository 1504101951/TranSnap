import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transnap/src/common/constants/drawing_metrics.dart';
import 'package:transnap/src/screenshot/beautify.dart';
import 'package:transnap/src/screenshot/drawing_style.dart';
import 'package:transnap/src/screenshot/edit_document.dart';

import 'support/capture_pixels.dart';

Future<Uint8List> solidPng(int width, int height, Color color) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = color,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return bytes!.buffer.asUint8List();
}

Future<(int, int, Uint8List)> decode(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  final image = frame.image;
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final result = (image.width, image.height, data!.buffer.asUint8List());
  image.dispose();
  codec.dispose();
  return result;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const blue = Color(0xFF0000FF);

  (int, int, int) pixel((int, int, Uint8List) image, int x, int y) {
    final offset = (y * image.$1 + x) * 4;
    return (image.$3[offset], image.$3[offset + 1], image.$3[offset + 2]);
  }

  test('不美化时导出与原图逐像素一致', () async {
    final source = await solidPng(40, 30, blue);
    final doc = EditDocument()..loadCapture(await decodePng(source));
    final plain = await decode(await doc.renderPng(unit: 2));
    final original = await decode(source);
    expect((plain.$1, plain.$2), (40, 30));
    expect(plain.$3, original.$3);
  });

  test('美化按像素倍率扩出内边距，背景从首色开始，圆角外为背景，阴影只加深背景', () async {
    final source = await solidPng(40, 30, blue);
    final doc = EditDocument()..loadCapture(await decodePng(source));
    final preset = DrawingMetrics.gradients[1];
    final style = BeautifyStyle(
      background: (color: preset.from, gradient: FillGradient(end: preset.to)),
      padding: 10,
      cornerRadius: 6,
      shadow: false,
    );
    final framed = await decode(await doc.renderPng(beautify: style, unit: 2));
    expect((framed.$1, framed.$2), (80, 70));
    final start = preset.from;
    final corner = pixel(framed, 0, 0);
    expect((corner.$1 - (start.r * 255).round()).abs(), lessThan(4));
    expect((corner.$2 - (start.g * 255).round()).abs(), lessThan(4));
    expect(pixel(framed, 40, 35), (0, 0, 255));
    expect(pixel(framed, 20, 20).$2, greaterThan(100));
    final shadowed = await decode(
      await doc.renderPng(beautify: style.copyWith(shadow: true), unit: 2),
    );
    final below = pixel(framed, 40, 54);
    final belowShadow = pixel(shadowed, 40, 54);
    expect(
      belowShadow.$1 + belowShadow.$2 + belowShadow.$3,
      lessThan(below.$1 + below.$2 + below.$3),
    );
    expect(pixel(shadowed, 40, 35), (0, 0, 255));
  });
}
