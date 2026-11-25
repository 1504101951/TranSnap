import 'dart:async';

import 'package:characters/characters.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../common/constants/selection_gesture_types.dart';
import '../common/constants/text_limits.dart';
import '../common/constants/text_mode.dart';
import '../settings/service_config.dart';
import '../translation/language_direction.dart';
import '../translation/segmented_translation.dart';
import '../translation/translation_types.dart';

class SelectionSession extends ChangeNotifier {
  SelectionSession({
    required this.provider,
    required this.detectLanguage,
    LanguageDirection? language,
    LanguageDirection? inputLanguage,
    TranslationProvider? inputProvider,
    Future<String?> Function(String text)? lookupDefinition,
  }) : inputProvider = inputProvider ?? provider,
       language = language ?? LanguageDirection.systemDefault(),
       inputLanguage =
           inputLanguage ?? language ?? LanguageDirection.systemDefault(),
       lookupDefinition = lookupDefinition ?? _noDefinition;

  static Future<String?> _noDefinition(String text) async => null;

  static final _latinTerm = RegExp(
    r"^[A-Za-z][A-Za-z'’-]*(?: [A-Za-z][A-Za-z'’-]*){0,2}$",
  );

  static final _cjkTerm = RegExp(r'^[\u4e00-\u9fff]{1,4}$');

  static bool isDictionaryTerm(String text) {
    final term = text.trim();
    return term.length <= 40 &&
        (_latinTerm.hasMatch(term) || _cjkTerm.hasMatch(term));
  }

  static const selectionLimit = TextLimits.translationInput;

  TranslationProvider provider;
  LanguageDirection language;

  LanguageDirection inputLanguage;

  TranslationProvider inputProvider;

  bool _input = false;

  String? _readFailure;
  final Future<String?> Function(String text) detectLanguage;

  final Future<String?> Function(String text) lookupDefinition;

  String? definition;

  bool savedToVocabulary = false;

  TranslationSnapshot snapshot = TranslationSnapshot.idle;
  String? sessionId;

  TextMode mode = TextMode.translate;

  TranslationProvider? Function(TextMode mode) assistProviderFor = (_) => null;

  TranslationProvider? Function(String serviceId, TextMode mode)
  serviceProviderFor = (_, _) => null;

  List<ServiceChoice> Function() get serviceChoices => _serviceChoices;

  set serviceChoices(List<ServiceChoice> Function() value) {
    _serviceChoices = value;
    notifyListeners();
  }

  List<ServiceChoice> Function() _serviceChoices = () => const [
    (
      id: ServiceConfig.systemId,
      name: ServiceConfig.systemName,
      isModel: false,
      isDefault: true,
    ),
  ];

  String? serviceOverride;
  String? sourceOverride;
  String? targetOverride;

  static const assistUnavailable =
      '润色、纠错与解释需要模型服务（OpenAI、DeepSeek 或 Anthropic）；可在卡片上切换服务，或把默认翻译服务设为模型服务。';

  bool get isExpanded =>
      snapshot.phase != TranslationPhase.idle &&
      snapshot.phase != TranslationPhase.trigger;

  TranslationProgress? _progress;
  TranslationProvider? _activeProvider;
  LanguageDirection? _activeLanguage;

  bool get canRetry =>
      snapshot.phase == TranslationPhase.failed && _progress != null;

  TranslationProvider get activeProvider => _activeProvider ?? provider;

  String? dismissIfServiceRemoved(Set<String> serviceIds) {
    if (!isExpanded) return null;
    final selected = serviceOverride ?? activeProvider.id;
    if (selected == ServiceConfig.builtinId ||
        selected == ServiceConfig.systemId ||
        serviceIds.contains(selected)) {
      return null;
    }
    final closedId = sessionId;
    dismiss();
    return closedId;
  }

  LanguageDirection get activeLanguage => _activeLanguage ?? language;

  String? get outputLanguage => _progress?.request.targetLanguage;

  bool get sourceIsTarget {
    final target = outputLanguage;
    return mode == TextMode.translate &&
        target != null &&
        LanguageDirection.isTarget(snapshot.detectedLanguage, target);
  }

  int _generation = 0;
  StreamSubscription<TranslationEvent>? _translation;
  Completer<void>? _completion;

