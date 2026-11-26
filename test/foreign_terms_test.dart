import 'package:flutter_test/flutter_test.dart';
import 'package:transnap/src/translation/foreign_terms.dart';

void main() {
  test('中文目标语言提取拉丁字母片段：相邻单词合并，网址、版本号、带点号/下划线/斜杠/@ 的词与单个字母不提取', () {
    expect(
      ForeignTerms.of(
        '我们在 Node.js 里用 cache hit 统计，见 https://a.com 和 v1.2 版本，A 方案。',
        'zh-CN',
      ),
      ['cache hit'],
    );
    expect(
      ForeignTerms.of(
        "这是 state-of-the-art 的 don't 用法，e.g. 例子，file_name、a/b、x@y.com。",
        'zh-CN',
      ),
      ['state-of-the-art', "don't"],
    );
    expect(ForeignTerms.of('我去bank，再去 bank（cache）', 'zh-TW'), [
      'bank',
      'cache',
    ]);
  });

  test('拉丁字母目标语言提取中日韩文字片段，单个字不提取；其他目标语言提取拉丁字母片段', () {
    expect(ForeignTerms.of('We met at 北京 station, ate 饺子 with 我.', 'en'), [
      '北京',
      '饺子',
    ]);
    expect(ForeignTerms.of('今日は meeting です', 'ja'), ['meeting']);
  });

  test('片段带 UTF-16 起止偏移，同一片段每处出现都单独给出（盖板按偏移取位置）', () {
    expect(ForeignTerms.spans('我去bank，再去 bank', 'zh-CN'), [
      (start: 2, end: 6, text: 'bank'),
      (start: 10, end: 14, text: 'bank'),
    ]);
  });
}
