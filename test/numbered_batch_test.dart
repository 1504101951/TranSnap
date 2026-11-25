import 'package:flutter_test/flutter_test.dart';
import 'package:transnap/src/translation/numbered_batch.dart';
import 'package:transnap/src/translation/translation_types.dart';

Map<int, String> _parse(List<String> chunks, int count) {
  final parser = NumberedBatchParser(count);
  final result = <int, String>{};
  void take(List<BatchItemUpdate> updates) {
    for (final update in updates) {
      result[update.index] = (result[update.index] ?? '') + update.addition;
    }
  }

  chunks.map(parser.add).forEach(take);
  take(parser.finish());
  return result;
}

void main() {
  test('段落内的换行改为空格后逐行编号', () {
    expect(numberedBatchText(['a\r\nb', 'c']), '[1] a b\n[2] c');
  });

  test('编号被拆在两个片段之间时仍能归属，增量在行内逐步给出', () {
    final parser = NumberedBatchParser(2);
    expect(parser.add('['), isEmpty);
    expect(parser.add('1'), isEmpty);
    final first = parser.add('] 你');
    expect(first.single.index, 0);
    expect(first.single.addition, '你');
    expect(parser.add('好\n[').single.addition, '好');
    final second = parser.add('2] 世界');
    expect(second.single.index, 1);
    expect(second.single.addition, '世界');
    expect(parser.finish(), isEmpty);
  });

  test('乱序、缺号、前言与续行按规则归属', () {
    expect(
      _parse(['好的，以下是译文：\n[3] 丙\n[1] 甲\n续行\n[注] 说明\n'], 3),
      {2: '丙', 0: '甲\n续行\n[注] 说明'},
    );
  });

  test('越界或重复的编号当作普通文本', () {
    expect(_parse(['[1] 甲\n[3] 丙\n[2] 乙\n[1] 重复'], 2), {
      0: '甲\n[3] 丙',
      1: '乙\n[1] 重复',
    });
  });

  test('流结束时行首的不完整编号按普通文本提交', () {
    final parser = NumberedBatchParser(1);
    expect(parser.add('[1] 甲\n[1').single.addition, '甲');
    expect(parser.finish().single.addition, '\n[1');
  });
}
