import '../common/widgets/line_icon.dart';
import '../common/constants/glass_metrics.dart';
import '../common/constants/motion_metrics.dart';
import '../common/constants/text_mode.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../common/widgets/app_motion.dart';
import '../common/widgets/app_tooltip.dart';
import '../common/widgets/native_glass.dart';

import '../selection/selection_session.dart';
import '../settings/app_settings.dart';
import 'dictionary_definition.dart';
import '../translation/translation_types.dart';

class TranslationOverlay extends StatefulWidget {
  const TranslationOverlay({
    super.key,
    required this.session,
    required this.onActivate,
    required this.onDismiss,
    required this.onDrag,
    required this.onMode,
    required this.onService,
    required this.onLanguages,
    required this.onSpeak,
    required this.onAddVocabulary,
    this.speakingSource,
  });

  static const triggerSize = Size(84, 30);
  static const triggerWindowSize = Size(84, 32);
  final SelectionSession session;
  final VoidCallback onActivate;
  final VoidCallback onDismiss;
  final VoidCallback onDrag;
  final ValueChanged<TextMode> onMode;

  final ValueChanged<String> onService;
  final void Function(String? source, String target) onLanguages;

  final ValueChanged<bool> onSpeak;

  final VoidCallback onAddVocabulary;

  final bool? speakingSource;

  static const modeLabels = {
    TextMode.translate: '翻译',
    TextMode.polish: '润色',
    TextMode.correct: '纠错',
    TextMode.explain: '解释',
  };

  static const cardSize = Size(720, 420);
  static const autoLanguage = 'auto';

  static TextStyle textStyleFor({required bool dictionary}) => TextStyle(
    fontSize: 15,
    height: 22 / 15,
    fontWeight: dictionary ? FontWeight.w600 : null,
  );

  @override
  State<TranslationOverlay> createState() => _TranslationOverlayState();
}

class _TranslationOverlayState extends State<TranslationOverlay> {
  (String?, int)? _hoveredParagraph;
  TranslationPhase? _lastPhase;
  String? _lastSessionId;
  int _sweepCount = 0;
  String? _hoveredPane;
  bool? _localSpeakingSource;
  final Map<String, int> _copyTriggers = {};
  final ScrollController _sourceScroll = ScrollController();
  final ScrollController _resultScroll = ScrollController();
  final List<GlobalKey> _sourceParagraphKeys = [];
  bool _sourceScrollDetached = false;
  int _programmaticScrollDepth = 0;

  @override
  void initState() {
    super.initState();
    _syncSessionState();
    widget.session.addListener(_onSessionChanged);
  }

