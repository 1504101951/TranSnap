import '../common/constants/glass_metrics.dart';
import '../common/constants/motion_metrics.dart';
import '../common/constants/text_mode.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../common/widgets/app_motion.dart';
import '../common/widgets/native_glass.dart';

import '../selection/selection_session.dart';
import 'dictionary_definition.dart';
import '../translation/translation_types.dart';

/// 当前选区的触发按钮和译文卡片；窗口位置由 macOS 管理。
class TranslationOverlay extends StatefulWidget {
  /// session 提供状态；三个无参回调分别翻译、关闭、拖动，onMode 切换处理模式，
  /// speakingSource 指示外部朗读状态（true 原文/词典、false 译文、null 未朗读）；构造浮层内容。
  const TranslationOverlay({
    super.key,
    required this.session,
    required this.onActivate,
    required this.onDismiss,
    required this.onDrag,
    required this.onMode,
    required this.onService,
    required this.onSpeak,
    required this.onAddVocabulary,
    this.speakingSource,
  });

  /// 视觉按钮84×30，透明命中窗口额外提供上下各1pt点击空间。
  static const triggerSize = Size(84, 30);
  static const triggerWindowSize = Size(84, 32);
  final SelectionSession session;
  final VoidCallback onActivate;
  final VoidCallback onDismiss;
  final VoidCallback onDrag;
  final ValueChanged<TextMode> onMode;

  /// 卡片服务菜单选中的服务 id；用该服务重新处理当前原文，只影响本张卡片（#100）。
  final ValueChanged<String> onService;

  /// source 为 true 时朗读原文栏，否则朗读结果栏；同一栏正在朗读时再次点击停止（#101）。
  final ValueChanged<bool> onSpeak;

  /// 把当前单词、译文与词典释义加入生词本（#102）。
  final VoidCallback onAddVocabulary;

  /// 外部受控朗读状态：true 原文/词典正在朗读，false 结果栏正在朗读，null 未朗读或由内部状态托管。
  final bool? speakingSource;

  /// 模式菜单的选项名称，也是左栏标题；顺序即菜单顺序（#100）。
  static const modeLabels = {
    TextMode.translate: '翻译',
    TextMode.polish: '润色',
    TextMode.correct: '纠错',
    TextMode.explain: '解释',
  };

  /// 单栏卡片宽度、对照与词典布局宽度、卡片最大高度（#134 第 1 条）。
  static const singleWidth = 560.0;
  static const compareWidth = 720.0;
  static const maxHeight = 420.0;

  /// 单栏卡片除正文外的固定高度：标题区 44、分隔线 0.5、正文上内边距 16、操作行上下各 4 与按钮命中 32（#134、#67 第 37 项）。
  static const singleChromeHeight =
      44 +
      0.5 +
      GlassMetrics.space16 +
      GlassMetrics.space4 * 2 +
      GlassMetrics.hitSize;

  /// translated 为译文（或作为唯一正文的原文），dictionary 为词典布局左栏，single 为单栏布局；
  /// 返回不含颜色的正文样式：单栏译文 15/22 w500、单栏原文 12/17、对照 15/22、词典左栏 15/22 w600（#134）。
  static TextStyle textStyleFor({
    required bool translated,
    required bool dictionary,
    required bool single,
  }) {
    if (single && !translated) {
      return const TextStyle(
        fontSize: GlassMetrics.captionFont,
        height: GlassMetrics.captionLine / GlassMetrics.captionFont,
      );
    }
    return TextStyle(
      fontSize: 15,
      height: 22 / 15,
      fontWeight: dictionary
          ? FontWeight.w600
          : single
          ? FontWeight.w500
          : null,
    );
  }

