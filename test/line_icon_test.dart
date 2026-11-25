import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:lucide_icons_flutter/lucide_icons_weights.dart';
import 'package:transnap/src/common/widgets/line_icon.dart';

void main() {
  test('按显示尺寸选字重，使屏幕线宽最接近 1.6pt（#67）', () {
    expect(
      {
        for (final size in [12.0, 14, 16, 18, 20, 24, 32])
          size: LineIcon.weightFor(size.toDouble()),
      },
      {
        12.0: 600,
        14.0: 500,
        16.0: 500,
        18.0: 400,
        20.0: 400,
        24.0: 300,
        32.0: 200,
      },
    );
  });

  test('换用所选字重的常量图标，常规字重与未收录图标原样返回', () {
    expect(LineIcon.resolve(LucideIcons.copy, 16), LucideIcons500.copy);
    expect(LineIcon.resolve(LucideIcons.copy, 20), LucideIcons.copy);
    expect(LineIcon.resolve(LucideIcons.zapOff, 16), LucideIcons.zapOff);
  });
}
