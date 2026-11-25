class LiveBlockCache {
  LiveBlockCache({required this.budgetBytes});

  final int budgetBytes;
  final _entries = <String, _Entry>{};
  var _bytes = 0;

  int get bytes => _bytes;

  String? translation(String key) => _touch(key)?.translation;

  void store(String key, String translation) {
    final entry = _take(key)..translation = translation;
    _put(key, entry);
  }

  int failures(String key) => _entries[key]?.failures ?? 0;

  void noteFailure(String key) {
    final entry = _take(key)..failures += 1;
    _put(key, entry);
  }

  bool rejected(String key) => _entries[key]?.rejected ?? false;

  void reject(String key) {
    final entry = _take(key)..rejected = true;
    _put(key, entry);
  }

  void clear() {
    _entries.clear();
    _bytes = 0;
  }

  _Entry? _touch(String key) {
    final entry = _entries.remove(key);
    if (entry != null) _entries[key] = entry;
    return entry;
  }

  _Entry _take(String key) {
    final entry = _entries.remove(key);
    if (entry == null) return _Entry();
    _bytes -= _cost(key, entry);
    return entry;
  }

  void _put(String key, _Entry entry) {
    _entries[key] = entry;
    _bytes += _cost(key, entry);
    while (_bytes > budgetBytes && _entries.isNotEmpty) {
      final oldest = _entries.keys.first;
      _bytes -= _cost(oldest, _entries.remove(oldest)!);
    }
  }

  int _cost(String key, _Entry entry) =>
      (key.length + (entry.translation?.length ?? 0)) * 2;
}

class _Entry {
  String? translation;
  var failures = 0;
  var rejected = false;
}
