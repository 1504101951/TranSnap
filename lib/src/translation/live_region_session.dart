import 'dart:async';

import 'package:characters/characters.dart';
import 'package:flutter/foundation.dart';

import '../common/constants/live_region.dart';
import '../common/constants/text_limits.dart';
import '../settings/app_settings.dart';
import 'language_direction.dart';
import 'live_block_cache.dart';
import 'translation_http.dart';
import 'translation_types.dart';

abstract final class LiveRegionSchedule {
  static const streamPublishInterval = Duration(milliseconds: 100);
  static const candidateCoalescingDelay = Duration(milliseconds: 200);
  static const requestStartInterval = Duration(milliseconds: 500);
  static const maxInflightBatches = 3;
  static const cacheBudgetBytes = 100 * 1024 * 1024;
  static const transientRetryLimit = 3;
  static const rateLimitBackoff = [
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
  ];
  static const maxRetryAfter = Duration(seconds: 60);
}

abstract class LiveRegionClock {
  DateTime now();

  void schedule(Duration delay, void Function() fire);

  void cancelSchedule();
}

final class SystemLiveRegionClock implements LiveRegionClock {
  final Stopwatch _watch = Stopwatch()..start();
  Timer? _timer;

  @override
  DateTime now() =>
      DateTime.fromMillisecondsSinceEpoch(_watch.elapsedMilliseconds);

  @override
  void schedule(Duration delay, void Function() fire) {
    _timer?.cancel();
    _timer = Timer(delay, fire);
  }

  @override
  void cancelSchedule() {
    _timer?.cancel();
    _timer = null;
  }
}

class LiveTextBlock {
  const LiveTextBlock({
    required this.text,
    this.x,
    this.y,
    this.width,
    this.height,
  });

  factory LiveTextBlock.fromMap(Map<Object?, Object?> map) => LiveTextBlock(
    text: '${map['text'] ?? ''}',
    x: (map['x'] as num?)?.toDouble(),
    y: (map['y'] as num?)?.toDouble(),
    width: (map['width'] as num?)?.toDouble(),
    height: (map['height'] as num?)?.toDouble(),
  );

  final String text;
  final double? x;
  final double? y;
  final double? width;
  final double? height;

  bool get placeable =>
      x != null &&
      y != null &&
      width != null &&
      height != null &&
      width! > 0 &&
      height! > 0;
}

class LiveOcrSample {
  const LiveOcrSample({
    required this.generation,
    this.text,
    this.failure,
    this.blocks = const [],
  });

  final int generation;
  final String? text;
  final String? failure;
  final List<LiveTextBlock> blocks;
}

class LiveRegionView {
  const LiveRegionView({
    required this.phase,
    required this.status,
    this.failed = false,
    this.overlays = const [],
    this.metrics = const [],
  });

  static const idle = LiveRegionView(phase: LiveRegionPhase.idle, status: '');

  final LiveRegionPhase phase;
  final String status;

  final bool failed;

  final List<Map<String, Object>> overlays;

  final List<Map<String, Object>> metrics;

  Map<String, Object?> toMap() => {
    'phase': phase.name,
    'status': status,
    'failed': failed,
    'overlays': overlays,
    'metrics': metrics,
  };
}

class _Paragraph {
  _Paragraph(this.text, this.observedAt, {required this.immediate});

  final String text;
  final DateTime observedAt;
  final bool immediate;
  var places = <LiveTextBlock>[];

  var shown = '';

  var done = false;

  var alone = false;
}

class _Batch {
  _Batch(this.texts, this.keys, this.startedAt, this.wait)
    : partial = [for (final _ in texts) StringBuffer()];

  final List<String> texts;
  final List<String> keys;
  final List<StringBuffer> partial;
  final DateTime startedAt;
  final Duration wait;

  DateTime? firstAt;
  StreamSubscription<BatchTranslationEvent>? subscription;
  var cancelled = false;
}

class LiveRegionSession {
  LiveRegionSession({
    required this.providerFor,
    required this.detectLanguage,
    required this.clock,
    this.onView,
    this.inputLimit = TextLimits.translationInput,
  });

