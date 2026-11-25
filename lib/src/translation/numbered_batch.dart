import 'translation_types.dart';

String singleLineParagraph(String text) =>
    text.replaceAll(RegExp(r'[\r\n]+'), ' ');

String numberedBatchText(List<String> texts) => [
  for (final (index, text) in texts.indexed)
    '[${index + 1}] ${singleLineParagraph(text)}',
].join('\n');

class NumberedBatchParser {
  NumberedBatchParser(this.count);

  final int count;
  static final _marker = RegExp(r'^\[(\d{1,4})\]');
  static final _partialMarker = RegExp(r'^\[\d{0,4}$');
  final _seen = <int>{};
  var _buffer = '';
  int? _index;
  var _decided = false;
  var _started = false;
  var _breakPending = false;

  List<BatchItemUpdate> add(String chunk) {
    _buffer += chunk;
    return _drain(end: false);
  }

  List<BatchItemUpdate> finish() => _drain(end: true);

  List<BatchItemUpdate> _drain({required bool end}) {
    final updates = <BatchItemUpdate>[];
    while (true) {
      if (!_decided) {
        if (_buffer.isEmpty) break;
        final marker = _marker.firstMatch(_buffer);
        if (marker == null && !end && _partialMarker.hasMatch(_buffer)) break;
        final index = marker == null ? null : int.parse(marker[1]!) - 1;
        if (index != null && index >= 0 && index < count && _seen.add(index)) {
          _index = index;
          _started = false;
          _breakPending = false;
          _buffer = _buffer.substring(marker!.end);
        }
        _decided = true;
      }
      final newline = _buffer.indexOf('\n');
      _emit(newline < 0 ? _buffer : _buffer.substring(0, newline), updates);
      if (newline < 0) {
        _buffer = '';
        break;
      }
      _buffer = _buffer.substring(newline + 1);
      _decided = false;
      _breakPending = _started;
    }
    return updates;
  }

  void _emit(String piece, List<BatchItemUpdate> updates) {
    final index = _index;
    if (index == null) return;
    var text = _started ? piece : piece.trimLeft();
    if (text.isEmpty) return;
    if (_breakPending) {
      text = '\n$text';
      _breakPending = false;
    }
    _started = true;
    updates.add(BatchItemUpdate(index, text));
  }
}
