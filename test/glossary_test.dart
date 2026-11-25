import 'package:flutter_test/flutter_test.dart';
import 'package:transnap/src/settings/app_settings.dart';
import 'package:transnap/src/translation/glossary.dart';
import 'package:transnap/src/translation/glossary_file.dart';

void main() {
  GlossaryEntry entry(String term) =>
      GlossaryEntry(term: term, translation: '译', language: 'zh-CN');

  test('拉丁字母一侧按整词、不区分大小写匹配，汉字与符号一侧按子串匹配', () {
    expect(entry('API').occursIn('Call the api, please.'), isTrue);
    expect(entry('API').occursIn('The capital city'), isFalse);
    expect(entry('API').occursIn('API_KEY'), isTrue);
    expect(entry('C++').occursIn('I write C++daily'), isTrue);
    expect(entry('C++').occursIn('ABC++'), isFalse);
    expect(entry('机器学习').occursIn('深度机器学习模型'), isTrue);
    expect(entry('Node.js').occursIn('Nodexjs'), isFalse);
  });

  test('只返回目标语言一致且在任一原文中出现的术语，保留原文时译法等于术语', () {
    final glossary = [
      const GlossaryEntry(
        term: 'Kubernetes',
        translation: '',
        language: 'zh-CN',
      ),
      const GlossaryEntry(term: 'API', translation: '接口', language: 'zh-CN'),
      const GlossaryEntry(
        term: 'API',
        translation: 'interface',
        language: 'fr',
      ),
      const GlossaryEntry(
        term: 'Swift',
        translation: 'Swift 语言',
        language: 'zh-CN',
      ),
    ];
    expect(
      glossaryHits(glossary, ['Hello', 'Run the API on kubernetes'], 'zh-Hans'),
      [
        {'term': 'Kubernetes', 'translation': 'Kubernetes'},
        {'term': 'API', 'translation': '接口'},
      ],
    );
    expect(glossaryHits(glossary, ['No terms here'], 'zh-CN'), isEmpty);
    expect(glossaryHits(const [], ['API'], 'zh-CN'), isEmpty);
  });

  test('术语表随偏好往返；同一目标语言下大小写不同的同一术语或空术语被拒绝', () {
    final settings = AppSettings(
      primaryLanguage: 'zh-CN',
      glossary: [
        const GlossaryEntry(term: 'API', translation: '接口', language: 'zh-CN'),
        const GlossaryEntry(term: 'api', translation: 'API', language: 'ja'),
      ],
    );
    settings.validate();
    final restored = AppSettings.fromMap(settings.toMap());
    expect(
      restored.glossary.map((e) => e.toMap()),
      settings.glossary.map((e) => e.toMap()),
    );
    restored.glossary.add(
      const GlossaryEntry(term: 'api', translation: '应用接口', language: 'zh-CN'),
    );
    expect(restored.validate, throwsFormatException);
    restored.glossary
      ..removeLast()
      ..add(const GlossaryEntry(term: ' ', translation: '', language: 'zh-CN'));
    expect(restored.validate, throwsFormatException);
  });

  test('CSV 与 JSON 保留引号逗号换行和空译法，并只导出术语字段', () {
    final entries = [
      const GlossaryEntry(
        term: 'say "Hello", API\nnext',
        translation: '第一行\r\n"第二行",尾',
        language: 'sv',
      ),
      const GlossaryEntry(
        term: 'Kubernetes',
        translation: '',
        language: 'zh-CN',
      ),
    ];
    for (final format in ['csv', 'json']) {
      final text = exportGlossaryFile(entries, format: format);
      final draft = parseGlossaryFile('\uFEFF$text', format: format);
      expect(draft.errorCount, 0);
      expect(
        draft.merge([], overwrite: false).map((entry) => entry.toMap()),
        entries.map((entry) => entry.toMap()),
      );
      expect(draft.rows.last.entry!.translation, isEmpty);
    }
  });

  test('CSV 引用与分隔结构错误，以及错误列数，均阻止整批导入', () {
    for (final line in [
      'API,接口',
      'API,接口,zh-CN,extra',
      '"API,接口,zh-CN',
      'A"PI,接口,zh-CN',
      '"API"tail,接口,zh-CN',
    ]) {
      final draft = parseGlossaryFile(
        'term,translation,language\n$line',
        format: 'csv',
      );
      expect(draft.errorCount, 1, reason: line);
      expect(() => draft.merge([], overwrite: false), throwsFormatException);
    }
  });

  test('CSV 精确校验表头，错误报告跨行字段之后的真实行号', () {
    for (final header in [
      '',
      'term,language,translation',
      'term,translation,language,extra',
    ]) {
      expect(parseGlossaryFile(header, format: 'csv').errorCount, 1);
    }
    final draft = parseGlossaryFile(
      'term,translation,language\r\n"multi\r\nline",译,zh-CN\r\n,译,zh-CN\r\n',
      format: 'csv',
    );
    expect(draft.rows.map((row) => row.position), [2, 4]);
    expect(draft.rows.first.entry!.term, 'multi\r\nline');
    expect(draft.rows.last.error, '原文术语不能为空。');
  });

  test('JSON 收集全部字段类型与语言错误，任何错误均使有效行不可提交', () {
    final draft = parseGlossaryFile(
      '[{"term":"API","translation":"接口","language":"zh-CN"},'
      '{"term":3,"translation":"","language":"en"},'
      '{"term":"API","translation":null,"language":"en"},'
      '{"term":"API","translation":""},'
      '{"term":" ","translation":"","language":"en"},'
      '{"term":"API","translation":"","language":""},'
      '{"term":"API","translation":"","language":"invalid-language"},'
      '[]]',
      format: 'json',
    );
    expect(draft.rows.length, 8);
    expect(draft.errorCount, 7);
    expect(draft.rows.first.entry!.translation, '接口');
    expect(() => draft.merge([], overwrite: true), throwsFormatException);
  });

  test('JSON 顶层和真实语法错误保留为可预览错误，文件格式不接受其他类型', () {
    for (final source in ['{}', 'null', '"API"']) {
      expect(parseGlossaryFile(source, format: 'json').errorCount, 1);
    }
    final broken = parseGlossaryFile('[\n{"term": }]', format: 'json');
    expect(broken.errorCount, 1);
    expect(broken.rows.single.position, 2);
    expect(parseGlossaryFile('API', format: 'txt').errorCount, 1);
    expect(() => exportGlossaryFile([], format: 'txt'), throwsFormatException);
  });

  test('语言标签允许系统语言与脚本地区，拒绝非法结构', () {
    for (final language in ['sv', 'zh-Hant-TW', 'pt_BR', 'es-419']) {
      final draft = parseGlossaryFile(
        'term,translation,language\nAPI,,$language',
        format: 'csv',
      );
      expect(draft.errorCount, 0, reason: language);
      expect(draft.rows.single.entry!.language, language);
    }
    for (final language in [
      'en-22',
      'en-',
      '-en',
      'English',
      'auto',
      'zh CN',
    ]) {
      expect(
        parseGlossaryFile(
          'term,translation,language\nAPI,,$language',
          format: 'csv',
        ).errorCount,
        1,
        reason: language,
      );
    }
  });

  test('重复键沿输入顺序预览与合并：保留取首条和已有值，覆盖取末条', () {
    final existing = [
      const GlossaryEntry(term: 'API', translation: '现有', language: 'zh-CN'),
    ];
    final draft = parseGlossaryFile(
      '[{"term":"api","translation":"第一条","language":"zh-Hans"},'
      '{"term":"NEW","translation":"首条","language":"en"},'
      '{"term":"new","translation":"末条","language":"en"},'
      '{"term":"API","translation":"新增语言","language":"ja"}]',
      format: 'json',
    );
    expect(draft.addedCount(existing), 2);
    expect(draft.duplicatePositions(existing), {1, 3});
    expect(
      draft.merge(existing, overwrite: false).map((entry) => entry.translation),
      ['现有', '首条', '新增语言'],
    );
    expect(
      draft.merge(existing, overwrite: true).map((entry) => entry.translation),
      ['第一条', '末条', '新增语言'],
    );
    expect(existing.single.translation, '现有');
  });

  test('CSV 中间与末尾的空行跳过，不计为错误', () {
    final draft = parseGlossaryFile(
      'term,translation,language\r\n\r\nA,甲,zh-CN\r\n\r\nB,乙,zh-CN\r\n\r\n\r\n',
      format: 'csv',
    );
    expect(draft.errorCount, 0);
    expect([for (final row in draft.rows) row.entry!.term], ['A', 'B']);
  });

  test('空术语表导出后可以预览为空批次，不构造空术语', () {
    for (final format in ['csv', 'json']) {
      final draft = parseGlossaryFile(
        exportGlossaryFile([], format: format),
        format: format,
      );
      expect(draft.rows, isEmpty);
      expect(draft.errorCount, 0);
      expect(draft.merge([], overwrite: false), isEmpty);
    }
  });
}
