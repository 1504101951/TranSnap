import 'dart:async';

import 'package:flutter/material.dart';

import '../common/constants/selection_gesture_types.dart';
import '../common/constants/text_mode.dart';
import '../common/widgets/app_tooltip.dart';
import '../common/widgets/native_glass.dart';
import '../history/translation_history.dart';
import '../history/vocabulary.dart';
import '../overlay/translation_overlay.dart';
import '../platform/platform_event.dart';
import '../platform/platform_ports.dart';
import '../translation/language_direction.dart';
import '../translation/provider_selection.dart';
import '../translation/translation_types.dart';
import 'selection_session.dart';

class TranSnapApp extends StatefulWidget {
  const TranSnapApp({
    super.key,
    required this.selection,
    required this.overlay,
    required this.speech,
    required this.perf,
    required this.session,
    required this.history,
    required this.vocabulary,
  });

  final SelectionPort selection;
  final OverlayHost overlay;
  final SpeechPort speech;
  final PerformanceMarks perf;
  final SelectionSession session;
  final TranslationHistoryStore history;
  final VocabularyStore vocabulary;

  @override
  State<TranSnapApp> createState() => _TranSnapAppState();
}

class _TranSnapAppState extends State<TranSnapApp> {
  static const _triggerSize = TranslationOverlay.triggerWindowSize;
  late final StreamSubscription<PlatformEvent> _bridgeSubscription;

  (String, Size)? _sizedOverlay;

  String? _sourceAppName;

  String? _replaceSessionId;

  bool? _speakingSource;
  int _speechRequest = 0;

  @override
  void initState() {
    super.initState();
    _bridgeSubscription = widget.selection.events.listen(_onBridgeEvent);
    widget.session.addListener(_syncOverlaySize);
  }

  @override
  void dispose() {
    _bridgeSubscription.cancel();
    widget.session.removeListener(_syncOverlaySize);
    super.dispose();
  }

  void _onBridgeEvent(PlatformEvent event) {
    switch (event) {
      case SelectionCaptured(
        :final sessionId,
        :final text,
        :final gesture,
        :final readFailure,
        :final sourceAppName,
        :final x,
        :final y,
      ):
        final explicit =
            gesture == SelectionGestureTypes.hotkey ||
            gesture == SelectionGestureTypes.inputHotkey;
        if (widget.session.isExpanded && !explicit) {
          return;
        }
        Tooltip.dismissAllToolTips();
        _sourceAppName = sourceAppName;
        _resetSpeech();
        _replaceSessionId = gesture == SelectionGestureTypes.inputHotkey
            ? sessionId
            : null;
        widget.session.begin(
          sessionId: sessionId,
          text: text,
          input: gesture == SelectionGestureTypes.inputHotkey,
          readFailure: readFailure,
          awaitSelection:
              gesture == SelectionGestureTypes.selectAll ||
              gesture == SelectionGestureTypes.keyboard ||
              explicit,
        );
        if (widget.session.snapshot.phase != TranslationPhase.trigger) {
          widget.overlay.hideOverlay(sessionId: sessionId);
          return;
        }
        final size = explicit ? _resultSize() : _triggerSize;
        if (explicit) {
          final needsRead =
              gesture == SelectionGestureTypes.hotkey && text.trim().isEmpty;
          unawaited(_activate(readSelection: needsRead));
        }
        if (_replaceSessionId == sessionId) return;
        widget.overlay.showOverlay(
          sessionId: sessionId,
          x: x,
          y: y,
          width: size.width,
          height: size.height,
        );
      case SelectionInvalidated(:final sessionId):
        if (widget.session.isExpanded ||
            widget.session.sessionId != sessionId) {
          return;
        }
        _dismiss();
      case EscapePressed(:final sessionId):
        if (widget.session.sessionId != sessionId) return;
        _dismiss();
      case UnknownBridgeEvent():
        break;
    }
  }

  Size _resultSize() => TranslationOverlay.cardSize;