  /// session 为当前会话，scaler 为系统文字缩放；返回卡片布局与窗口尺寸。
  /// 只有一组段落配对、没有词典释义且单栏内容高度不超过 420 时为 560 宽单栏，高度按译文与原文实际行数计算；
  /// 其余为 720×420 对照或词典布局。卡片与原生窗口尺寸共用这一判定（#134）。
  static ({bool single, Size size}) layoutFor(
    SelectionSession session,
    TextScaler scaler,
  ) {
    const compare = (single: false, size: Size(compareWidth, maxHeight));
    final snap = session.snapshot;
    if (session.definition != null || snap.pairs.length > 1) return compare;
    const textWidth = singleWidth - GlassMetrics.space16 * 2;
    // measure 按指定样式与宽度排版文字，返回所占高度。
    double measure(String text, TextStyle style, double width) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
      )..layout(maxWidth: width);
      final height = painter.height;
      painter.dispose();
      return height;
    }

    final lead = textStyleFor(
      translated: true,
      dictionary: false,
      single: true,
    );
    final double content;
    if (session.sourceIsTarget) {
      content = measure(snap.sourceText, lead, textWidth);
    } else {
      // 译文未到达时按骨架两行估算；原文占满内容宽度（#134 第 4 条）。
      final translated = snap.translatedText.isEmpty
          ? lead.height! * lead.fontSize! * 2
          : measure(snap.translatedText, lead, textWidth);
      final source = measure(
        snap.sourceText,
        textStyleFor(translated: false, dictionary: false, single: true),
        textWidth,
      );
      content = translated + GlassMetrics.space8 + source;
    }
    final height = (singleChromeHeight + content).ceilToDouble();
    if (height > maxHeight) return compare;
    return (single: true, size: Size(singleWidth, height));
  }

  /// 无参数；创建只保存当前悬停段落的界面状态。
  @override
  State<TranslationOverlay> createState() => _TranslationOverlayState();
}