  @override
  void didUpdateWidget(TranslationOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.speakingSource != widget.speakingSource) {
      _localSpeakingSource = null;
    }
    if (oldWidget.session != widget.session) {
      oldWidget.session.removeListener(_onSessionChanged);
      widget.session.addListener(_onSessionChanged);
      _syncSessionState();
    }
  }

  @override
  void dispose() {
    widget.session.removeListener(_onSessionChanged);
    _sourceScroll.dispose();
    _resultScroll.dispose();
    super.dispose();
  }

  void _onSessionChanged() {
    if (!mounted) return;
    setState(_syncSessionState);
  }

  void _syncSessionState() {
    final phase = widget.session.snapshot.phase;
    final id = widget.session.sessionId;
    if (_lastSessionId != id || phase == TranslationPhase.idle) {
      _lastSessionId = id;
      _localSpeakingSource = null;
      _copyTriggers.clear();
      _hoveredParagraph = null;
      _sourceScrollDetached = false;
      _programmaticScrollDepth = 0;
      Tooltip.dismissAllToolTips();
      if (_sourceScroll.hasClients) _sourceScroll.jumpTo(0);
      if (_resultScroll.hasClients) _resultScroll.jumpTo(0);
    }
    if (_lastPhase != phase) {
      _lastPhase = phase;
      if (phase == TranslationPhase.completed) {
        _sweepCount += 1;
      }
      if (phase == TranslationPhase.translating ||
          phase == TranslationPhase.idle) {
        _localSpeakingSource = null;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final snap = widget.session.snapshot;
    final definition = widget.session.definition;
    final pairs = snap.pairs.isEmpty
        ? [TranslationPair(snap.sourceText, snap.translatedText)]
        : snap.pairs;
    _syncSourceParagraphKeys(pairs.length);
    if (snap.phase == TranslationPhase.idle) {
      return const SizedBox.shrink();
    }
    if (snap.phase == TranslationPhase.trigger) {
      return Center(
        child: BouncyPresence(
          key: ValueKey('trigger-${widget.session.sessionId}'),
          fromScale: 0.88,
          quick: true,
          child: GestureDetector(
            onPanStart: (_) => widget.onDrag(),
            child: NativeGlassSurface(
              material: true,
              radius: GlassMetrics.primaryRadius,
              child: FilledButton(
                onPressed: widget.onActivate,
                style: FilledButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.primary,
                  backgroundColor: Colors.transparent,
                  shadowColor: Colors.transparent,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  minimumSize: TranslationOverlay.triggerSize,
                  fixedSize: TranslationOverlay.triggerSize,
                  alignment: Alignment.center,
                  visualDensity: VisualDensity.standard,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  textStyle: Theme.of(context).textTheme.labelLarge!
                      .copyWith(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    LineIcon(LucideIcons.languages, size: 16),
                    SizedBox(width: 6),
                    Text('翻译', textAlign: TextAlign.center),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    final busy = snap.phase == TranslationPhase.translating;
    final failed =
        snap.phase == TranslationPhase.failed ||
        snap.phase == TranslationPhase.sizeLimited;
    final statusInBanner = failed && snap.translatedText.isEmpty;
    final mode = widget.session.mode;
    final modeLabel = TranslationOverlay.modeLabels[mode]!;
    final errorBannerText =
        snap.message ??
        (snap.phase == TranslationPhase.sizeLimited ? '选区过长' : '$modeLabel失败');
    final status = switch (snap.phase) {
      TranslationPhase.translating => '$modeLabel中…',
      TranslationPhase.failed =>
        statusInBanner ? '$modeLabel失败' : (snap.message ?? '$modeLabel失败'),
      TranslationPhase.sizeLimited =>
        statusInBanner ? '选区过长' : (snap.message ?? '选区过长'),
      _ => null,
    };
    final choices = widget.session.serviceChoices();
    final currentService =
        widget.session.serviceOverride ??
        choices.firstWhere((choice) => choice.isDefault).id;
    final resultLabel = mode == TextMode.translate ? '译文' : modeLabel;
    final resultBody = busy && snap.translatedText.isEmpty
        ? const GentleShimmerSkeleton(lines: 2)
        : statusInBanner
        ? NativeGlassBanner(
            message: errorBannerText,
            isError: true,
            action: widget.session.canRetry
                ? FilledButton.tonalIcon(
                    onPressed: widget.onActivate,
                    icon: const LineIcon(LucideIcons.refreshCw, size: 16),
                    label: const Text('重试'),
                  )
                : null,
          )
        : _paragraphs(
            pairs,
            translated: true,
            dictionary: definition != null,
            failed: failed,
          );
    final revealedResult = AnimatedSwitcher(
      duration: AppMotion.reduced(context)
          ? Duration.zero
          : MotionMetrics.skeletonFadeDuration,
      layoutBuilder: (current, previous) => Stack(
        alignment: Alignment.topLeft,
        children: [...previous, ?current],
      ),
      child: KeyedSubtree(
        key: ValueKey(busy && snap.translatedText.isEmpty),
        child: resultBody,
      ),
    );
    final sourceBody = _paragraphs(
      pairs,
      translated: false,
      dictionary: definition != null,
      failed: false,
    );
    final sourceOnly = widget.session.sourceIsTarget;
    final sourceActions = [
      _CardButton(
        key: sourceOnly
            ? const ValueKey('card-copy')
            : const ValueKey('card-copy-source'),
        tooltip: '复制原文',
        icon: CopyConfirmIcon(
          trigger: _copyTriggers[sourceOnly ? 'result' : 'source'] ?? 0,
          size: 14,
        ),
        onPressed: snap.sourceText.isEmpty
            ? null
            : () => _copy(sourceOnly ? 'result' : 'source', snap.sourceText),
        visual: 24,
        radius: GlassMetrics.menuItemRadius,
        iconSize: 14,
        material: false,
      ),
      _CardButton(
        key: sourceOnly
            ? const ValueKey('card-speak')
            : const ValueKey('card-speak-source'),
        tooltip: _speaking(true) ? '停止朗读' : '朗读原文',
        icon: SpeechWaveIcon(speaking: _speaking(true), size: 14),
        onPressed: snap.sourceText.isEmpty ? null : () => _speak(true),
        visual: 24,
        radius: GlassMetrics.menuItemRadius,
        iconSize: 14,
        material: false,
      ),
    ];
    final resultActions = [
      _CardButton(
        key: const ValueKey('card-copy'),
        tooltip: '复制$resultLabel',
        icon: CopyConfirmIcon(trigger: _copyTriggers['result'] ?? 0, size: 14),
        onPressed: snap.translatedText.isEmpty
            ? null
            : () => _copy('result', snap.translatedText),
        visual: 24,
        radius: GlassMetrics.menuItemRadius,
        iconSize: 14,
        material: false,
      ),
      _CardButton(
        key: const ValueKey('card-speak'),
        tooltip: _speaking(false) ? '停止朗读' : '朗读$resultLabel',
        icon: SpeechWaveIcon(speaking: _speaking(false), size: 14),
        onPressed: snap.translatedText.isEmpty ? null : () => _speak(false),
        visual: 24,
        radius: GlassMetrics.menuItemRadius,
        iconSize: 14,
        material: false,
      ),
    ];
    final Widget body;
    if (definition != null) {
      body = Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            flex: 2,
            child: Column(
              children: [
                Expanded(
                  child: _pane(
                    title: '原文',
                    body: sourceBody,
                    actions: sourceActions,
                    scrollController: _sourceScroll,
                    onScrollNotification: _onSourceScroll,
                  ),
                ),
                const Divider(),
                Expanded(
                  child: _pane(
                    title: resultLabel,
                    body: revealedResult,
                    actions: resultActions,
                    scrollController: _resultScroll,
                  ),
                ),
              ],
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            flex: 3,
            child: _pane(
              title: '词典',
              body: DictionaryDefinitionView(definition: definition),
              actions: [
                if (snap.phase == TranslationPhase.completed)
                  _CardButton(
                    key: const ValueKey('card-vocabulary'),
                    tooltip: widget.session.savedToVocabulary
                        ? '已加入生词本'
                        : '加入生词本',
                    icon: VocabularyBookmarkIcon(
                      saved: widget.session.savedToVocabulary,
                      size: 14,
                    ),
                    onPressed: widget.session.savedToVocabulary
                        ? null
                        : widget.onAddVocabulary,
                    visual: 24,
                    radius: GlassMetrics.menuItemRadius,
                    iconSize: 14,
                    material: false,
                  ),
                _CardButton(
                  tooltip: '复制词典',
                  icon: CopyConfirmIcon(
                    trigger: _copyTriggers['dictionary'] ?? 0,
                    size: 14,
                  ),
                  onPressed: () => _copy('dictionary', definition),
                  visual: 24,
                  radius: GlassMetrics.menuItemRadius,
                  iconSize: 14,
                  material: false,
                ),
              ],
            ),
          ),
        ],
      );
    } else if (sourceOnly) {
      body = _pane(
        title: '原文',
        body: _paragraphs(
          pairs,
          translated: false,
          dictionary: false,
          failed: false,
          lead: true,
        ),
        actions: sourceActions,
        scrollController: _sourceScroll,
        onScrollNotification: _onSourceScroll,
      );
    } else {
      body = Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: _pane(
              title: '原文',
              body: sourceBody,
              actions: sourceActions,
              scrollController: _sourceScroll,
              onScrollNotification: _onSourceScroll,
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: _pane(
              title: resultLabel,
              body: revealedResult,
              actions: resultActions,
              scrollController: _resultScroll,
            ),
          ),
        ],
      );
    }
    return BouncyPresence(
      key: ValueKey('card-${widget.session.sessionId}'),
      fromScale: 0.94,
      quick: true,
      child: OpticalPrismOverlay(
        radius: GlassMetrics.panelRadius,
        sweepTrigger: _sweepCount,
        child: NativeGlassSurface(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: 44,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: GlassMetrics.space8,
                  ),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Positioned.fill(
                        child: MouseRegion(
                          cursor: SystemMouseCursors.move,
                          child: GestureDetector(
                            key: const ValueKey('result-drag-area'),
                            behavior: HitTestBehavior.opaque,
                            onPanStart: (_) => widget.onDrag(),
                          ),
                        ),
                      ),
                      Row(
                        children: [
                          NativeGlassMenuButton<TextMode>(
                            key: const ValueKey('card-mode-menu'),
                            quiet: true,
                            quietTextStyle: TextStyle(
                              fontSize: GlassMetrics.bodyFont,
                              fontWeight: FontWeight.w600,
                              color: Theme.of(context).colorScheme.onSurface,
                            ),
                            value: mode,
                            items: TranslationOverlay.modeLabels,
                            onChanged: busy ? null : widget.onMode,
                          ),
                          if (status != null)
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 120),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const SizedBox(width: GlassMetrics.space8),
                                  TranslationStatusIcon(
                                    phase: snap.phase,
                                    size: 14,
                                  ),
                                  const SizedBox(width: GlassMetrics.space4),
                                  Flexible(
                                    child: AppTooltip(
                                      message: status,
                                      child: Text(
                                        status,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          const Spacer(),
                          if (widget.session.canRetry && !statusInBanner)
                            TextButton.icon(
                              onPressed: widget.onActivate,
                              icon: const LineIcon(
                                LucideIcons.refreshCw,
                                size: 14,
                              ),
                              label: const Text('重试'),
                            ),
                          NativeGlassMenuButton<String>(
                            quiet: true,
                            value: currentService,
                            items: {
                              for (final choice in choices)
                                if (mode == TextMode.translate ||
                                    choice.isModel ||
                                    choice.id == currentService)
                                  choice.id: choice.name,
                            },
                            onChanged: busy ? null : widget.onService,
                          ),
                          const SizedBox(width: GlassMetrics.space4),
                          _CardButton(
                            key: const ValueKey('overlay-close-button'),
                            tooltip: '关闭',
                            icon: const LineIcon(LucideIcons.x),
                            onPressed: widget.onDismiss,
                            visual: 28,
                            radius: GlassMetrics.controlRadius,
                            iconSize: GlassMetrics.icon,
                            material: false,
                          ),
                        ],
                      ),
                      Center(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: _languageMenus(busy),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const Divider(height: 0.5, thickness: 0.5),
              Expanded(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Theme.of(context).cardTheme.color,
                    borderRadius: const BorderRadius.vertical(
                      bottom: Radius.circular(GlassMetrics.panelRadius),
                    ),
                  ),
                  child: body,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _copy(String paneKey, String text) {
    Clipboard.setData(ClipboardData(text: text));
    setState(() {
      _copyTriggers[paneKey] = (_copyTriggers[paneKey] ?? 0) + 1;
    });
  }

  bool _speaking(bool source) =>
      (widget.speakingSource ?? _localSpeakingSource) == source;

  void _speak(bool source) {
    if (widget.speakingSource == null) {
      setState(() {
        _localSpeakingSource = _speaking(source) ? null : source;
      });
    }
    widget.onSpeak(source);
  }

  void _syncSourceParagraphKeys(int count) {
    while (_sourceParagraphKeys.length < count) {
      _sourceParagraphKeys.add(GlobalKey());
    }
    if (_sourceParagraphKeys.length > count) {
      _sourceParagraphKeys.removeRange(count, _sourceParagraphKeys.length);
    }
  }

  bool _onSourceScroll(ScrollNotification notification) {
    if (_programmaticScrollDepth == 0 &&
        notification is ScrollUpdateNotification) {
      _sourceScrollDetached = true;
    }
    return false;
  }

  Future<void> _followSourceParagraph(int index) async {
    if (_sourceScrollDetached ||
        index < 0 ||
        index >= _sourceParagraphKeys.length) {
      return;
    }
    final target = _sourceParagraphKeys[index].currentContext;
    if (target == null) return;
    _programmaticScrollDepth += 1;
    try {
      await Scrollable.ensureVisible(
        target,
        alignment: 0.25,
        duration: AppMotion.reduced(context)
            ? Duration.zero
            : const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
      );
    } finally {
      if (_programmaticScrollDepth > 0) {
        _programmaticScrollDepth -= 1;
      }
    }
  }

  Widget _pane({
    required String title,
    required Widget body,
    List<Widget> actions = const [],
    ScrollController? scrollController,
    NotificationListenerCallback<ScrollNotification>? onScrollNotification,
  }) {
    final header = SizedBox(
      height: 32,
      child: Row(
        children: [
          Expanded(
            child: Text(title, style: Theme.of(context).textTheme.bodySmall),
          ),
          if (actions.isNotEmpty)
            AnimatedOpacity(
              opacity: _hoveredPane == title ? 1 : 0.65,
              duration: AppMotion.reduced(context)
                  ? Duration.zero
                  : GlassMetrics.transition,
              child: Row(mainAxisSize: MainAxisSize.min, children: actions),
            ),
        ],
      ),
    );
    final scrollView = SingleChildScrollView(
      controller: scrollController,
      primary: false,
      padding: const EdgeInsets.only(
        left: GlassMetrics.space16,
        right: GlassMetrics.space16,
        bottom: GlassMetrics.space12,
      ),
      child: body,
    );
    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            GlassMetrics.space16,
            GlassMetrics.space4,
            GlassMetrics.space8,
            GlassMetrics.space4,
          ),
          child: header,
        ),
        Expanded(
          child: onScrollNotification == null
              ? scrollView
              : NotificationListener<ScrollNotification>(
                  onNotification: onScrollNotification,
                  child: scrollView,
                ),
        ),
      ],
    );
    if (actions.isEmpty) return column;
    return MouseRegion(
      onEnter: (_) => setState(() => _hoveredPane = title),
      onExit: (_) => setState(() => _hoveredPane = null),
      child: column,
    );
  }

  List<Widget> _languageMenus(bool busy) {
    final session = widget.session;
    final detected = session.snapshot.detectedLanguage;
    final detectedName = detected == null
        ? null
        : AppSettings.languages[detected] ?? detected;
    final target =
        session.outputLanguage ??
        session.activeLanguage.resolve(detected).targetLanguage;
    final onChanged = busy || !session.isExpanded
        ? null
        : (String? source, String target) => widget.onLanguages(source, target);
    return [
      NativeGlassMenuButton<String>(
        key: const ValueKey('card-source-language'),
        quiet: true,
        value: session.sourceOverride ?? TranslationOverlay.autoLanguage,
        items: {
          TranslationOverlay.autoLanguage:
              detectedName == null || session.sourceOverride != null
              ? '自动检测'
              : '自动检测（$detectedName）',
          ...AppSettings.languages,
        },
        onChanged: onChanged == null
            ? null
            : (value) => onChanged(
                value == TranslationOverlay.autoLanguage ? null : value,
                target,
              ),
      ),
      Text(
        '→',
        style: TextStyle(
          fontSize: GlassMetrics.captionFont,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
      NativeGlassMenuButton<String>(
        key: const ValueKey('card-target-language'),
        quiet: true,
        value: target,
        items: {
          if (!AppSettings.languages.containsKey(target)) target: target,
          ...AppSettings.languages,
        },
        onChanged: onChanged == null
            ? null
            : (value) => onChanged(session.sourceOverride, value),
      ),
    ];
  }

  Widget _paragraphs(
    List<TranslationPair> pairs, {
    required bool translated,
    required bool dictionary,
    required bool failed,
    bool lead = false,
  }) {
    final colors = Theme.of(context).colorScheme;
    final style = TranslationOverlay.textStyleFor(dictionary: dictionary)
        .copyWith(
          color: translated || lead
              ? colors.onSurface
              : colors.onSurfaceVariant,
        );

    return SelectionArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 8,
        children: [
          for (var index = 0; index < pairs.length; index++)
            if (translated && !failed)
              MouseRegion(
                key: ValueKey('${widget.session.sessionId}-reveal-$index'),
                onEnter: (_) {
                  setState(() {
                    _hoveredParagraph = (widget.session.sessionId, index);
                  });
                  if (pairs.length > 1) {
                    _followSourceParagraph(index);
                  }
                },
                onExit: (_) => setState(() => _hoveredParagraph = null),
                child: CharReveal(
                  key: ValueKey('translated-paragraph-$index'),
                  text: pairs[index].translation,
                  style: style,
                  builder: (context, span) => Text.rich(span),
                ),
              )
            else
              GentleReveal(
                key: ValueKey(
                  '${widget.session.sessionId}-${translated ? 't' : 's'}-$index-${failed ? 'err' : 'ok'}',
                ),
                staggerIndex: index.clamp(0, 6),
                shakeOnError: translated && failed,
                child: translated
                    ? MouseRegion(
                        key: ValueKey('translated-paragraph-$index'),
                        onEnter: (_) {
                          setState(() {
                            _hoveredParagraph = (
                              widget.session.sessionId,
                              index,
                            );
                          });
                          if (pairs.length > 1) {
                            _followSourceParagraph(index);
                          }
                        },
                        onExit: (_) => setState(() => _hoveredParagraph = null),
                        child: Text(pairs[index].translation, style: style),
                      )
                    : KeyedSubtree(
                        key: _sourceParagraphKeys[index],
                        child: Container(
                          key: ValueKey('source-paragraph-$index'),
                          decoration: BoxDecoration(
                            color:
                                pairs.length > 1 &&
                                    _hoveredParagraph ==
                                        (widget.session.sessionId, index)
                                ? colors.onSurface.withValues(alpha: 0.08)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(pairs[index].source, style: style),
                        ),
                      ),
              ),
        ],
      ),
    );
  }
}

class _CardButton extends StatelessWidget {
  const _CardButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    required this.visual,
    required this.radius,
    required this.iconSize,
    this.material = true,
  });
  final String tooltip;
  final Widget icon;
  final VoidCallback? onPressed;
  final double visual;
  final double radius;
  final double iconSize;

  final bool material;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: GlassMetrics.hitSize,
    child: Stack(
      alignment: Alignment.center,
      children: [
        Positioned.fill(
          child: GestureDetector(
            excludeFromSemantics: true,
            behavior: HitTestBehavior.opaque,
            onTap: onPressed,
          ),
        ),
        SizedBox.square(
          dimension: visual,
          child: NativeGlassSurface(
            material: material,
            radius: radius,
            child: AppTooltip(
              message: tooltip,
              child: IconButton(
                onPressed: onPressed,
                padding: EdgeInsets.zero,
                constraints: BoxConstraints.tight(Size.square(visual)),
                iconSize: iconSize,
                icon: icon,
              ),
            ),
          ),
        ),
      ],
    ),
  );
}