  final BatchTranslationProvider Function(AppSettings settings) providerFor;
  final Future<String?> Function(String text) detectLanguage;
  final LiveRegionClock clock;
  final void Function(LiveRegionView view)? onView;
  final int inputLimit;

  LiveRegionView view = LiveRegionView.idle;

  final _cache = LiveBlockCache(
    budgetBytes: LiveRegionSchedule.cacheBudgetBytes,
  );
  final _inflight = <_Batch>[];
  var _metrics = <Map<String, Object>>[];
  var _paragraphs = <String, _Paragraph>{};
  var _generation = 0;
  var _phase = LiveRegionPhase.idle;
  var _notice = '';
  String? _halt;
  String? _lastError;
  AppSettings? _latestSettings;
  var _firstNonEmpty = true;

  LiveRegionView? _sent;

  Timer? _streamTimer;
  var _streamPending = false;
  DateTime? _lastBatchStart;

  DateTime? _rateLimitedUntil;
  var _rateLimitStreak = 0;
  var _epoch = 0;
  var _pending = 0;
  final List<Completer<void>> _waiters = [];

  void start(AppSettings settings, int generation) {
    if (generation <= _generation && _phase != LiveRegionPhase.idle) return;
    _epoch += 1;
    _pending = 0;
    for (final waiter in List<Completer<void>>.of(_waiters)) {
      if (!waiter.isCompleted) waiter.complete();
    }
    _waiters.clear();
    _release();
    _generation = generation;
    _phase = LiveRegionPhase.running;
    _latestSettings = settings;
    _paragraphs = {};
    _sent = null;
    _firstNonEmpty = true;
    _lastBatchStart = null;
    _rateLimitedUntil = null;
    _rateLimitStreak = 0;
    _halt = null;
    _lastError = null;
    _notice = '正在识别';
    _publish();
  }

  void pause(int generation) {
    if (_phase != LiveRegionPhase.running || generation <= _generation) return;
    _generation = generation;
    clock.cancelSchedule();
    _phase = LiveRegionPhase.paused;
    _cancelAll();
    _publish();
  }

  void resume(int generation) {
    if (_phase != LiveRegionPhase.paused || generation <= _generation) return;
    _generation = generation;
    _phase = LiveRegionPhase.running;
    _publish();
  }

  void end(int generation) {
    if (_phase == LiveRegionPhase.idle ||
        _phase == LiveRegionPhase.discarded ||
        generation <= _generation) {
      return;
    }
    _generation = generation;
    _phase = LiveRegionPhase.ended;
    _release();
    _publish();
  }

  void discard(int generation) {
    if (generation <= _generation && _phase != LiveRegionPhase.idle) return;
    _generation = generation;
    _phase = LiveRegionPhase.discarded;
    _paragraphs = {};
    _notice = '';
    _halt = null;
    _lastError = null;
    _release();
    _publish();
  }

  void captureUnavailable(int generation, String message) {
    if (_phase != LiveRegionPhase.running && _phase != LiveRegionPhase.paused) {
      return;
    }
    if (generation <= _generation) return;
    _generation = generation;
    _phase = LiveRegionPhase.ended;
    _paragraphs = {};
    _notice = message;
    _halt = null;
    _lastError = null;
    _release();
    _publish();
  }

  void noteSettings(AppSettings settings) {
    _latestSettings = settings;
  }

  Future<void> onOcr(LiveOcrSample sample) async {
    _applyOcr(sample);
    await settle();
  }

  Future<void> settle() {
    if (_pending == 0) return Future<void>.value();
    final waiter = Completer<void>();
    _waiters.add(waiter);
    return waiter.future;
  }

