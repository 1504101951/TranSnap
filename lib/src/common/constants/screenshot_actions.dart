import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'screenshot_enums.dart';

abstract final class ScreenshotActions {
  static const shapePrefix = 'screenshot-shape-';
  static const brushPrefix = 'screenshot-brush-';
  static const palette = 'screenshot-color-picker';
  static const width = 'screenshot-stroke-width';
  static const shapeMode = 'screenshot-shape-mode';
  static const cursor = 'screenshot-tool-cursor';
  static const crop = 'screenshot-tool-crop';
  static const record = 'screenshot-record';
  static const live = 'screenshot-live';
  static const scrolling = 'screenshot-scrolling';
  static const rect = 'screenshot-tool-rect';
  static const arrow = 'screenshot-tool-arrow';
  static const step = 'screenshot-tool-step';
  static const text = 'screenshot-tool-text';
  static const brush = 'screenshot-tool-brush';
  static const eyedropper = 'screenshot-tool-eyedropper';
  static const ruler = 'screenshot-tool-ruler';
  static const beautify = 'screenshot-beautify';
  static const ratio = 'screenshot-ratio';
  static const sticker = 'screenshot-sticker';
  static const pin = 'screenshot-pin';
  static const save = 'screenshot-save';
  static const copy = 'screenshot-copy';
  static const ocrCopy = 'screenshot-ocr-copy';
  static const ocrTranslate = 'screenshot-ocr-translate';
  static const close = 'screenshot-close';
  static const sizeDown = 'screenshot-text-size-down';
  static const sizeUp = 'screenshot-text-size-up';
  static const reveal = 'screenshot-reveal';
  static const colorPrefix = 'screenshot-text-color-';

  static const composable = <String, ({IconData icon, bool hostsChildren})>{
    crop: (icon: LucideIcons.crop, hostsChildren: true),
    record: (icon: LucideIcons.video, hostsChildren: false),
    scrolling: (icon: LucideIcons.unfoldVertical, hostsChildren: false),
    rect: (icon: LucideIcons.square, hostsChildren: true),
    arrow: (icon: LucideIcons.arrowUpRight, hostsChildren: true),
    step: (icon: LucideIcons.listOrdered, hostsChildren: true),
    text: (icon: LucideIcons.type, hostsChildren: true),
    brush: (icon: LucideIcons.brush, hostsChildren: true),
    eyedropper: (icon: LucideIcons.pipette, hostsChildren: true),
    ruler: (icon: LucideIcons.ruler, hostsChildren: true),
    beautify: (icon: LucideIcons.sparkles, hostsChildren: true),
    sticker: (icon: LucideIcons.smile, hostsChildren: false),
    ratio: (icon: LucideIcons.ratio, hostsChildren: false),
    pin: (icon: LucideIcons.pin, hostsChildren: false),
    save: (icon: LucideIcons.save, hostsChildren: false),
    copy: (icon: LucideIcons.copy, hostsChildren: false),
    ocrCopy: (icon: LucideIcons.scanText, hostsChildren: false),
    ocrTranslate: (icon: LucideIcons.languages, hostsChildren: false),
    close: (icon: LucideIcons.x, hostsChildren: false),
  };

  static const defaultFavorites = [
    crop,
    rect,
    record,
    ocrCopy,
    ocrTranslate,
    pin,
  ];

  static const defaultGroups = [
    [arrow, step, text, brush],
    [beautify, ratio, save, copy, close],
  ];

  static const defaultChildren = <String, List<String>>{
    crop: [scrolling, eyedropper, ruler],
    beautify: [sticker],
  };

  static final Map<String, IconData> icons = {
    for (final entry in composable.entries) entry.key: entry.value.icon,
  };

  static final Map<String, String> labels = {
    '${shapePrefix}rectangle': '矩形框',
    '${shapePrefix}circle': '圆形框',
    '${shapePrefix}filledRectangle': '矩形纯色填充',
    '${shapePrefix}filledCircle': '圆形纯色填充',
    '${brushPrefix}solid': '普通画笔',
    '${brushPrefix}mosaic': '马赛克画笔',
    '${brushPrefix}highlighter': '荧光笔',
    palette: '颜色',
    width: '粗细',
    shapeMode: '图形模式',
    cursor: '光标',
    crop: '截图',
    record: '录制',
    live: '实时翻译',
    scrolling: '滚动长截图',
    rect: '图形',
    arrow: '箭头',
    step: '编号',
    text: '文字',
    brush: '画笔',
    eyedropper: '取色',
    ruler: '标尺',
    beautify: '美化',
    sticker: '贴纸',
    ratio: '比例',
    pin: '贴图',
    save: '保存',
    copy: '复制图片',
    ocrCopy: '识别文字',
    ocrTranslate: '翻译文字',
    close: '关闭',
    for (var i = 0; i < ScreenshotDefaults.textColors.length; i++)
      '$colorPrefix${ScreenshotDefaults.textColors[i].toARGB32()}':
          '文字颜色：${['红', '白', '黑', '黄'][i]}',
    sizeDown: '缩小字号',
    sizeUp: '增大字号',
    reveal: '在 Finder 中显示',
  };
}
