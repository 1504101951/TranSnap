import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transnap/src/common/constants/screenshot_enums.dart';
import 'package:transnap/src/screenshot/beautify.dart';
import 'package:transnap/src/screenshot/edit_document.dart';
import 'package:transnap/src/screenshot/stickers.dart';
import 'package:transnap/src/settings/app_settings.dart';

Future<ui.Image> _solid(int width, int height, Color color) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawColor(color, BlendMode.src);
  return recorder.endRecording().toImage(width, height);
}

Future<(int, int, Uint8List)> _decode(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final image = (await codec.getNextFrame()).image;
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  return (image.width, image.height, data!.buffer.asUint8List());
}

(int, int, int) _pixel((int, int, Uint8List) decoded, int x, int y) {
  final offset = (y * decoded.$1 + x) * 4;
  return (decoded.$3[offset], decoded.$3[offset + 1], decoded.$3[offset + 2]);
}

void main() {
  const blue = Color(0xFF0000FF);
  const red = (255, 0, 0);

  Future<EditDocument> document(Rect bounds, {double rotation = 0}) async {
    final doc = EditDocument()..loadCapture(await _solid(48, 48, blue));
    doc.stickerImages['red'] = await _solid(10, 10, const Color(0xFFFF0000));
    doc.addAnnotation(
      EditAnnotation(
        id: '',
        kind: AnnotationKind.sticker,
        bounds: bounds,
        stickerId: 'red',
        rotation: rotation,
      ),
    );
    return doc;
  }

  test('贴纸位图画满 bounds，旋转 90° 后横条变为竖条', () async {
    const bounds = Rect.fromLTWH(14, 20, 20, 8);
    final flat = await _decode(await (await document(bounds)).renderPng());
    expect(_pixel(flat, 16, 24), red);
    expect(_pixel(flat, 24, 16), (0, 0, 255));
    final turned = await _decode(
      await (await document(bounds, rotation: math.pi / 2)).renderPng(),
    );
    expect(_pixel(turned, 24, 16), red);
    expect(_pixel(turned, 16, 24), (0, 0, 255));
  });

  test('开启美化时贴纸可画在背景留白区，不美化时选区外部分被裁掉', () async {
    final doc = await document(const Rect.fromLTWH(-8, -8, 16, 16));
    final framed = await _decode(
      await doc.renderPng(
        beautify: const BeautifyStyle(
          background: (color: Color(0xFFFFFFFF), gradient: null),
          padding: 10,
          shadow: false,
        ),
      ),
    );
    expect((framed.$1, framed.$2), (68, 68));
    expect(_pixel(framed, 4, 4), red);
    final plain = await _decode(await doc.renderPng());
    expect((plain.$1, plain.$2), (48, 48));
    expect(_pixel(plain, 2, 2), red);
  });

  test('贴纸默认大小：长边取原图与 512pt 的较小值并保持比例；设置往返与校验（#103）', () {
    expect(initialStickerSize(1000, 500), (512.0, 256.0));
    expect(initialStickerSize(300, 200), (300.0, 200.0));
    final settings = AppSettings(primaryLanguage: 'zh-CN')
      ..stickers.add(const StickerEntry(id: 'a', width: 120, height: 60));
    final restored = AppSettings.fromMap(settings.toMap());
    expect(restored.stickers.single.toMap(), {
      'id': 'a',
      'width': 120.0,
      'height': 60.0,
    });
    expect(restored.validate, returnsNormally);
    restored.stickers.add(const StickerEntry(id: 'b', width: 513, height: 10));
    expect(restored.validate, throwsFormatException);
    restored.stickers
      ..removeLast()
      ..add(const StickerEntry(id: 'c', width: 0, height: 10));
    expect(restored.validate, throwsFormatException);
  });
}
