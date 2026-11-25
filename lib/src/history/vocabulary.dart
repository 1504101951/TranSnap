import 'package:flutter/services.dart';
import 'package:sqlite3/sqlite3.dart';

import '../common/constants/method_names.dart';

class VocabularyEntry {
  const VocabularyEntry({
    required this.word,
    required this.translation,
    required this.definition,
    required this.addedAt,
  });

  factory VocabularyEntry.fromMap(Map<Object?, Object?> map) => VocabularyEntry(
    word: map['word'] as String,
    translation: map['translation'] as String,
    definition: map['definition'] as String,
    addedAt: map['addedAt'] as int,
  );

  final String word;
  final String translation;
  final String definition;
  final int addedAt;

  Map<String, Object> toMap() => {
    'word': word,
    'translation': translation,
    'definition': definition,
    'addedAt': addedAt,
  };
}

class VocabularyStore {
  VocabularyStore(this.database, {this.onChanged}) {
    database.execute('''
CREATE TABLE IF NOT EXISTS vocabulary (
  word TEXT PRIMARY KEY COLLATE NOCASE,
  translation TEXT NOT NULL,
  definition TEXT NOT NULL,
  added_at INTEGER NOT NULL
)''');
  }

  final Database database;

  final void Function()? onChanged;

  void add(VocabularyEntry entry) {
    database.execute(
      '''INSERT INTO vocabulary(word, translation, definition, added_at) VALUES (?, ?, ?, ?)
         ON CONFLICT(word) DO UPDATE SET translation = excluded.translation,
           definition = excluded.definition, added_at = excluded.added_at''',
      [entry.word, entry.translation, entry.definition, entry.addedAt],
    );
    onChanged?.call();
  }

  void delete(String word) {
    database.execute('DELETE FROM vocabulary WHERE word = ?', [word]);
    onChanged?.call();
  }

  List<VocabularyEntry> list() => [
    for (final row in database.select(
      'SELECT word, translation, definition, added_at FROM vocabulary ORDER BY added_at DESC, word',
    ))
      VocabularyEntry(
        word: row['word'] as String,
        translation: row['translation'] as String,
        definition: row['definition'] as String,
        addedAt: row['added_at'] as int,
      ),
  ];

  String csv() => [
    for (final entry in list())
      [
        entry.word,
        entry.translation,
        entry.definition,
      ].map((field) => '"${field.replaceAll('"', '""')}"').join(','),
  ].map((line) => '$line\n').join();
}

Object? handleVocabularyRequest(VocabularyStore vocabulary, MethodCall call) {
  switch (call.method) {
    case MethodNames.vocabularyList:
      return [for (final entry in vocabulary.list()) entry.toMap()];
    case MethodNames.deleteVocabulary:
      final map = Map<Object?, Object?>.from(call.arguments as Map);
      vocabulary.delete(map['word'] as String);
      return null;
    case MethodNames.vocabularyCsv:
      return vocabulary.csv();
    default:
      throw MissingPluginException('未知生词本操作：${call.method}');
  }
}