  void _syncOverlaySize() {
    final id = widget.session.sessionId;
    if (id == null || id == _replaceSessionId) return;
    final phase = widget.session.snapshot.phase;
    if (phase == TranslationPhase.idle) {
      widget.overlay.hideOverlay(sessionId: id);
      return;
    }
    final size = phase == TranslationPhase.trigger
        ? _triggerSize
        : _resultSize();
    if (_sizedOverlay == (id, size)) return;
    _sizedOverlay = (id, size);
    widget.overlay.setOverlaySize(
      sessionId: id,
      width: size.width,
      height: size.height,
    );
  }

  Future<void> _activate({bool readSelection = true}) async {
    final id = widget.session.sessionId;
    final retry = widget.session.canRetry;
    if (id == null ||
        (!retry && widget.session.snapshot.phase != TranslationPhase.trigger)) {
      return;
    }
    await widget.overlay.retainOverlay(sessionId: id);
    if (widget.session.sessionId != id ||
        (retry
            ? !widget.session.canRetry
            : widget.session.snapshot.phase != TranslationPhase.trigger)) {
      return;
    }
    final activeProvider = retry
        ? widget.session.activeProvider
        : _replaceSessionId == id
        ? widget.session.inputProvider
        : widget.session.provider;
    final activeLanguage = retry
        ? widget.session.activeLanguage
        : _replaceSessionId == id
        ? widget.session.inputLanguage
        : widget.session.language;
    final sourceLabel = _sourceAppName;
    final watch = _replaceSessionId == id ? (Stopwatch()..start()) : null;
    void markFirstToken() {
      if (widget.session.snapshot.translatedText.isEmpty) return;
      widget.session.removeListener(markFirstToken);
      unawaited(widget.perf.perfMark('input-first-token', watch!));
    }

    if (watch != null) widget.session.addListener(markFirstToken);
    if (retry) {
      await widget.session.retry();
    } else {
      await widget.session.activate(
        readSelection: readSelection
            ? () => widget.selection.readSelectionForTranslation(sessionId: id)
            : null,
      );
    }
    if (watch != null) {
      widget.session.removeListener(markFirstToken);
      if (widget.session.sessionId == id &&
          widget.session.snapshot.phase == TranslationPhase.completed) {
        unawaited(widget.perf.perfMark('input-complete', watch));
      }
    }
    _record(id, activeProvider, activeLanguage, sourceLabel);
    if (_replaceSessionId == id) await _finishInput(id);
  }

  Future<void> _finishInput(String id) async {
    if (widget.session.sessionId != id) return;
    final snapshot = widget.session.snapshot;
    final String? failure;
    if (snapshot.phase == TranslationPhase.completed) {
      final replace = Stopwatch()..start();
      failure = await widget.selection.replaceSelection(
        sessionId: id,
        text: snapshot.translatedText,
      );
      unawaited(widget.perf.perfMark('input-replace', replace));
    } else {
      failure = snapshot.message ?? '翻译失败';
    }
    if (widget.session.sessionId != id) return;
    if (failure != null) {
      await widget.selection.showInputFailure(sessionId: id, message: failure);
    }
    _dismiss();
  }

