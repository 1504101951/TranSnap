import 'package:flutter_test/flutter_test.dart';
import 'package:translate_app/src/common/utils/date_text.dart';

/// 无参数；验证历史与生词本共用的日期时间与日期分组文本。
void main() {
  test('月、日、时、分不足两位时补零', () {
    // 作用：列表时间与导出文件名依赖固定宽度。
    // 边界：各字段取一位数最大值 9 与两位数 12。
    expect(dateText(DateTime(2026, 9, 9)), '2026-09-09');
    expect(dateTimeText(DateTime(2026, 12, 9, 9, 5)), '2026-12-09 09:05');
    expect(timeText(DateTime(2026, 12, 9, 9, 5)), '09:05');
    expect(timeText(DateTime(2026, 12, 9, 23, 59)), '23:59');
  });

  test('按本地自然日返回今天、昨天或 yyyy-MM-dd 分组标题', () {
    // 作用：验证历史列表日期分组标题在跨日、跨月和跨年时的正确转换。
    // 边界：当天 00:00 与 23:59 均归入「今天」；跨月初 1 号的上一天归入「昨天」；两天前归入具体日期。
    final now = DateTime(2026, 12, 1, 0, 5);
    expect(dateGroupLabel(DateTime(2026, 12, 1, 23, 59), now: now), '今天');
    expect(dateGroupLabel(DateTime(2026, 11, 30, 23, 59), now: now), '昨天');
    expect(dateGroupLabel(DateTime(2026, 11, 29, 18, 0), now: now), '2026-11-29');
    expect(dateGroupLabel(DateTime(2025, 12, 1, 12, 0), now: now), '2025-12-01');
  });
}