  void begin({
    required String sessionId,
    required String? text,
    bool awaitSelection = false,
    bool input = false,
    String? readFailure,
  }) {
    this.sessionId = sessionId;
    _input = input;
    _readFailure = readFailure;
    _cancelTranslation();
    mode = TextMode.translate;
    serviceOverride = null;
    sourceOverride = null;
    targetOverride = null;
    if (!awaitSelection && (text == null || text.trim().isEmpty)) {
      snapshot = TranslationSnapshot.idle;
      notifyListeners();
      return;
    }
    snapshot = TranslationSnapshot(
      phase: TranslationPhase.trigger,
      sourceText: text ?? '',
      translatedText: '',
    );
    notifyListeners();
  }

  Future<void> activate({Future<String?> Function()? readSelection}) async {
    if (snapshot.phase != TranslationPhase.trigger) return;

    final generation = _generation;
    final activeProvider = _activeProvider = _input ? inputProvider : provider;
    final activeLanguage = _activeLanguage = _input ? inputLanguage : language;
    var source = snapshot.sourceText;
    snapshot = TranslationSnapshot(
      phase: TranslationPhase.translating,
      sourceText: source,
      translatedText: '',
    );
    notifyListeners();

    try {
      if (readSelection != null) {
        final text = await readSelection();
        if (generation != _generation) return;
        source = text ?? '';
        snapshot = TranslationSnapshot(
          phase: TranslationPhase.translating,
          sourceText: source,
          translatedText: '',
        );
        notifyListeners();
      }
    } on PlatformException catch (error) {
      if (generation != _generation) return;
      snapshot = snapshot.copyWith(
        phase: TranslationPhase.failed,
        message: error.code == SelectionReadFailures.secureField
            ? '密码框中的文字不会被读取。'
            : '无法准备选区翻译：${error.message ?? error.code}',
      );
      notifyListeners();
      return;
    } catch (error) {
      if (generation != _generation) return;
      snapshot = snapshot.copyWith(
        phase: TranslationPhase.failed,
        message: '无法准备选区翻译：$error',
      );
      notifyListeners();
      return;
    }
    await _translateSource(source, generation, activeProvider, activeLanguage);
  }

  Future<void> switchMode(TextMode mode) => _reprocess(mode, serviceOverride);

  Future<void> switchService(String serviceId) => _reprocess(mode, serviceId);

  Future<void> switchLanguages({
    required String? source,
    required String target,
  }) {
    if (!isExpanded || snapshot.phase == TranslationPhase.translating) {
      return Future.value();
    }
    sourceOverride = source;
    targetOverride = target;
    return _reprocess(mode, serviceOverride);
  }

  Future<void> _reprocess(TextMode mode, String? serviceId) async {
    if (!isExpanded || snapshot.phase == TranslationPhase.translating) return;
    final source = snapshot.sourceText;
    final language = activeLanguage;
    _cancelTranslation();
    this.mode = mode;
    serviceOverride = serviceId;
    final generation = _generation;
    final provider = serviceId != null
        ? serviceProviderFor(serviceId, mode)
        : mode == TextMode.translate
        ? this.provider
        : assistProviderFor(mode);
    if (provider == null) {
      snapshot = TranslationSnapshot(
        phase: TranslationPhase.failed,
        sourceText: source,
        translatedText: '',
        message: assistUnavailable,
      );
      notifyListeners();
      return;
    }
    _activeProvider = provider;
    _activeLanguage = language;
    snapshot = TranslationSnapshot(
      phase: TranslationPhase.translating,
      sourceText: source,
      translatedText: '',
    );
    notifyListeners();
    await _translateSource(source, generation, provider, language);
  }