  void _addVocabulary() {
    final session = widget.session;
    final definition = session.definition;
    if (definition == null) return;
    try {
      widget.vocabulary.add(
        VocabularyEntry(
          word: session.snapshot.sourceText.trim(),
          translation: session.snapshot.translatedText,
          definition: definition,
          addedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      session.markSavedToVocabulary();
    } catch (error) {
      debugPrint('保存生词失败: $error');
    }
  }

  void _resetSpeech({bool rebuild = true}) {
    _speechRequest++;
    unawaited(widget.speech.stopSpeech());
    if (_speakingSource == null) return;
    if (rebuild && mounted) {
      setState(() => _speakingSource = null);
    } else {
      _speakingSource = null;
    }
  }

  Future<void> _speak(bool source) async {
    final snapshot = widget.session.snapshot;
    final primary = widget.session.activeLanguage.primaryCode;
    final language = source
        ? snapshot.detectedLanguage ?? primary
        : widget.session.outputLanguage ?? primary;
    final request = ++_speechRequest;
    final optimistic = _speakingSource == source ? null : source;
    setState(() => _speakingSource = optimistic);
    try {
      final active = await widget.speech.toggleSpeech(
        text: source ? snapshot.sourceText : snapshot.translatedText,
        language: language,
      );
      if (!mounted || _speechRequest != request) return;
      final synced = active ? source : null;
      if (_speakingSource != synced) {
        setState(() => _speakingSource = synced);
      }
    } catch (_) {
      if (mounted && _speechRequest == request && _speakingSource != null) {
        setState(() => _speakingSource = null);
      }
    }
  }

  Future<void> _switchMode(TextMode mode) async {
    final id = widget.session.sessionId;
    if (id == null) return;
    _resetSpeech();
    final sourceLabel = _sourceAppName;
    await widget.session.switchMode(mode);
    _record(
      id,
      widget.session.activeProvider,
      widget.session.activeLanguage,
      sourceLabel,
    );
  }

  Future<void> _switchService(String serviceId) async {
    final id = widget.session.sessionId;
    if (id == null) return;
    _resetSpeech();
    final sourceLabel = _sourceAppName;
    await widget.session.switchService(serviceId);
    _record(
      id,
      widget.session.activeProvider,
      widget.session.activeLanguage,
      sourceLabel,
    );
  }

  Future<void> _switchLanguages(String? source, String target) async {
    final id = widget.session.sessionId;
    if (id == null) return;
    _resetSpeech();
    final sourceLabel = _sourceAppName;
    await widget.session.switchLanguages(source: source, target: target);
    _record(
      id,
      widget.session.activeProvider,
      widget.session.activeLanguage,
      sourceLabel,
    );
  }

  void _record(
    String id,
    TranslationProvider provider,
    LanguageDirection language,
    String? sourceLabel,
  ) {
    if (widget.session.sessionId != id ||
        widget.session.mode != TextMode.translate ||
        widget.session.snapshot.phase != TranslationPhase.completed) {
      return;
    }
    widget.history.insert(
      sourceText: widget.session.snapshot.sourceText,
      translatedText: widget.session.snapshot.translatedText,
      detectedLanguage: widget.session.snapshot.detectedLanguage ?? '',
      targetLanguage:
          widget.session.outputLanguage ??
          language
              .resolve(widget.session.snapshot.detectedLanguage)
              .targetLanguage,
      providerId: provider.id,
      model: translationHistoryModel(provider),
      sourceLabel: sourceLabel,
      completedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  void _dismiss() {
    Tooltip.dismissAllToolTips();
    unawaited(widget.overlay.hideOverlayTooltip());
    final id = widget.session.sessionId;
    _resetSpeech(rebuild: false);
    widget.session.dismiss();
    if (id != null) {
      widget.overlay.hideOverlay(sessionId: id);
    }
  }

  @override
  Widget build(BuildContext context) {
    return NativeGlassApp(
      title: 'TranSnap',
      home: AppTooltipScope(
        onShow: (message, anchor, preferAbove) {
          final id = widget.session.sessionId;
          if (id == null) return;
          unawaited(
            widget.overlay.showOverlayTooltip(
              sessionId: id,
              message: message,
              x: anchor.left,
              y: anchor.top,
              width: anchor.width,
              height: anchor.height,
              preferAbove: preferAbove,
            ),
          );
        },
        onHide: () => unawaited(widget.overlay.hideOverlayTooltip()),
        child: TranslationOverlay(
          session: widget.session,
          speakingSource: _speakingSource,
          onActivate: _activate,
          onDismiss: _dismiss,
          onMode: (mode) => unawaited(_switchMode(mode)),
          onService: (serviceId) => unawaited(_switchService(serviceId)),
          onLanguages: (source, target) =>
              unawaited(_switchLanguages(source, target)),
          onSpeak: (source) => unawaited(_speak(source)),
          onAddVocabulary: _addVocabulary,
          onDrag: () {
            final id = widget.session.sessionId;
            if (id != null) widget.overlay.dragOverlay(sessionId: id);
          },
        ),
      ),
    );
  }
}