  void _applyOcr(LiveOcrSample sample) {
    if (sample.generation != _generation || _phase != LiveRegionPhase.running) {
      return;
    }
    if (sample.failure != null) {
      _clearScreen(sample.failure!);
      return;
    }
    final blocks = [
      for (final block
          in sample.blocks.isEmpty
              ? [LiveTextBlock(text: sample.text ?? '')]
              : sample.blocks)
        if (block.text.trim().isNotEmpty) block,
    ];
    if (blocks.isEmpty) {
      _clearScreen('未识别到文字');
      return;
    }
    final now = clock.now();
    final immediate = _firstNonEmpty;
    _firstNonEmpty = false;
    final settings = _latestSettings!;
    final next = <String, _Paragraph>{};
    for (final block in blocks) {
      var paragraph = next[block.text];
      if (paragraph == null) {
        paragraph =
            _paragraphs[block.text] ??
            _appear(block.text, now, settings, immediate: immediate);
        paragraph.places = [];
        next[block.text] = paragraph;
      }
      paragraph.places.add(block);
    }
    _paragraphs = next;
    for (final batch in List<_Batch>.of(_inflight)) {
      if (!batch.texts.any(next.containsKey)) _cancel(batch);
    }
    _publish();
    _evaluate();
  }

  _Paragraph _appear(
    String text,
    DateTime now,
    AppSettings settings, {
    required bool immediate,
  }) {
    final paragraph = _Paragraph(text, now, immediate: immediate);
    final hit = _cache.translation(_key(settings, text));
    if (hit != null) {
      paragraph
        ..shown = hit
        ..done = true;
    }
    return paragraph;
  }

  void _clearScreen(String notice) {
    _paragraphs = {};
    _notice = notice;
    clock.cancelSchedule();
    _cancelAll();
    _publish();
  }

  void _evaluate() {
    if (_phase != LiveRegionPhase.running || _halt != null) {
      clock.cancelSchedule();
      return;
    }
    final settings = _latestSettings!;
    final now = clock.now();
    final ready = <_Paragraph>[];
    DateTime? nextDue;
    var rejected = false;
    for (final paragraph in _paragraphs.values) {
      if (paragraph.done || _sending(paragraph.text)) continue;
      final key = _key(settings, paragraph.text);
      if (_blocked(key)) continue;
      if (paragraph.text.characters.length > inputLimit) {
        _cache.reject(key);
        _lastError = '文字超过 50,000 个字符，未发送翻译请求。';
        rejected = true;
        continue;
      }
      final due = paragraph.immediate
          ? paragraph.observedAt
          : paragraph.observedAt.add(
              LiveRegionSchedule.candidateCoalescingDelay,
            );
      if (now.isBefore(due)) {
        if (nextDue == null || due.isBefore(nextDue)) nextDue = due;
        continue;
      }
      ready.add(paragraph);
    }
    if (rejected) _publish();
    if (ready.isEmpty) {
      if (nextDue == null) {
        clock.cancelSchedule();
      } else {
        clock.schedule(nextDue.difference(now), _evaluate);
      }
      return;
    }
    final limit = providerFor(settings).allowsParallelBatches
        ? LiveRegionSchedule.maxInflightBatches
        : 1;
    if (_inflight.length >= limit) {
      clock.cancelSchedule();
      return;
    }
    final limitedUntil = _rateLimitedUntil;
    if (limitedUntil != null && now.isBefore(limitedUntil)) {
      clock.schedule(limitedUntil.difference(now), _evaluate);
      return;
    }
    final lastStart = _lastBatchStart;
    if (lastStart != null) {
      final allowed = lastStart.add(LiveRegionSchedule.requestStartInterval);
      if (now.isBefore(allowed)) {
        clock.schedule(allowed.difference(now), _evaluate);
        return;
      }
    }
    final items = <_Paragraph>[];
    var chars = 0;
    for (final paragraph in ready) {
      if (paragraph.alone) {
        if (items.isEmpty) items.add(paragraph);
        break;
      }
      final length = paragraph.text.characters.length;
      if (items.isNotEmpty &&
          (items.length >= batchItemLimit || chars + length > batchCharLimit)) {
        break;
      }
      items.add(paragraph);
      chars += length;
    }
    _startBatch(items, settings);
    if (ready.length > items.length) {
      clock.schedule(LiveRegionSchedule.requestStartInterval, _evaluate);
    } else if (nextDue != null) {
      clock.schedule(nextDue.difference(now), _evaluate);
    } else {
      clock.cancelSchedule();
    }
  }