/// 根据会话呈现触发按钮或结果；持有段落悬停与轻量微交互状态，翻译由会话管理。
class _TranslationOverlayState extends State<TranslationOverlay> {
  (String?, int)? _hoveredParagraph;
  TranslationPhase? _lastPhase;
  String? _lastSessionId;
  int _sweepCount = 0;
  // 悬停卡片时底部操作行完全显示；悬停原文块或某一栏时，该处的朗读、复制按钮出现（#134）。
  bool _cardHovered = false;
  String? _hoveredPane;
  bool? _localSpeakingSource;
  final Map<String, int> _copyTriggers = {};

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
    super.dispose();
  }

  void _onSessionChanged() {
    if (!mounted) return;
    setState(_syncSessionState);
  }

  /// 会话标识或阶段跃迁时复位局部微交互态，并在完成翻译瞬间触发一次表面光学扫光（#142）。
  void _syncSessionState() {
    final phase = widget.session.snapshot.phase;
    final id = widget.session.sessionId;
    if (_lastSessionId != id || phase == TranslationPhase.idle) {
      _lastSessionId = id;
      _localSpeakingSource = null;
      _copyTriggers.clear();
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

  /// context 提供主题；返回随会话更新的单按钮或结果卡片。
  @override
  Widget build(BuildContext context) {
    final snap = widget.session.snapshot;
    final definition = widget.session.definition;
    // 已校验的语义段落成对展示；没有配对时整段作为一对。词典释义单独成栏。
    final pairs = snap.pairs.isEmpty
        ? [TranslationPair(snap.sourceText, snap.translatedText)]
        : snap.pairs;
    if (snap.phase == TranslationPhase.idle) {
      return const SizedBox.shrink();
    }
    if (snap.phase == TranslationPhase.trigger) {
      // 触发态整块区域就是按钮，拖动手势胜出时不会误发翻译请求。
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
                  // 保留主题字体，让中文和系统字体设置使用同一套字形回退。
                  textStyle: Theme.of(context).textTheme.labelLarge!
                      .copyWith(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Icon(LucideIcons.languages, size: 16),
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
    // 状态文字只在处理中与失败时出现；完成后标题区只留模式标签（#134）。
    final status = switch (snap.phase) {
      TranslationPhase.translating => '$modeLabel中…',
      TranslationPhase.failed =>
        statusInBanner ? '$modeLabel失败' : (snap.message ?? '$modeLabel失败'),
      TranslationPhase.sizeLimited =>
        statusInBanner ? '选区过长' : (snap.message ?? '选区过长'),
      _ => null,
    };
    // 服务菜单：本卡片选用的服务，未选择时为默认服务（#100）。
    final choices = widget.session.serviceChoices();
    final currentService =
        widget.session.serviceOverride ??
        choices.firstWhere((choice) => choice.isDefault).id;
    final resultLabel = mode == TextMode.translate ? '译文' : modeLabel;
    // layoutFor 与原生窗口尺寸共用同一判定：单栏、对照或词典（#134）。
    final single = TranslationOverlay.layoutFor(
      widget.session,
      MediaQuery.textScalerOf(context),
    ).single;
    final resultBody = busy && snap.translatedText.isEmpty
        ? const GentleShimmerSkeleton(lines: 2)
        : statusInBanner
        ? NativeGlassBanner(
            message: errorBannerText,
            isError: true,
            action: widget.session.canRetry
                ? FilledButton.tonalIcon(
                    onPressed: widget.onActivate,
                    icon: const Icon(LucideIcons.refreshCw, size: 16),
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
    // 首字到达时加载骨架 120ms 淡出，不与逐字显影同时出现（#142 第 2 条）。
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
    // 原文已是目标语言时只有原文；朗读与复制都作用于原文（#134 第 5 条）。
    final sourceOnly = widget.session.sourceIsTarget;
    final Widget body;
    if (single) {
      body = Padding(
        padding: const EdgeInsets.fromLTRB(
          GlassMetrics.space16,
          GlassMetrics.space16,
          GlassMetrics.space16,
          0,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (sourceOnly)
              _paragraphs(
                pairs,
                translated: false,
                dictionary: false,
                failed: false,
                lead: true,
              )
            else ...[
              revealedResult,
              const SizedBox(height: GlassMetrics.space8),
              sourceBody,
            ],
          ],
        ),
      );
    } else if (definition != null) {
      // 词典布局：左 2/5 上下分屏（译文、原文），右 3/5 词典；栏头只有栏名（#134 第 7 条）。
      body = Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            flex: 2,
            child: Column(
              children: [
                Expanded(
                  child: _pane(title: resultLabel, body: revealedResult),
                ),
                const Divider(),
                Expanded(
                  child: _pane(title: '原文', body: sourceBody),
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
                ),
              ],
            ),
          ),
        ],
      );
    } else {
      // 对照布局：左译文右原文各半，原文复制与朗读沉到底部操作行右侧（#134 第 5 条）。
      body = Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: _pane(title: resultLabel, body: revealedResult),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: _pane(title: '原文', body: sourceBody),
          ),
        ],
      );
    }
    // 底部操作行默认 55% 不透明度，悬停卡片时完全显示（#134 第 6 条）。
    final primaryText = sourceOnly ? snap.sourceText : snap.translatedText;
    final footer = AnimatedOpacity(
      opacity: _cardHovered ? 1 : 0.55,
      duration: AppMotion.reduced(context)
          ? Duration.zero
          : GlassMetrics.transition,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          GlassMetrics.space8,
          GlassMetrics.space4,
          GlassMetrics.space8,
          GlassMetrics.space4,
        ),
        child: Row(
          spacing: GlassMetrics.space4,
          children: [
            // 查到释义且翻译完成后可加入生词本；本卡片加入后改为已加入并禁用（#102）。
            if (definition != null && snap.phase == TranslationPhase.completed)
              _FooterAction(
                key: const ValueKey('card-vocabulary'),
                icon: VocabularyBookmarkIcon(
                  saved: widget.session.savedToVocabulary,
                  size: 14,
                ),
                label: widget.session.savedToVocabulary ? '已加入生词本' : '加入生词本',
                onPressed: widget.session.savedToVocabulary
                    ? null
                    : widget.onAddVocabulary,
              ),
            _FooterAction(
              key: const ValueKey('card-copy'),
              icon: CopyConfirmIcon(
                trigger: _copyTriggers['result'] ?? 0,
                size: 14,
              ),
              label: sourceOnly ? '复制原文' : '复制$resultLabel',
              onPressed: primaryText.isEmpty
                  ? null
                  : () => _copy('result', primaryText),
            ),
            _FooterAction(
              key: const ValueKey('card-speak'),
              icon: SpeechWaveIcon(speaking: _speaking(sourceOnly), size: 14),
              label: _speaking(sourceOnly) ? '停止朗读' : '朗读',
              onPressed: primaryText.isEmpty ? null : () => _speak(sourceOnly),
            ),
            if (!sourceOnly) ...[
              const Spacer(),
              _FooterAction(
                key: const ValueKey('card-copy-source'),
                icon: CopyConfirmIcon(
                  trigger: _copyTriggers['source'] ?? 0,
                  size: 14,
                ),
                label: '复制原文',
                onPressed: snap.sourceText.isEmpty
                    ? null
                    : () => _copy('source', snap.sourceText),
              ),
              _FooterAction(
                key: const ValueKey('card-speak-source'),
                icon: SpeechWaveIcon(speaking: _speaking(true), size: 14),
                label: _speaking(true) ? '停止朗读' : '朗读原文',
                onPressed: snap.sourceText.isEmpty ? null : () => _speak(true),
              ),
            ],
          ],
        ),
      ),
    );
    return BouncyPresence(
      key: ValueKey('card-${widget.session.sessionId}'),
      fromScale: 0.94,
      quick: true,
      child: OpticalPrismOverlay(
        radius: GlassMetrics.panelRadius,
        sweepTrigger: _sweepCount,
        child: MouseRegion(
          onEnter: (_) => setState(() => _cardHovered = true),
          onExit: (_) => setState(() => _cardHovered = false),
          child: NativeGlassSurface(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 44pt 标题区保留玻璃材料，左右内边距 8：标签与关闭按钮到卡片边缘都是 8（#134 第 2 条）。
                SizedBox(
                  height: 44,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: GlassMetrics.space8,
                    ),
                    child: Row(
                      children: [
                        _ModeTabs(
                          value: mode,
                          onChanged: busy ? null : widget.onMode,
                        ),
                        // 标题区空白整块可拖动，不显示拖动手柄；状态只在处理中与失败时出现。
                        Expanded(
                          child: MouseRegion(
                            cursor: SystemMouseCursors.move,
                            child: GestureDetector(
                              key: const ValueKey('result-drag-area'),
                              behavior: HitTestBehavior.opaque,
                              onPanStart: (_) => widget.onDrag(),
                              child: SizedBox.expand(
                                child: status == null
                                    ? null
                                    : Row(
                                        children: [
                                          const SizedBox(
                                            width: GlassMetrics.space8,
                                          ),
                                          TranslationStatusIcon(
                                            phase: snap.phase,
                                            size: 14,
                                          ),
                                          const SizedBox(
                                            width: GlassMetrics.space8,
                                          ),
                                          Expanded(
                                            child: Tooltip(
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
                            ),
                          ),
                        ),
                        if (widget.session.canRetry && !statusInBanner)
                          TextButton.icon(
                            onPressed: widget.onActivate,
                            icon: const Icon(LucideIcons.refreshCw, size: 14),
                            label: const Text('重试'),
                          ),
                        // 服务菜单为次级文字菜单；润色、纠错、解释只列模型服务与当前服务，处理中禁用（#100）。
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
                          tooltip: '关闭',
                          icon: const Icon(LucideIcons.x),
                          onPressed: widget.onDismiss,
                          visual: 28,
                          radius: GlassMetrics.controlRadius,
                          iconSize: GlassMetrics.icon,
                          material: false,
                        ),
                      ],
                    ),
                  ),
                ),
                const Divider(height: 0.5, thickness: 0.5),
                // 正文使用 95% 不透明阅读底色，不随窗口透明度变化，来源应用的内容不会透出。
                Expanded(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Theme.of(context).cardTheme.color,
                      borderRadius: const BorderRadius.vertical(
                        bottom: Radius.circular(GlassMetrics.panelRadius),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: single
                              ? SingleChildScrollView(
                                  primary: false,
                                  child: body,
                                )
                              : body,
                        ),
                        footer,
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// paneKey 为复制反馈槽位，text 为要复制的全文；写入剪贴板并触发该槽位的打勾反馈，无返回值。
  void _copy(String paneKey, String text) {
    Clipboard.setData(ClipboardData(text: text));
    setState(() {
      _copyTriggers[paneKey] = (_copyTriggers[paneKey] ?? 0) + 1;
    });
  }

  /// source 为朗读原文（true）或结果（false）；返回该段是否正在朗读，外部受控状态优先。
  bool _speaking(bool source) =>
      (widget.speakingSource ?? _localSpeakingSource) == source;

  /// source 为朗读原文（true）或结果（false）；同一段正在朗读时再次点击停止，交给外部朗读并在本地记录状态，无返回值。
  void _speak(bool source) {
    if (widget.speakingSource == null) {
      setState(() {
        _localSpeakingSource = _speaking(source) ? null : source;
      });
    }
    widget.onSpeak(source);
  }

  /// title 为栏名（也是悬停标识），body 为可滚动正文，actions 为悬停该栏时在栏名右侧出现的按钮；
  /// 返回 28pt 栏头加独立滚动正文的一栏（对照与词典布局）。
  Widget _pane({
    required String title,
    required Widget body,
    List<Widget> actions = const [],
  }) {
    final header = SizedBox(
      height: 28,
      child: Row(
        children: [
          Expanded(
            child: Text(title, style: Theme.of(context).textTheme.bodySmall),
          ),
          if (actions.isNotEmpty)
            Visibility.maintain(
              visible: _hoveredPane == title,
              child: Row(mainAxisSize: MainAxisSize.min, children: actions),
            ),
        ],
      ),
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
          child: SingleChildScrollView(
            // 结果栏分栏独立滚动，不争抢父级 PrimaryScrollController。
            primary: false,
            padding: const EdgeInsets.only(
              left: GlassMetrics.space16,
              right: GlassMetrics.space16,
              bottom: GlassMetrics.space12,
            ),
            child: body,
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

  /// pairs 为已校验的段落配对，translated 选择译文（true）或原文（false），dictionary 为词典布局（左栏加粗），
  /// failed 触发失败轻抖，lead 表示原文作为唯一正文（原文已是目标语言）；
  /// 返回段间距 8pt 的段落列，悬停译文段落时高亮对应原文段落。
  Widget _paragraphs(
    List<TranslationPair> pairs, {
    required bool translated,
    required bool dictionary,
    required bool failed,
    bool lead = false,
  }) {
    final colors = Theme.of(context).colorScheme;
    // 译文与对照、词典布局正文 15/22（词典左栏 w600）；单栏的原文为 12/17 次要色（#134）。
    final style =
        TranslationOverlay.textStyleFor(
          translated: translated || lead,
          dictionary: dictionary,
          single: TranslationOverlay.layoutFor(
            widget.session,
            MediaQuery.textScalerOf(context),
          ).single,
        ).copyWith(
          color: translated || lead
              ? colors.onSurface
              : colors.onSurfaceVariant,
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        for (var index = 0; index < pairs.length; index++)
          // 成功的译文逐字显影（CharReveal，#142）；原文与失败段沿用逐段入场与失败轻抖。
          if (translated && !failed)
            MouseRegion(
              key: ValueKey('${widget.session.sessionId}-reveal-$index'),
              onEnter: (_) => setState(() {
                _hoveredParagraph = (widget.session.sessionId, index);
              }),
              onExit: (_) => setState(() => _hoveredParagraph = null),
              child: CharReveal(
                key: ValueKey('translated-paragraph-$index'),
                text: pairs[index].translation,
                style: style,
                builder: (context, span) => SelectableText.rich(span),
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
                      onEnter: (_) => setState(() {
                        _hoveredParagraph = (widget.session.sessionId, index);
                      }),
                      onExit: (_) => setState(() => _hoveredParagraph = null),
                      child: SelectableText(
                        pairs[index].translation,
                        style: style,
                      ),
                    )
                  : Container(
                      key: ValueKey('source-paragraph-$index'),
                      decoration: BoxDecoration(
                        color:
                            _hoveredParagraph ==
                                (widget.session.sessionId, index)
                            ? colors.primaryContainer
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: SelectableText(pairs[index].source, style: style),
                    ),
            ),
      ],
    );
  }
}

/// 卡片中的图标按钮：中心绘制 visual×visual 的可见按钮，外围 32×32 命中区同样触发动作。
class _CardButton extends StatelessWidget {
  /// tooltip 为提示与可访问名，icon 为图标组件，onPressed 为空表示禁用；
  /// visual、radius、iconSize 为可见尺寸、圆角与图标边长。
  const _CardButton({
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

  /// 是否带独立玻璃材料；标题区关闭按钮为无底图标按钮（#134 第 2 条）。
  final bool material;

  /// context 未使用；返回 32×32 命中区与居中的按钮。
  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: GlassMetrics.hitSize,
    child: Stack(
      alignment: Alignment.center,
      children: [
        // 可见按钮外的扩展命中区，排除重复语义，由上层可见按钮承担悬停、按压与提示。
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
            child: IconButton(
              tooltip: tooltip,
              onPressed: onPressed,
              padding: EdgeInsets.zero,
              constraints: BoxConstraints.tight(Size.square(visual)),
              iconSize: iconSize,
              icon: icon,
            ),
          ),
        ),
      ],
    ),
  );
}

/// 标题区模式分段标签：翻译、润色、纠错、解释四个纯文字标签（#100、#134）。
/// 高 28、圆角 8、左右内边距 8，与卡片左缘间距 8 使首个标签文字对齐正文左缘 16。
class _ModeTabs extends StatelessWidget {
  /// value 为当前模式，onChanged 为切换回调，处理中为空表示禁用。
  const _ModeTabs({required this.value, required this.onChanged});

  final TextMode value;
  final ValueChanged<TextMode>? onChanged;

  /// context 提供主题；返回间距 2 的标签行，选中项 w600 与浅色 5% / 深色 8% 底。
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final colors = theme.colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 2,
      children: [
        for (final entry in TranslationOverlay.modeLabels.entries)
          Semantics(
            selected: entry.key == value,
            child: TextButton(
              key: ValueKey('mode-tab-${entry.key.name}'),
              onPressed: onChanged == null ? null : () => onChanged!(entry.key),
              style: TextButton.styleFrom(
                minimumSize: const Size(0, GlassMetrics.buttonHeight),
                fixedSize: const Size.fromHeight(GlassMetrics.buttonHeight),
                padding: const EdgeInsets.symmetric(
                  horizontal: GlassMetrics.space8,
                ),
                shape: RoundedSuperellipseBorder(
                  borderRadius: BorderRadius.circular(
                    GlassMetrics.controlRadius,
                  ),
                ),
                backgroundColor: entry.key == value
                    ? colors.onSurface.withValues(alpha: dark ? 0.08 : 0.05)
                    : Colors.transparent,
                foregroundColor: entry.key == value
                    ? colors.onSurface
                    : colors.onSurfaceVariant,
                textStyle: theme.textTheme.bodyMedium!.copyWith(
                  fontWeight: entry.key == value ? FontWeight.w600 : null,
                ),
              ),
              child: Text(entry.value),
            ),
          ),
      ],
    );
  }
}

/// 底部操作行按钮：14pt 图标加 12pt 次要色文字，可见高 24、命中高 32、左右内边距 8、圆角 6（#134 第 6 条）。
class _FooterAction extends StatelessWidget {
  /// icon 为图标组件，label 为文字与可访问名，onPressed 为空表示禁用。
  const _FooterAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final Widget icon;
  final String label;
  final VoidCallback? onPressed;

  /// context 提供主题；返回 32pt 高命中区内居中的 24pt 文字按钮。
  @override
  Widget build(BuildContext context) => SizedBox(
    height: GlassMetrics.hitSize,
    child: Stack(
      alignment: Alignment.center,
      children: [
        // 可见按钮上下各 4pt 的扩展命中区，排除重复语义。
        Positioned.fill(
          child: GestureDetector(
            excludeFromSemantics: true,
            behavior: HitTestBehavior.opaque,
            onTap: onPressed,
          ),
        ),
        TextButton.icon(
          onPressed: onPressed,
          icon: icon,
          label: Text(label),
          style: TextButton.styleFrom(
            minimumSize: const Size(0, 24),
            fixedSize: const Size.fromHeight(24),
            padding: const EdgeInsets.symmetric(
              horizontal: GlassMetrics.space8,
            ),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
            textStyle: Theme.of(context).textTheme.bodySmall,
            iconSize: 14,
            shape: RoundedSuperellipseBorder(
              borderRadius: BorderRadius.circular(GlassMetrics.menuItemRadius),
            ),
          ),
        ),
      ],
    ),
  );
}
