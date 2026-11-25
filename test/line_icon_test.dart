import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:lucide_icons_flutter/lucide_icons_weights.dart';
import 'package:transnap/src/common/widgets/line_icon.dart';

void main() {
  test('按显示尺寸选字重，使屏幕线宽最接近 1.6pt（#67）', () {
    // 作用：验证尺寸 → 字重的选择，它决定各尺寸图标的线宽是否一致。
    // 边界：屏幕线宽＝24 单位线宽 × 尺寸 ÷ 24；12pt 取 600（1.5），14pt 取 500（1.46 比 600 的 1.75 更近），
    // 16pt 取 500（1.67），18pt 取 400（1.5），20pt 取 400（1.67），24pt 取 300（1.55），32pt 取 200（1.33 比 300 的 2.07 更近）。
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
    // 作用：验证 resolve 的输出，Release 构建只保留常量 IconData 用到的字形。
    // 边界：16pt 的复制图标换成 500 字重；20pt 选常规字重 400 时原样返回；不在字重表里的码位原样返回。
    expect(LineIcon.resolve(LucideIcons.copy, 16), LucideIcons500.copy);
    expect(LineIcon.resolve(LucideIcons.copy, 20), LucideIcons.copy);
    expect(LineIcon.resolve(LucideIcons.zapOff, 16), LucideIcons.zapOff);
  });
}