  void _startBatch(List<_Paragraph> items, AppSettings latest) {
    final settings = AppSettings.fromMap(latest.toMap());
    final texts = [for (final item in items) item.text];
    final now = clock.now();
    var wait = Duration.zero;
    for (final item in items) {
      final waited = now.difference(item.observedAt);
      if (waited > wait) wait = waited;
    }
    final batch = _Batch(
      texts,
      [for (final text in texts) _key(settings, text)],
      now,
      wait,
    );
    _inflight.add(batch);
    _lastBatchStart = now;
    _publish();
    final epoch = _epoch;
    _beginWork();
    unawaited(() async {
      try {
        final detected = await _detectEach(texts);
        if (epoch != _epoch) return;
        if (batch.cancelled) {
          _inflight.remove(batch);
          return;
        }
        final same = <int>[];
        final groups = <String, List<int>>{};
        final sources = <String, String?>{};
        for (final (index, language) in detected.indexed) {
          final direction = settings.direction.resolve(language);
          if (LanguageDirection.isTarget(
            direction.detectedLanguage,
            direction.targetLanguage,
          )) {
            same.add(index);
            continue;
          }
          (groups[direction.targetLanguage] ??= []).add(index);
          final source = sources.containsKey(direction.targetLanguage)
              ? sources[direction.targetLanguage]
              : direction.detectedLanguage;
          sources[direction.targetLanguage] =
              source == direction.detectedLanguage ? source : null;
        }

        _Batch part(List<int> indexes) => _Batch(
          [for (final index in indexes) batch.texts[index]],
          [for (final index in indexes) batch.keys[index]],
          batch.startedAt,
          batch.wait,
        );
        _inflight.remove(batch);
        final passthrough = same.isEmpty ? null : part(same);
        final requests = {
          for (final entry in groups.entries) entry.key: part(entry.value),
        };
        _inflight.addAll([?passthrough, ...requests.values]);
        if (passthrough != null) {
          for (final (index, text) in passthrough.texts.indexed) {
            passthrough.partial[index].write(text);
          }
          _complete(passthrough);
        }
        for (final MapEntry(key: target, value: request) in requests.entries) {
          _request(request, settings, sources[target], target);
        }
      } catch (_) {
        if (epoch != _epoch) return;
        if (batch.cancelled) {
          _inflight.remove(batch);
          return;
        }
        _fail(batch, '翻译准备失败，将自动重试。', TranslationFailureKind.transient);
      } finally {
        if (epoch == _epoch) _evaluate();
        _endWork(epoch);
      }
    }());
  }

  void _request(
    _Batch batch,
    AppSettings settings,
    String? detected,
    String target,
  ) {
    try {
      batch.subscription = providerFor(settings)
          .translateBatch(
            BatchTranslationRequest(
              texts: batch.texts,
              detectedLanguage: detected,
              targetLanguage: target,
            ),
            client: translationHttpClient,
          )
          .listen(
            (event) => _onEvent(batch, event),
            onError: (Object error) {
              _onEvent(
                batch,
                BatchFailure('$error', TranslationFailureKind.transient),
              );
            },
          );
    } catch (_) {
      _fail(batch, '翻译准备失败，将自动重试。', TranslationFailureKind.transient);
    }
  }

  void _onEvent(_Batch batch, BatchTranslationEvent event) {
    if (batch.cancelled || !_inflight.contains(batch)) return;
    switch (event) {
      case BatchItemUpdate(:final index, :final addition):
        batch.firstAt ??= clock.now();
        batch.partial[index].write(addition);
        final paragraph = _paragraphs[batch.texts[index]];
        if (paragraph == null || paragraph.done) return;
        paragraph.shown = batch.partial[index].toString();
        _publishStreaming();
      case BatchCompleted():
        _complete(batch);
      case BatchFailure(:final message, :final kind, :final retryAfter):
        _fail(batch, message, kind, retryAfter: retryAfter);
    }
  }

