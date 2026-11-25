String dateText(DateTime value) =>
    '${value.year}-${_pad(value.month)}-${_pad(value.day)}';

String dateTimeText(DateTime value) =>
    '${dateText(value)} ${_pad(value.hour)}:${_pad(value.minute)}';

String timeText(DateTime value) =>
    '${_pad(value.hour)}:${_pad(value.minute)}';

String dateGroupLabel(DateTime value, {DateTime? now}) {
  final reference = now ?? DateTime.now();
  final today = DateTime(reference.year, reference.month, reference.day);
  final target = DateTime(value.year, value.month, value.day);
  final difference = today.difference(target).inDays;
  if (difference == 0) return '今天';
  if (difference == 1) return '昨天';
  return dateText(value);
}

String _pad(int value) => value.toString().padLeft(2, '0');
