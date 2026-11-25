import 'package:flutter_test/flutter_test.dart';
import 'package:transnap/src/common/utils/date_text.dart';

void main() {
  test('月、日、时、分不足两位时补零', () {
    expect(dateText(DateTime(2026, 9, 9)), '2026-09-09');
    expect(dateTimeText(DateTime(2026, 12, 9, 9, 5)), '2026-12-09 09:05');
    expect(timeText(DateTime(2026, 12, 9, 9, 5)), '09:05');
    expect(timeText(DateTime(2026, 12, 9, 23, 59)), '23:59');
  });

  test('按本地自然日返回今天、昨天或 yyyy-MM-dd 分组标题', () {
    final now = DateTime(2026, 12, 1, 0, 5);
    expect(dateGroupLabel(DateTime(2026, 12, 1, 23, 59), now: now), '今天');
    expect(dateGroupLabel(DateTime(2026, 11, 30, 23, 59), now: now), '昨天');
    expect(dateGroupLabel(DateTime(2026, 11, 29, 18, 0), now: now), '2026-11-29');
    expect(dateGroupLabel(DateTime(2025, 12, 1, 12, 0), now: now), '2025-12-01');
  });
}