  void _complete(_Batch batch) {
    _rateLimitStreak = 0;
    for (final (index, text) in batch.texts.indexed) {
      final translation = batch.partial[index].toString().trim();
      final paragraph = _paragraphs[text];
      if (translation.isEmpty) {
        if (paragraph != null && !paragraph.done) paragraph.shown = '';
        if (batch.texts.length == 1) {
          _cache.reject(batch.keys[index]);
          _lastError = '服务未返回该段译文。';
        } else {
          paragraph?.alone = true;
        }
        continue;
      }
      _cache.store(batch.keys[index], translation);
      if (paragraph == null) continue;
      paragraph
        ..shown = translation
        ..done = true;
    }
    _measure(batch, 'completed');
    _finish(batch);
  }

  void _fail(
    _Batch batch,
    String message,
    TranslationFailureKind kind, {
    Duration? retryAfter,
  }) {
    for (final text in batch.texts) {
      final paragraph = _paragraphs[text];
      if (paragraph != null && !paragraph.done) paragraph.shown = '';
    }
    switch (kind) {
      case TranslationFailureKind.service:
        _halt = message;
      case TranslationFailureKind.paragraph:
        if (batch.texts.length == 1) {
          _cache.reject(batch.keys.single);
          _lastError = message;
        } else {
          for (final text in batch.texts) {
            _paragraphs[text]?.alone = true;
          }
        }
      case TranslationFailureKind.rateLimited:
        batch.keys.forEach(_cache.noteFailure);
        _lastError = message;
        const backoff = LiveRegionSchedule.rateLimitBackoff;
        final wait = retryAfter == null
            ? _rateLimitStreak < backoff.length
                  ? backoff[_rateLimitStreak]
                  : backoff.last
            : retryAfter > LiveRegionSchedule.maxRetryAfter
            ? LiveRegionSchedule.maxRetryAfter
            : retryAfter;
        _rateLimitStreak++;
        _rateLimitedUntil = clock.now().add(wait);
      case TranslationFailureKind.transient:
        batch.keys.forEach(_cache.noteFailure);
        _lastError = message;
    }
    _measure(batch, kind.name);
    _finish(batch);
  }

  void _finish(_Batch batch) {
    _inflight.remove(batch);
    unawaited(batch.subscription?.cancel());
    _publish();
    _evaluate();
  }

  void _cancel(_Batch batch) {
    if (batch.cancelled) return;
    batch.cancelled = true;
    _measure(batch, 'cancelled');
    final subscription = batch.subscription;
    if (subscription == null) return;
    final epoch = _epoch;
    _beginWork();
    unawaited(
      subscription.cancel().whenComplete(() {
        if (epoch != _epoch) return;
        _inflight.remove(batch);
        _evaluate();
        _endWork(epoch);
      }),
    );
  }

  void _cancelAll() {
    for (final batch in List<_Batch>.of(_inflight)) {
      _cancel(batch);
    }
  }

  void _release() {
    clock.cancelSchedule();
    for (final batch in _inflight) {
      batch.cancelled = true;
      unawaited(batch.subscription?.cancel());
    }
    _inflight.clear();
    _cache.clear();
  }

  void _measure(_Batch batch, String outcome) {
    final now = clock.now();
    _metrics.add({
      'blocks': batch.texts.length,
      'chars': batch.texts.fold<int>(0, (sum, text) => sum + text.length),
      'waitMs': batch.wait.inMilliseconds,
      'firstMs':
          batch.firstAt?.difference(batch.startedAt).inMilliseconds ?? -1,
      'totalMs': now.difference(batch.startedAt).inMilliseconds,
      'inflight': _inflight.length,
      'outcome': outcome,
    });
  }

  void _beginWork() => _pending += 1;

  void _endWork(int epoch) {
    if (epoch != _epoch) return;
    _pending -= 1;
    if (_pending > 0) return;
    final waiters = List<Completer<void>>.of(_waiters);
    _waiters.clear();
    for (final waiter in waiters) {
      if (!waiter.isCompleted) waiter.complete();
    }
  }

