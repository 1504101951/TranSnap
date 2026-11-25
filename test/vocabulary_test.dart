import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:transnap/src/common/constants/method_names.dart';
import 'package:transnap/src/history/vocabulary.dart';
import 'package:transnap/src/selection/selection_session.dart';

void main() {
  test('同一单词不区分大小写只保留一条并更新内容，列表按加入时间倒序，删除后消失', () {
    final store = VocabularyStore(sqlite3.openInMemory());
    store.add(
      const VocabularyEntry(
        word: 'Apple',
        translation: '苹果',
        definition: 'a fruit',
        addedAt: 1,
      ),
    );
    store.add(
      const VocabularyEntry(
        word: 'pear',
        translation: '梨',
        definition: 'another fruit',
        addedAt: 2,
      ),
    );
    store.add(
      const VocabularyEntry(
        word: 'apple',
        translation: '苹果（更新）',
        definition: 'updated',
        addedAt: 3,
      ),
    );
    expect(
      [for (final e in store.list()) (e.word, e.translation, e.addedAt)],
      [('Apple', '苹果（更新）', 3), ('pear', '梨', 2)],
    );
    handleVocabularyRequest(
      store,
      const MethodCall(MethodNames.deleteVocabulary, {'word': 'APPLE'}),
    );
    expect(store.list().map((e) => e.word), ['pear']);
  });

  test('CSV 每列加引号并转义引号，释义内的逗号与换行不串列', () {
    final store = VocabularyStore(sqlite3.openInMemory());
    store.add(
      const VocabularyEntry(
        word: 'quote',
        translation: '引用, 报价',
        definition: 'say "hi"\nnext line',
        addedAt: 1,
      ),
    );
    expect(store.csv(), '"quote","引用, 报价","say ""hi""\nnext line"\n');
  });

  test('查词判定：1–3 个拉丁字母词且不超过 40 字符，或 1–4 个汉字', () {
    for (final term in [
      'serendipity',
      ' take off ',
      "don't stop now",
      'state-of-the-art',
      '苹果',
      '人工智能',
      'a' * 40,
    ]) {
      expect(SelectionSession.isDictionaryTerm(term), isTrue, reason: term);
    }
    for (final term in [
      'one two three four',
      'a' * 41,
      '中华人民共和',
      'Hello, world',
      '苹果 手机',
      '',
      '42',
    ]) {
      expect(SelectionSession.isDictionaryTerm(term), isFalse, reason: term);
    }
  });
}
