/// value 为本地时间；返回 yyyy-MM-dd。
String dateText(DateTime value) =>
    '${value.year}-${_pad(value.month)}-${_pad(value.day)}';

/// value 为本地时间；返回 yyyy-MM-dd HH:mm。
String dateTimeText(DateTime value) =>
    '${dateText(value)} ${_pad(value.hour)}:${_pad(value.minute)}';

/// value 为本地时间；返回 HH:mm。
String timeText(DateTime value) =>
    '${_pad(value.hour)}:${_pad(value.minute)}';

/// value 为本地记录时间，now 为可选当前本地时间；返回「今天」「昨天」或 yyyy-MM-dd 分组标题。
String dateGroupLabel(DateTime value, {DateTime? now}) {
  final reference = now ?? DateTime.now();
  final today = DateTime(reference.year, reference.month, reference.day);
  final target = DateTime(value.year, value.month, value.day);
  final difference = today.difference(target).inDays;
  if (difference == 0) return '今天';
  if (difference == 1) return '昨天';
  return dateText(value);
}

/// value 为月、日、时或分；返回补零到两位的文本。
String _pad(int value) => value.toString().padLeft(2, '0');
