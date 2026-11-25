import 'dart:ui';

abstract final class DrawingMetrics {
  static const paletteWidth = 280.0;
  static const padding = 12.0;
  static const gap = 8.0;
  static const fieldWidth = 256.0;
  static const fieldHeight = 144.0;
  static const hueHeight = 16.0;
  static const swatch = 24.0;
  static const minWidth = 1.0;
  static const maxWidth = 20.0;
  static const mosaicPixels = 12.0;

  static const highlighterColor = Color(0xFFFFCC00);
  static const highlighterWidth = 16.0;
  static const highlighterOpacity = 0.4;

  static const stepDiameter = 28.0;
  static const stepFontRatio = 0.55;
  static const stepTextMaxRatio = 0.8;
  static const stepLightThreshold = 0.5;
  static const colors = <Color>[
    Color(0xFFFF3B30),
    Color(0xFFFF9500),
    Color(0xFFFFCC00),
    Color(0xFF34C759),
    Color(0xFF007AFF),
    Color(0xFFAF52DE),
    Color(0xFFFFFFFF),
    Color(0xFF000000),
  ];

  static const gradients = <({String name, Color from, Color to})>[
    (name: '晨曦', from: Color(0xFFFF9A8B), to: Color(0xFFFF6A88)),
    (name: '海洋', from: Color(0xFF4FACFE), to: Color(0xFF00F2FE)),
    (name: '薄荷', from: Color(0xFF43E97B), to: Color(0xFF38F9D7)),
    (name: '紫罗兰', from: Color(0xFFA18CD1), to: Color(0xFFFBC2EB)),
    (name: '日落', from: Color(0xFFF6D365), to: Color(0xFFFDA085)),
    (name: '石墨', from: Color(0xFF434343), to: Color(0xFF000000)),
  ];

  static const wellWidth = 48.0;
  static const wellHeight = 24.0;
  static const wellSelectedBorder = 2.0;
  static const directionButton = 32.0;
  static const previewHeight = 24.0;
}

abstract final class BeautifyMetrics {
  static const paddings = <double>[32, 64, 96];
  static const defaultPadding = 64.0;

  static const paddingMenuWidth = 112.0;
  static const radiusMenuWidth = 88.0;

  static const squareRadius = 0.0;
  static const roundRadius = 12.0;

  static const shadowColor = Color(0x59000000);
  static const shadowBlur = 24.0;
  static const shadowOffset = 8.0;
}

abstract final class MeasureMetrics {
  static const labelOffset = 12.0;

  static const swatchSize = 10.0;
  static const swatchBorder = 1.0;
  static const swatchRadius = 2.0;
  static const swatchGap = 4.0;

  static const lineWidth = 1.0;
  static const outlineWidth = 3.0;
  static const tickLength = 8.0;
}

abstract final class CropMetrics {
  static const ratios = <({String label, double? ratio})>[
    (label: '自由', ratio: null),
    (label: '1:1', ratio: 1),
    (label: '4:3', ratio: 4 / 3),
    (label: '3:4', ratio: 3 / 4),
    (label: '16:9', ratio: 16 / 9),
    (label: '9:16', ratio: 9 / 16),
  ];

  static const ratioFontSize = 11.0;

  static const nudgeStep = 1.0;
  static const nudgeLargeStep = 10.0;

  static const minSide = 8.0;

  static const labelFontSize = 12.0;
  static const labelHeight = 18.0;
  static const labelPadding = 6.0;
  static const labelGap = 4.0;
  static const labelRadius = 4.0;
  static const labelBackground = Color(0x99000000);
}

abstract final class StickerMetrics {
  static const maxDefaultSize = 512.0;
  static const emojiDefaultSize = 96.0;

  static const cellRadius = 6.0;
  static const panelColumns = 6;
  static const panelGap = 4.0;
  static const thumbnail = 48.0;
  static const thumbnailGap = 8.0;

  static const actionGap = 8.0;

  static const panelWidth = 284.0;

  static const gridHeight = 260.0;
  static const emojiFontSize = 24.0;
  static const categoryFontSize = 12.0;
  static const categoryPadding = 4.0;

  static const anchorGap = 4.0;

  static const previewWidth = 480.0;
  static const previewHeight = 320.0;
  static const checker = 12.0;

  static const rotateDistance = 20.0;
  static const rotateHandle = 10.0;
}
