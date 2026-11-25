import '../common/constants/drawing_metrics.dart';

class StickerEntry {
  const StickerEntry({
    required this.id,
    required this.width,
    required this.height,
  });
  final String id;
  final double width;
  final double height;

  factory StickerEntry.fromMap(Map<Object?, Object?> map) => StickerEntry(
    id: map['id'] as String,
    width: (map['width'] as num).toDouble(),
    height: (map['height'] as num).toDouble(),
  );

  Map<String, Object> toMap() => {'id': id, 'width': width, 'height': height};

  void validate() {
    if (id.isEmpty ||
        width <= 0 ||
        height <= 0 ||
        (width > height ? width : height) > StickerMetrics.maxDefaultSize) {
      throw const FormatException('贴纸默认大小无效。');
    }
  }
}

(double, double) initialStickerSize(int width, int height) {
  final long = (width > height ? width : height).toDouble();
  final scale = long > StickerMetrics.maxDefaultSize
      ? StickerMetrics.maxDefaultSize / long
      : 1.0;
  return (width * scale, height * scale);
}
