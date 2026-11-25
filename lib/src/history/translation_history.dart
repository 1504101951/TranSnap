import 'package:sqlite3/sqlite3.dart';

typedef HistoryCursor = ({int completedAt, int id});

class TranslationRecord {
  const TranslationRecord({
    required this.id,
    required this.sourceText,
    required this.translatedText,
    required this.detectedLanguage,
    required this.targetLanguage,
    required this.providerId,
    required this.completedAt,
    this.model,
    this.sourceLabel,
  });

  final int id;
  final String sourceText;
  final String translatedText;
  final String detectedLanguage;
  final String targetLanguage;
  final String providerId;
  final String? model;
  final int completedAt;

  final String? sourceLabel;

  HistoryCursor get cursor => (completedAt: completedAt, id: id);

  factory TranslationRecord.fromMap(Map<Object?, Object?> map) =>
      TranslationRecord(
        id: map['id'] as int,
        sourceText: map['sourceText'] as String,
        translatedText: map['translatedText'] as String,
        detectedLanguage: map['detectedLanguage'] as String,
        targetLanguage: map['targetLanguage'] as String,
        providerId: map['providerId'] as String,
        completedAt: map['completedAt'] as int,
        model: map['model'] as String?,
        sourceLabel: map['sourceLabel'] as String?,
      );
}