  Future<void> _translateSource(
    String source,
    int generation,
    TranslationProvider provider,
    LanguageDirection language,
  ) async {
    if (source.trim().isEmpty) {
      snapshot = snapshot.copyWith(
        phase: TranslationPhase.failed,
        message: _readFailure == SelectionReadFailures.secureField
            ? '密码框中的文字不会被读取。'
            : '未读取到选中文字，请重新选择后使用翻译快捷键。',
      );
      notifyListeners();
      return;
    }
    if (source.characters.length > selectionLimit) {
      snapshot = TranslationSnapshot(
        phase: TranslationPhase.sizeLimited,
        sourceText: source,
        translatedText: '',
        message: '选区超过 50,000 个字符，未发送翻译请求。',
      );
      notifyListeners();
      return;
    }
    final String? detected;
    try {
      detected = sourceOverride ?? await detectLanguage(source);
    } catch (error) {
      if (generation != _generation) return;
      snapshot = snapshot.copyWith(
        phase: TranslationPhase.failed,
        message: '无法准备选区翻译：$error',
      );
      notifyListeners();
      return;
    }
    if (generation != _generation) return;
    final direction = language.resolve(detected);
    snapshot = snapshot.copyWith(detectedLanguage: direction.detectedLanguage);
    final request = TranslationRequest(
      sourceText: source,
      detectedLanguage: direction.detectedLanguage,
      targetLanguage: switch (mode) {
        TextMode.translate => targetOverride ?? direction.targetLanguage,
        TextMode.explain => language.primaryCode,
        TextMode.polish || TextMode.correct =>
          direction.detectedLanguage ??
              LanguageDirection.normalize(language.primaryCode),
      },
    );

    if (mode == TextMode.translate && isDictionaryTerm(source)) {
      unawaited(_lookup(source.trim(), generation));
    }
    _progress = TranslationProgress(request);
    await _runTranslation(provider, _progress!);
  }

  void markSavedToVocabulary() {
    savedToVocabulary = true;
    notifyListeners();
  }

  Future<void> _lookup(String term, int generation) async {
    final found = await lookupDefinition(term);
    if (generation != _generation || found == null) return;
    definition = found;
    notifyListeners();
  }

  Future<void> retry() async {
    if (!canRetry) return;
    final progress = _progress!;
    snapshot = snapshot.copyWith(
      phase: TranslationPhase.translating,
      translatedText: progress.completedText,
      pairs: List.unmodifiable(progress.pairs),
    );
    notifyListeners();
    await _translation?.cancel();
    if (!identical(progress, _progress)) return;
    await _runTranslation(_activeProvider!, progress);
  }

  Future<void> _runTranslation(
    TranslationProvider activeProvider,
    TranslationProgress progress,
  ) async {
    final generation = _generation;
    final completion = Completer<void>();
    _completion = completion;
    _translation =
        translateSegmented(
          activeProvider.translate,
          progress.request,
          progress: progress,
          usesSlidingContext: activeProvider.usesSlidingContext,
        ).listen(
          (event) {
            if (generation != _generation) return;
            switch (event) {
              case TranslationUpdate(:final addition):
                snapshot = snapshot.copyWith(
                  phase: TranslationPhase.translating,
                  translatedText: snapshot.translatedText + addition,
                  pairs: const [],
                  message: null,
                );
              case TranslationCompleted(:final pairs):
                snapshot = snapshot.copyWith(
                  phase: TranslationPhase.completed,
                  pairs: pairs,
                  message: null,
                );
              case TranslationFailure(:final message):
                snapshot = snapshot.copyWith(
                  phase: TranslationPhase.failed,
                  translatedText: progress.completedText,
                  pairs: List.unmodifiable(progress.pairs),
                  message: message,
                );
            }
            notifyListeners();
            if ((event is TranslationCompleted ||
                    event is TranslationFailure) &&
                !completion.isCompleted) {
              completion.complete();
            }
          },
          onDone: () {
            if (!completion.isCompleted) completion.complete();
            if (generation == _generation) {
              _translation = null;
              _completion = null;
            }
          },
        );
    await completion.future;
  }

  void dismiss() {
    _cancelTranslation();
    sessionId = null;
    serviceOverride = null;
    sourceOverride = null;
    targetOverride = null;
    snapshot = TranslationSnapshot.idle;
    notifyListeners();
  }

  void _cancelTranslation() {
    _generation += 1;
    definition = null;
    savedToVocabulary = false;
    _progress = null;
    _activeProvider = null;
    _activeLanguage = null;
    unawaited(_translation?.cancel());
    _translation = null;
    final completion = _completion;
    _completion = null;
    if (completion != null && !completion.isCompleted) completion.complete();
  }

  @override
  void dispose() {
    _cancelTranslation();
    super.dispose();
  }
}