  String _key(AppSettings settings, String text) {
    final direction = settings.direction;
    return '${settings.defaultServiceId}\n${direction.primaryCode}\n'
        '${direction.secondaryCode ?? ''}\n$text';
  }

  bool _blocked(String key) =>
      _cache.rejected(key) ||
      _cache.failures(key) > LiveRegionSchedule.transientRetryLimit;

  bool _sending(String text) =>
      _inflight.any((batch) => !batch.cancelled && batch.texts.contains(text));

  bool _containsCjk(String text) => RegExp(r'[㐀-鿿]').hasMatch(text);

  Future<List<String?>> _detectEach(List<String> texts) async {
    final hanzi = texts.where(_containsCjk).toList();
    final others = [
      for (final text in texts)
        if (!_containsCjk(text)) text,
    ];
    final hanziLanguage = hanzi.isEmpty
        ? null
        : await detectLanguage(hanzi.join('\n')) ?? 'zh-Hans';
    final each = await Future.wait(others.map(detectLanguage));
    final merged = each.contains(null)
        ? await detectLanguage(others.join('\n'))
        : null;
    final languages = {
      for (final (index, text) in others.indexed) text: each[index] ?? merged,
    };
    return [
      for (final text in texts)
        _containsCjk(text) ? hanziLanguage : languages[text],
    ];
  }

  bool _isFailure(String status) => status == _halt || status == _lastError;

  String _status() {
    if (_halt != null) return _halt!;
    if (_paragraphs.isEmpty) return _notice;
    if (_inflight.any((batch) => !batch.cancelled)) return '正在翻译';
    final settings = _latestSettings!;
    final unfinished = [
      for (final paragraph in _paragraphs.values)
        if (!paragraph.done) paragraph,
    ];
    if (unfinished.isEmpty) return '已完成';
    final waiting = unfinished.any(
      (paragraph) => !_blocked(_key(settings, paragraph.text)),
    );
    return waiting ? '等待翻译' : _lastError ?? '等待翻译';
  }

  List<Map<String, Object>> _overlayMaps() {
    if (_phase != LiveRegionPhase.running) return const [];
    final maps = <Map<String, Object>>[];
    for (final paragraph in _paragraphs.values) {
      final text = paragraph.shown;
      if (text.isEmpty || text.trim() == paragraph.text.trim()) continue;
      for (final place in paragraph.places) {
        if (!place.placeable) continue;
        maps.add({
          'text': text,
          'x': place.x!,
          'y': place.y!,
          'width': place.width!,
          'height': place.height!,
        });
      }
    }
    return maps;
  }

  void _publish() {
    _streamTimer?.cancel();
    _streamTimer = null;
    _streamPending = false;
    _send();
  }

  void _publishStreaming() {
    if (_streamTimer != null) {
      _streamPending = true;
      final status = _status();
      view = LiveRegionView(
        phase: _phase,
        status: status,
        failed: _isFailure(status),
        overlays: _overlayMaps(),
      );
      return;
    }
    _send();
    _streamTimer = Timer(LiveRegionSchedule.streamPublishInterval, () {
      _streamTimer = null;
      if (_streamPending) _publish();
    });
  }

  void _send() {
    final metrics = _metrics;
    _metrics = [];
    final previous = _sent;
    final status = _status();
    view = LiveRegionView(
      phase: _phase,
      status: status,
      failed: _isFailure(status),
      overlays: _overlayMaps(),
      metrics: metrics,
    );
    if (previous != null &&
        metrics.isEmpty &&
        previous.phase == view.phase &&
        previous.status == view.status &&
        _sameOverlays(previous.overlays, view.overlays)) {
      return;
    }
    _sent = view;
    onView?.call(view);
  }

  static bool _sameOverlays(
    List<Map<String, Object>> a,
    List<Map<String, Object>> b,
  ) {
    if (a.length != b.length) return false;
    for (var index = 0; index < a.length; index++) {
      if (!mapEquals(a[index], b[index])) return false;
    }
    return true;
  }
}