class TranslationHistoryStore {
  TranslationHistoryStore(
    this.database, {
    this.onChanged,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    database.execute('''
CREATE TABLE IF NOT EXISTS translation_history (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  source_text TEXT NOT NULL,
  translated_text TEXT NOT NULL,
  detected_language TEXT NOT NULL,
  target_language TEXT NOT NULL,
  provider_id TEXT NOT NULL,
  model TEXT,
  completed_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS history_meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
''');
    final columns = database.select('PRAGMA table_info(translation_history)');
    if (!columns.any((column) => column['name'] == 'source_label')) {
      database.execute(
        'ALTER TABLE translation_history ADD COLUMN source_label TEXT',
      );
    }
    database.execute('''CREATE INDEX IF NOT EXISTS history_completed_order
      ON translation_history(completed_at DESC, id DESC)''');
    database.execute('''
INSERT INTO history_meta(key, value) VALUES('recording', '1')
ON CONFLICT(key) DO NOTHING
''');
    database.execute('''
INSERT INTO history_meta(key, value) VALUES('retention_days', '30')
ON CONFLICT(key) DO NOTHING;
INSERT INTO history_meta(key, value) VALUES('retention_confirmed', '0')
ON CONFLICT(key) DO NOTHING;
''');
    if (!retentionConfirmed && expiredCount(retentionDays) == 0) {
      database.execute(
        "UPDATE history_meta SET value = '1' WHERE key = 'retention_confirmed'",
      );
    }
    _prune();
  }

  final Database database;
  final DateTime Function() _now;

  static const unknownSource = '未记录来源';

  static const retentionOptions = {
    30: '30 天',
    90: '90 天',
    365: '365 天',
    0: '永久保留',
  };

  int get retentionDays => int.parse(
    database
            .select(
              "SELECT value FROM history_meta WHERE key = 'retention_days'",
            )
            .single['value']
        as String,
  );

  bool get retentionConfirmed =>
      database
          .select(
            "SELECT value FROM history_meta WHERE key = 'retention_confirmed'",
          )
          .single['value'] ==
      '1';

  int expiredCount(int days) {
    if (!retentionOptions.containsKey(days)) {
      throw ArgumentError.value(days, 'days');
    }
    if (days == 0) return 0;
    final cutoff = _now().subtract(Duration(days: days)).millisecondsSinceEpoch;
    return database.select(
          'SELECT COUNT(*) AS count FROM translation_history WHERE completed_at < ?',
          [cutoff],
        ).single['count']
        as int;
  }

  void setRetention(int days) {
    if (!retentionOptions.containsKey(days)) {
      throw ArgumentError.value(days, 'days');
    }
    database.execute('BEGIN');
    try {
      _prune();
      database.execute(
        "UPDATE history_meta SET value = ? WHERE key = 'retention_days'",
        ['$days'],
      );
      database.execute(
        "UPDATE history_meta SET value = '1' WHERE key = 'retention_confirmed'",
      );
      _prune();
      database.execute('COMMIT');
    } catch (_) {
      database.execute('ROLLBACK');
      rethrow;
    }
    onChanged?.call();
  }

  int? _cutoff() {
    if (!retentionConfirmed || retentionDays == 0) return null;
    return _now().subtract(Duration(days: retentionDays)).millisecondsSinceEpoch;
  }

  void _prune() {
    final cutoff = _cutoff();
    if (cutoff == null) return;
    database.execute('DELETE FROM translation_history WHERE completed_at < ?', [
      cutoff,
    ]);
  }

  void delete(int id) {
    database.execute('DELETE FROM translation_history WHERE id = ?', [id]);
    if (database.updatedRows > 0) onChanged?.call();
  }

  void clear() {
    database.execute('DELETE FROM translation_history');
    if (database.updatedRows > 0) onChanged?.call();
  }

  List<String> sources() {
    final cutoff = _cutoff();
    return [
      for (final row in database.select(
        "SELECT DISTINCT COALESCE(NULLIF(source_label, ''), ?) AS source FROM translation_history"
        '${cutoff == null ? '' : ' WHERE completed_at >= ?'} ORDER BY source COLLATE NOCASE',
        [unknownSource, ?cutoff],
      ))
        row['source'] as String,
    ];
  }

  final void Function()? onChanged;

  bool get recordingEnabled {
    final rows = database.select(
      "SELECT value FROM history_meta WHERE key = 'recording'",
    );
    return rows.first['value'] == '1';
  }

  set recordingEnabled(bool value) {
    database.execute(
      "INSERT INTO history_meta(key, value) VALUES('recording', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
      [value ? '1' : '0'],
    );
  }

  void insert({
    required String sourceText,
    required String translatedText,
    required String detectedLanguage,
    required String targetLanguage,
    required String providerId,
    String? model,
    required int completedAt,
    String? sourceLabel,
  }) {
    if (!recordingEnabled) return;
    database.execute(
      '''INSERT INTO translation_history(
        source_text, translated_text, detected_language, target_language, provider_id, model, completed_at, source_label
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)''',
      [
        sourceText,
        translatedText,
        detectedLanguage,
        targetLanguage,
        providerId,
        model,
        completedAt,
        sourceLabel,
      ],
    );
    _prune();
    onChanged?.call();
  }

  List<TranslationRecord> page({
    HistoryCursor? before,
    int limit = 10,
    String? query,
    String? source,
    int? from,
    int? to,
  }) {
    if (limit < 1) throw ArgumentError.value(limit, 'limit', '必须为正数');
    final conditions = <String>[];
    final parameters = <Object?>[];
    final cutoff = _cutoff();
    if (cutoff != null) {
      conditions.add('completed_at >= ?');
      parameters.add(cutoff);
    }
    if (before != null) {
      conditions.add('(completed_at, id) < (?, ?)');
      parameters.addAll([before.completedAt, before.id]);
    }
    if (query != null && query.isNotEmpty) {
      conditions.add(
        '(instr(lower(source_text), lower(?)) > 0 OR instr(lower(translated_text), lower(?)) > 0)',
      );
      parameters.addAll([query, query]);
    }
    if (source != null && source.isNotEmpty) {
      conditions.add("COALESCE(NULLIF(source_label, ''), ?) = ?");
      parameters.addAll([unknownSource, source]);
    }
    if (from != null) {
      conditions.add('completed_at >= ?');
      parameters.add(from);
    }
    if (to != null) {
      conditions.add('completed_at < ?');
      parameters.add(to);
    }
    final rows = database.select(
      '''SELECT id, source_text, translated_text, detected_language, target_language, provider_id, model, completed_at, source_label
         FROM translation_history
         ${conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')}'}
         ORDER BY completed_at DESC, id DESC LIMIT ?''',
      [...parameters, limit],
    );
    return [
      for (final row in rows)
        TranslationRecord(
          id: row['id'] as int,
          sourceText: row['source_text'] as String,
          translatedText: row['translated_text'] as String,
          detectedLanguage: row['detected_language'] as String,
          targetLanguage: row['target_language'] as String,
          providerId: row['provider_id'] as String,
          model: row['model'] as String?,
          completedAt: row['completed_at'] as int,
          sourceLabel: row['source_label'] as String?,
        ),
    ];
  }
}
