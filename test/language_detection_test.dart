import 'package:flutter_test/flutter_test.dart';
import 'package:transnap/src/common/constants/preference_keys.dart';
import 'package:transnap/src/translation/language_detection.dart';

LanguageCandidates candidates(
  List<(String, double?)> ranked, [
  Set<String> unchangedScripts = const {},
]) => (
  candidates: [
    for (final (code, confidence) in ranked)
      (code: code, confidence: confidence),
  ],
  unchangedScripts: unchangedScripts,
);

void main() {
  test('首位置信度达到 0.5 直接采用；不足时依次取用户语言候选、唯一拉丁用户语言、常用语言，都不满足时不判定', () {
    const user = ['zh-CN', 'en'];
    expect(
      LanguageDetection.resolve(
        candidates([('en', 0.13), ('nl', 0.11), ('id', 0.10)]),
        'hello',
        user,
      ),
      'en',
    );
    expect(
      LanguageDetection.resolve(candidates([('fr', 0.90)]), 'Bonjour', user),
      'fr',
    );
    expect(
      LanguageDetection.resolve(
        candidates([('pl', 0.29), ('nl', 0.09), ('ro', 0.09)]),
        'ok',
        user,
      ),
      'en',
    );
    expect(
      LanguageDetection.resolve(
        candidates([('pl', 0.29), ('nl', 0.09), ('ro', 0.09)]),
        'ok',
        ['en', 'fr'],
      ),
      isNull,
    );
    expect(
      LanguageDetection.resolve(
        candidates([('en', 0.34), ('nl', 0.20), ('ro', 0.12)]),
        'pot',
        ['zh-CN'],
      ),
      'en',
    );
    expect(
      LanguageDetection.resolve(
        candidates([('pt', 0.48), ('es', 0.30), ('it', 0.10)]),
        'banco',
        ['zh-CN'],
      ),
      'pt',
    );
    expect(
      LanguageDetection.resolve(
        candidates([('tr', 0.31), ('pl', 0.20), ('ro', 0.10)]),
        'analyze',
        ['zh-CN', 'fr', 'de'],
      ),
      isNull,
    );
    expect(LanguageDetection.resolve(candidates([]), 'hello', user), isNull);
  });

  test('判定为中文时，原文按用户首个中文的书写体系转换后不变则改用该体系，否则保留识别结果', () {
    const user = ['zh-CN', 'en'];
    expect(
      LanguageDetection.resolve(
        candidates([('zh-Hant', 0.80), ('zh-Hans', 0.20)], {'Hans', 'Hant'}),
        '你好',
        user,
      ),
      'zh-Hans',
    );
    expect(
      LanguageDetection.resolve(
        candidates([('zh-Hant', 0.99)], {'Hant'}),
        '這是繁體中文',
        user,
      ),
      'zh-Hant',
    );
    expect(
      LanguageDetection.resolve(
        candidates([('zh-Hans', 0.99)], {'Hans', 'Hant'}),
        '你好',
        ['zh-TW'],
      ),
      'zh-Hant',
    );
    expect(
      LanguageDetection.resolve(
        candidates([('zh-Hans', 0.99)], {'Hans'}),
        '这是简体中文',
        ['en'],
      ),
      'zh-Hans',
    );
  });

  test('候选不带置信度时首位按达标处理，中文简繁规则不变', () {
    expect(
      LanguageDetection.resolve(
        candidates([('ja', null), ('en', null)]),
        '設定を開く',
        ['zh-CN', 'en'],
      ),
      'ja',
    );
    expect(
      LanguageDetection.resolve(
        candidates([('zh-Hant', null)], {'Hans', 'Hant'}),
        '你好',
        ['zh-CN'],
      ),
      'zh-Hans',
    );
  });

  test('权重：全部可识别语言为 1，常用语言为 3，英文为 20，用户语言为 30；无法识别的用户语言忽略', () {
    final hints = LanguageDetection.hints(['zh-CN', 'pt-BR', 'zh-HK', 'xx']);
    expect(hints['zh-Hans'], LanguageDetection.userWeight);
    expect(hints['zh-Hant'], LanguageDetection.userWeight);
    expect(hints['pt'], LanguageDetection.userWeight);
    expect(hints['en'], LanguageDetection.englishWeight);
    expect(hints['it'], LanguageDetection.popularWeight);
    expect(hints['ro'], LanguageDetection.baseWeight);
    expect(hints.containsKey('xx'), isFalse);
    expect(hints.length, LanguageDetection.all.length);
    expect(LanguageDetection.hints(['en'])['en'], LanguageDetection.userWeight);
  });

  test('用户语言只取已保存的主要、次要与输入语言，识别时把权重交给候选来源', () async {
    expect(LanguageDetection.preferred({}), isEmpty);
    final preferred = LanguageDetection.preferred({
      PreferenceKeys.primaryLanguage: 'zh-CN',
      PreferenceKeys.inputSecondaryLanguage: 'fr',
      PreferenceKeys.fontSet: 'neutral',
    });
    expect(preferred, ['zh-CN', 'fr']);
    Map<String, double>? received;
    final detected = await LanguageDetection.detect('Bonjour', preferred, (
      text,
      hints,
    ) async {
      received = hints;
      return candidates([('fr', 0.9)]);
    });
    expect(detected, 'fr');
    expect(received!['fr'], LanguageDetection.userWeight);
  });
}
