import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../common/widgets/line_icon.dart';
import '../common/constants/capture_phase.dart';
import '../common/constants/channel_names.dart';
import '../common/constants/glass_metrics.dart';
import '../common/constants/method_names.dart';
import '../common/utils/screenshot_filename.dart';
import '../common/widgets/app_motion.dart';
import '../common/widgets/app_tooltip.dart';
import '../common/widgets/glass_icon_button.dart';
import '../common/widgets/native_glass.dart';
import '../common/widgets/result_window.dart';
import '../common/widgets/toolbar_feedback.dart';

class CaptureApp extends StatefulWidget {
  const CaptureApp({
    super.key,
    this.channel = const MethodChannel(ChannelNames.capture),
  });

  final MethodChannel channel;

  @override
  State<CaptureApp> createState() => _CaptureAppState();
}

class _CaptureAppState extends State<CaptureApp> {
  Map<String, dynamic> _state = {'phase': CapturePhase.idle.name};
  bool _pending = false;
  String? _pendingMethod;
  String? _feedback;
  bool _feedbackIsError = false;
  bool _feedbackHovered = false;
  Timer? _feedbackTimer;
  bool _fitWidth = true;

  CapturePhase get _phase => CapturePhase.parse(_state['phase'] as String);

  @override
  void initState() {
    super.initState();
    widget.channel.setMethodCallHandler((call) async {
      if (call.method == MethodNames.captureStateChanged &&
          call.arguments is Map) {
        _apply(Map<String, dynamic>.from(call.arguments as Map));
      }
    });
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    await _invoke(MethodNames.getCaptureState);
  }

  @override
  void dispose() {
    widget.channel.setMethodCallHandler(null);
    _feedbackTimer?.cancel();
    super.dispose();
  }

  void _apply(Map<String, dynamic> state) {
    if (!mounted) return;
    final previous = _state;
    setState(() => _state = state);
    if (state['id'] != previous['id']) {
      _feedbackTimer?.cancel();
      _feedback = null;
      _feedbackIsError = false;
      _feedbackHovered = false;
      _fitWidth = true;
    }
    if (state['error'] != null && state['error'] != previous['error']) {
      _showFeedback(state['error'] as String, isError: true);
    } else if (state['gifPath'] != null &&
        state['gifPath'] != previous['gifPath']) {
      _showFeedback('已保存 GIF');
    } else if (state['apngPath'] != null &&
        state['apngPath'] != previous['apngPath']) {
      _showFeedback('已保存 APNG');
    } else if (state['webmPath'] != null &&
        state['webmPath'] != previous['webmPath']) {
      _showFeedback('已保存 WebM');
    } else if (state['savedPath'] != null &&
        state['savedPath'] != previous['savedPath']) {
      final path = state['savedPath'] as String;
      _showFeedback(path.toLowerCase().endsWith('.png') ? '已保存截图' : '已保存 MP4');
    } else if (state['warning'] != null &&
        state['warning'] != previous['warning']) {
      _showFeedback(state['warning'] as String, isError: true);
    }
  }

  void _showFeedback(String message, {bool isError = false}) {
    _feedbackTimer?.cancel();
    setState(() {
      _feedback = message;
      _feedbackIsError = isError;
      if (!isError) _feedbackHovered = false;
    });
    _startFeedbackTimer();
  }

  void _startFeedbackTimer() {
    _feedbackTimer?.cancel();
    if (_feedback == null || (_feedbackIsError && _feedbackHovered)) return;
    final duration = _feedbackIsError
        ? GlassMetrics.errorFeedbackDuration
        : GlassMetrics.feedbackDuration;
    _feedbackTimer = Timer(duration, () {
      if (!mounted) return;
      setState(() {
        _feedback = null;
        _feedbackIsError = false;
        _feedbackHovered = false;
      });
    });
  }

  void _onFeedbackHoverChanged(bool hovered) {
    if (_feedbackHovered == hovered) return;
    _feedbackHovered = hovered;
    if (!_feedbackIsError) return;
    if (hovered) {
      _feedbackTimer?.cancel();
    } else {
      _startFeedbackTimer();
    }
  }

  void _dismissFeedback() {
    if (_feedback == null) return;
    _feedbackTimer?.cancel();
    setState(() {
      _feedback = null;
      _feedbackIsError = false;
      _feedbackHovered = false;
    });
  }

  Future<bool> _invoke(
    String method, [
    Map<String, Object?> arguments = const {},
  ]) async {
    if (!mounted || _pending) return false;
    setState(() {
      _pending = true;
      _pendingMethod = method;
      _feedbackTimer?.cancel();
      _feedback = null;
      _feedbackIsError = false;
      _feedbackHovered = false;
    });
    try {
      final value = await widget.channel.invokeMapMethod<String, dynamic>(
        method,
        {if (_state['id'] != null) 'id': _state['id'], ...arguments},
      );
      if (value != null) _apply(value);
      return true;
    } on PlatformException catch (error) {
      if (mounted) _showFeedback(error.message ?? error.code, isError: true);
      return false;
    } finally {
      if (mounted) {
        setState(() {
          _pending = false;
          _pendingMethod = null;
        });
      }
    }
  }

  Future<void> _discard() => _invoke(MethodNames.cancelCapture);

  Future<void> _copyImage() async {
    await _invoke(MethodNames.copyScreenshot);
    if (!mounted || _feedback != null) return;
    _showFeedback('已复制');
  }

  Future<void> _copyVideo() async {
    final ok = await _invoke(MethodNames.copyRecording);
    if (!ok || !mounted || _feedback != null) return;
    _showFeedback('已复制视频');
  }

  Widget _active() {
    final paused = _phase == CapturePhase.paused;
    final scrolling = _state['kind'] == 'scrolling';
    final seconds = ((_state['elapsed'] as num?)?.toDouble() ?? 0).floor();
    final elapsed =
        '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
    final liveDetail = (_state['detail'] as String?) ?? '';
    final liveStatus = liveDetail.isEmpty ? '实时翻译' : liveDetail;
    final progress = _state['kind'] == 'liveTranslation'
        ? (_state['recording'] == true
              ? '录制：$elapsed · $liveStatus'
              : liveStatus)
        : scrolling
        ? '长截图：${_state['height'] ?? 0} 像素'
        : '录制：$elapsed';
    final label = switch (_phase) {
      CapturePhase.preparing =>
        _state['countdown'] is int ? '${_state['countdown']} 秒后开始' : '正在准备采集…',
      CapturePhase.pausing => '正在暂停…',
      CapturePhase.finalizing => '正在完成采集…',
      _ => paused ? '已暂停 · $progress' : progress,
    };
    final editable =
        !_pending &&
        [
          CapturePhase.recording,
          CapturePhase.scrolling,
          CapturePhase.paused,
        ].contains(_phase);
    final countdown = _state['countdown'] as int?;
    final status = label;

    Widget statusBubble(String description, Widget child) => AppTooltip(
      message: description,
      child: NativeGlassSurface(
        material: true,
        radius: GlassMetrics.controlRadius,
        child: child,
      ),
    );

    Widget action(
      int index,
      String description,
      IconData icon,
      VoidCallback? action, {
      bool busy = false,
    }) => GentleReveal(
      key: ValueKey('capture-bubble-$index'),
      staggerIndex: index,
      blur: false,
      child: GlassIconButton(
        tooltip: description,
        icon: LineIcon(
          icon,
          size: GlassMetrics.icon,
          semanticLabel: description,
        ),
        onPressed: action,
        visual: GlassMetrics.hitSize,
        radius: GlassMetrics.controlRadius,
        iconSize: GlassMetrics.icon,
        material: true,
        busy: busy,
      ),
    );

    return AppTooltipScope(
      onShow: (message, anchor, preferAbove) {
        widget.channel.invokeMethod<void>(MethodNames.showOverlayTooltip, {
          if (_state['id'] != null) 'id': _state['id'],
          'message': message,
          'x': anchor.left,
          'y': anchor.top,
          'width': anchor.width,
          'height': anchor.height,
          'preferAbove': preferAbove,
        }).ignore();
      },
      onHide: () {
        widget.channel.invokeMethod<void>(MethodNames.hideOverlayTooltip).ignore();
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: GentleReveal(
              key: const ValueKey('capture-bubble-0'),
              staggerIndex: 0,
              blur: false,
              child: statusBubble(
                status,
                ConstrainedBox(
                  constraints: const BoxConstraints(
                    minWidth: GlassMetrics.buttonMinWidth,
                    maxWidth: 268,
                    minHeight: GlassMetrics.hitSize,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Center(
                      widthFactor: 1,
                      heightFactor: 1,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (countdown != null ||
                              _phase == CapturePhase.recording ||
                              _phase == CapturePhase.paused) ...[
                            RecordingPulseIcon(
                              countdown: countdown,
                              active: _phase == CapturePhase.recording,
                              paused: paused,
                              pulseKey: _state['elapsed'],
                              size: 14,
                            ),
                            const SizedBox(width: 6),
                          ],
                          Flexible(
                            child: Text(
                              status,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          action(
            1,
            paused ? '开始' : '暂停',
            paused ? LucideIcons.play : LucideIcons.pause,
            editable
                ? () =>
                      _invoke(MethodNames.setCapturePaused, {'paused': !paused})
                : null,
            busy: _pending && _pendingMethod == MethodNames.setCapturePaused,
          ),
          const SizedBox(width: 6),
          action(
            2,
            '结束',
            LucideIcons.square,
            editable ? () => _invoke(MethodNames.stopCapture) : null,
            busy: _pending && _pendingMethod == MethodNames.stopCapture,
          ),
          const SizedBox(width: GlassMetrics.actionGap),
          action(
            3,
            '放弃',
            LucideIcons.x,
            _pending ? null : _discard,
            busy: _pending && _pendingMethod == MethodNames.cancelCapture,
          ),
        ],
      ),
    );
  }

  String _formatDuration(double seconds) {
    final total = seconds.isFinite && seconds > 0 ? seconds.floor() : 0;
    return '${total ~/ 60}:${(total % 60).toString().padLeft(2, '0')}';
  }

  void _seekTo(double seconds) {
    final id = _state['id'];
    if (id == null) return;
    setState(() => _state = {..._state, 'position': seconds});
    unawaited(
      widget.channel.invokeMethod<void>(MethodNames.seekRecording, {
        'id': id,
        'seconds': seconds,
      }),
    );
  }

  Widget _videoResult() {
    final pixels = Size(
      (_state['width'] as num).toDouble(),
      (_state['height'] as num).toDouble(),
    );
    final logical = pixels / (_state['previewScale'] as num).toDouble();
    final duration = ((_state['duration'] as num?)?.toDouble() ?? 0).clamp(
      0.0,
      86400.0,
    );
    final maxSlider = math.max(duration, 0.1);
    final position = ((_state['position'] as num?)?.toDouble() ?? 0).clamp(
      0.0,
      maxSlider,
    );
    final playing = _state['playing'] == true;
    final converting = _phase == CapturePhase.converting;
    final saving = converting && _state['progress'] == null;
    final enabled = !_pending && !converting;
    final exporting = converting
        ? RecordingExport.parse(_state['exporting'] as String)
        : null;
    final colors = Theme.of(context).colorScheme;
    final timeStyle = TextStyle(
      fontSize: GlassMetrics.statusFont,
      height: 16 / GlassMetrics.statusFont,
      color: colors.onSurfaceVariant,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final barRect = Rect.fromLTWH(
          0,
          math.max(0, constraints.maxHeight - GlassMetrics.resultBarHeight),
          constraints.maxWidth,
          GlassMetrics.resultBarHeight,
        );
        final sliderWidth = (constraints.maxWidth - 490)
            .clamp(64.0, 220.0)
            .toDouble();
        return Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: ResultWindowCanvas(
                    child: Padding(
                      padding: const EdgeInsets.all(
                        GlassMetrics.resultCanvasPadding,
                      ),
                      child: LayoutBuilder(
                        builder: (context, mediaBox) {
                          final scale = math.min(
                            1.0,
                            math.min(
                              mediaBox.maxWidth / logical.width,
                              mediaBox.maxHeight / logical.height,
                            ),
                          );
                          final size = logical * scale;
                          return ResultMediaFrame(
                            child: SizedBox.fromSize(
                              size: size,
                              child: Semantics(
                                label:
                                    '录制结果，${_state['duration']}秒，${pixels.width.toInt()}×${pixels.height.toInt()}像素',
                                child: AppKitView(
                                  key: ValueKey(_state['id']),
                                  viewType: ChannelNames.captureVideoPreview,
                                  creationParams: {'id': _state['id']},
                                  creationParamsCodec:
                                      const StandardMessageCodec(),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
                ResultWindowBar(
                  leading: [
                    ResultTextButton(
                      buttonKey: const Key('result-discard'),
                      label: '放弃',
                      weak: true,
                      tooltip: '关闭当前采集',
                      onPressed: _pending ? null : _discard,
                      busy:
                          _pending && _pendingMethod == MethodNames.cancelCapture,
                    ),
                    const ResultBarDivider(),
                    ResultIconButton(
                      buttonKey: const Key('result-play-toggle'),
                      icon: playing ? LucideIcons.pause : LucideIcons.play,
                      tooltip: playing ? '暂停视频' : '播放视频',
                      onPressed: enabled
                          ? () => _invoke(MethodNames.toggleRecordingPlayback)
                          : null,
                      busy:
                          _pending &&
                          _pendingMethod == MethodNames.toggleRecordingPlayback,
                    ),
                    Text(_formatDuration(position), style: timeStyle),
                    SizedBox(
                      width: sliderWidth,
                      height: GlassMetrics.buttonHeight,
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 4,
                          thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 6,
                          ),
                          overlayShape: const RoundSliderOverlayShape(
                            overlayRadius: 12,
                          ),
                          activeTrackColor: NativeGlassTheme.accentOf(context),
                          thumbColor: NativeGlassTheme.accentOf(context),
                        ),
                        child: Slider(
                          key: const Key('result-video-slider'),
                          min: 0,
                          max: maxSlider,
                          value: position,
                          onChanged: enabled ? _seekTo : null,
                        ),
                      ),
                    ),
                    Text(_formatDuration(duration), style: timeStyle),
                    ResultTextButton(
                      buttonKey: const Key('result-trim'),
                      label: '裁剪',
                      icon: LucideIcons.scissors,
                      onPressed: enabled
                          ? () => _invoke(MethodNames.trimRecording)
                          : null,
                      busy:
                          _pending &&
                          _pendingMethod == MethodNames.trimRecording,
                    ),
                  ],
                  trailing: [
                    ResultTextButton(
                      buttonKey: const Key('result-copy'),
                      label: '复制',
                      icon: LucideIcons.copy,
                      tooltip: '复制视频',
                      onPressed: enabled ? _copyVideo : null,
                      busy:
                          _pending &&
                          _pendingMethod == MethodNames.copyRecording,
                    ),
                    if (converting &&
                        exporting != null &&
                        exporting != RecordingExport.mp4)
                      ResultTextButton(
                        buttonKey: const Key('result-cancel-export'),
                        label: '取消转换',
                        icon: LucideIcons.x,
                        busy: true,
                        onPressed: _pending
                            ? null
                            : () => _invoke(MethodNames.cancelRecordingExport),
                      )
                    else
                      MenuAnchor(
                        style: NativeGlassMenuPanel.anchorStyle,
                        menuChildren: [
                          NativeGlassMenuPanel(
                            children: [
                              NativeGlassMenuItem(
                                label: '导出 GIF',
                                onPressed: enabled
                                    ? () =>
                                          _invoke(MethodNames.exportRecordingGIF)
                                    : null,
                              ),
                              NativeGlassMenuItem(
                                label: '导出 APNG',
                                onPressed: enabled
                                    ? () => _invoke(
                                        MethodNames.exportRecordingAPNG,
                                      )
                                    : null,
                              ),
                              NativeGlassMenuItem(
                                label: '导出 WebM',
                                onPressed: enabled
                                    ? () => _invoke(
                                        MethodNames.exportRecordingWebM,
                                      )
                                    : null,
                              ),
                            ],
                          ),
                        ],
                        builder: (context, controller, _) => ResultTextButton(
                          buttonKey: const Key('result-export-menu'),
                          label: '导出',
                          trailing: LucideIcons.chevronDown,
                          onPressed: enabled
                              ? () => controller.isOpen
                                    ? controller.close()
                                    : controller.open()
                              : null,
                        ),
                      ),
                    if (saving)
                      ResultTextButton(
                        buttonKey: const Key('result-cancel-save'),
                        label: '取消保存',
                        icon: LucideIcons.x,
                        primary: true,
                        busy: true,
                        onPressed: _pending
                            ? null
                            : () => _invoke(MethodNames.cancelRecordingExport),
                      )
                    else
                      ResultTextButton(
                        buttonKey: const Key('result-save'),
                        label: '保存',
                        icon: LucideIcons.save,
                        primary: true,
                        tooltip: '保存 MP4',
                        onPressed: enabled
                            ? () => _invoke(MethodNames.saveRecording)
                            : null,
                        busy:
                            _pending &&
                            _pendingMethod == MethodNames.saveRecording,
                      ),
                  ],
                ),
              ],
            ),
            if (_feedback != null || converting)
              ToolbarFeedback(
                toolbar: barRect,
                message:
                    _feedback ??
                    (saving
                        ? '正在保存…'
                        : '正在转换 ${((_state['progress'] as num).toDouble() * 100).round()}%'),
                isError: _feedback != null && _feedbackIsError,
                onHoverChanged: _feedback != null && _feedbackIsError
                    ? _onFeedbackHoverChanged
                    : null,
                onDismiss: _feedback != null && _feedbackIsError
                    ? _dismissFeedback
                    : null,
                liveRegion: _feedback != null || saving,
              ),
          ],
        );
      },
    );
  }

  Widget _resultPage(Widget child, {bool allowCopyVideo = false}) => Material(
    type: MaterialType.transparency,
    child: Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.escape) {
          if (!_pending) unawaited(_discard());
          return KeyEventResult.handled;
        }
        final keys = HardwareKeyboard.instance;
        final isCopyCombo =
            allowCopyVideo &&
            event.logicalKey == LogicalKeyboardKey.keyC &&
            keys.isMetaPressed &&
            !keys.isControlPressed &&
            !keys.isAltPressed &&
            !keys.isShiftPressed;
        if (!isCopyCombo) return KeyEventResult.ignored;
        if (!_pending && _phase == CapturePhase.videoReady) {
          unawaited(_copyVideo());
        }
        return KeyEventResult.handled;
      },
      child: child,
    ),
  );

  Widget _imageResult() {
    final pixels = Size(
      (_state['width'] as num).toDouble(),
      (_state['height'] as num).toDouble(),
    );
    final logical = pixels / (_state['previewScale'] as num).toDouble();
    final bytes = _state['imageBytes'] as Uint8List;
    final enabled = !_pending;

    return LayoutBuilder(
      builder: (context, constraints) {
        final barRect = Rect.fromLTWH(
          0,
          math.max(0, constraints.maxHeight - GlassMetrics.resultBarHeight),
          constraints.maxWidth,
          GlassMetrics.resultBarHeight,
        );
        return Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: ResultWindowCanvas(
                    child: LayoutBuilder(
                      builder: (context, mediaBox) {
                        const pad = GlassMetrics.resultCanvasPadding;
                        final availableWidth = math.max(
                          1.0,
                          mediaBox.maxWidth - pad * 2,
                        );
                        final scale = _fitWidth
                            ? math.min(1.0, availableWidth / logical.width)
                            : 1.0;
                        final displaySize = logical * scale;
                        return SingleChildScrollView(
                          primary: false,
                          scrollDirection: Axis.horizontal,
                          child: SingleChildScrollView(
                            key: const Key('long-image-scroll'),
                            primary: false,
                            scrollDirection: Axis.vertical,
                            child: SizedBox(
                              width: math.max(
                                mediaBox.maxWidth,
                                displaySize.width + pad * 2,
                              ),
                              height: math.max(
                                mediaBox.maxHeight,
                                displaySize.height + pad * 2,
                              ),
                              child: Center(
                                child: Padding(
                                  padding: const EdgeInsets.all(pad),
                                  child: ResultMediaFrame(
                                    child: Semantics(
                                      label:
                                          '长截图结果，${pixels.width.toInt()}×${pixels.height.toInt()}像素',
                                      child: SizedBox(
                                        key: const Key('long-image-preview'),
                                        width: displaySize.width,
                                        height: displaySize.height,
                                        child: Image.memory(
                                          bytes,
                                          fit: BoxFit.fill,
                                          filterQuality: scale == 1.0
                                              ? FilterQuality.none
                                              : FilterQuality.medium,
                                          gaplessPlayback: true,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                ResultWindowBar(
                  leading: [
                    ResultTextButton(
                      buttonKey: const Key('result-discard'),
                      label: '放弃',
                      weak: true,
                      tooltip: '放弃',
                      onPressed: _pending ? null : _discard,
                      busy:
                          _pending && _pendingMethod == MethodNames.cancelCapture,
                    ),
                    const ResultBarDivider(),
                    MenuAnchor(
                      style: NativeGlassMenuPanel.anchorStyle,
                      menuChildren: [
                        NativeGlassMenuPanel(
                          children: [
                            NativeGlassMenuItem(
                              label: '适合宽度',
                              checked: _fitWidth,
                              onPressed: () => setState(() => _fitWidth = true),
                            ),
                            NativeGlassMenuItem(
                              label: '实际大小',
                              checked: !_fitWidth,
                              onPressed: () => setState(() => _fitWidth = false),
                            ),
                          ],
                        ),
                      ],
                      builder: (context, controller, _) => ResultTextButton(
                        buttonKey: const Key('result-zoom-menu'),
                        label: _fitWidth ? '适合宽度' : '实际大小',
                        trailing: LucideIcons.chevronDown,
                        onPressed: enabled
                            ? () => controller.isOpen
                                  ? controller.close()
                                  : controller.open()
                            : null,
                      ),
                    ),
                  ],
                  trailing: [
                    ResultTextButton(
                      buttonKey: const Key('result-copy'),
                      label: '复制',
                      icon: LucideIcons.copy,
                      onPressed: enabled ? _copyImage : null,
                      busy:
                          _pending &&
                          _pendingMethod == MethodNames.copyScreenshot,
                    ),
                    ResultTextButton(
                      buttonKey: const Key('result-save'),
                      label: '保存',
                      icon: LucideIcons.save,
                      primary: true,
                      onPressed: enabled
                          ? () => _invoke(MethodNames.saveScreenshot, {
                              'name': screenshotFilename(DateTime.now()),
                            })
                          : null,
                      busy:
                          _pending &&
                          _pendingMethod == MethodNames.saveScreenshot,
                    ),
                  ],
                ),
              ],
            ),
            if (_feedback != null)
              ToolbarFeedback(
                toolbar: barRect,
                message: _feedback!,
                isError: _feedbackIsError,
                onHoverChanged: _feedbackIsError
                    ? _onFeedbackHoverChanged
                    : null,
                onDismiss: _feedbackIsError ? _dismissFeedback : null,
              ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) => NativeGlassApp(
    title: 'TranSnap 采集',
    home: Builder(builder: _buildPage),
  );

  Widget _buildPage(BuildContext context) {
    if (_phase == CapturePhase.idle) {
      return const SizedBox.shrink();
    }
    if (_phase == CapturePhase.failed) {
      if (_feedback == null) return const SizedBox.shrink();
      return Material(
        type: MaterialType.transparency,
        child: LayoutBuilder(
          builder: (context, constraints) => Stack(
            children: [
              ToolbarFeedback(
                toolbar: Rect.fromLTWH(
                  GlassMetrics.toolbarPadding,
                  math.max(
                    GlassMetrics.toolbarPadding,
                    constraints.maxHeight -
                        GlassMetrics.toolbarPadding -
                        GlassMetrics.hitSize,
                  ),
                  math.max(
                    0.0,
                    constraints.maxWidth - GlassMetrics.toolbarPadding * 2,
                  ),
                  GlassMetrics.hitSize,
                ),
                message: _feedback!,
                isError: _feedbackIsError,
                onHoverChanged: _feedbackIsError
                    ? _onFeedbackHoverChanged
                    : null,
                onDismiss: _feedbackIsError ? _dismissFeedback : null,
              ),
            ],
          ),
        ),
      );
    }
    if ([
      CapturePhase.preparing,
      CapturePhase.recording,
      CapturePhase.pausing,
      CapturePhase.paused,
      CapturePhase.scrolling,
      CapturePhase.finalizing,
    ].contains(_phase)) {
      return Material(
        type: MaterialType.transparency,
        child: LayoutBuilder(
          builder: (context, constraints) => Stack(
            children: [
              Align(
                alignment: Alignment.bottomRight,
                child: Padding(
                  padding: const EdgeInsets.all(GlassMetrics.toolbarPadding),
                  child: SizedBox(
                    height: GlassMetrics.hitSize,
                    child: _active(),
                  ),
                ),
              ),
              if (_feedback != null)
                ToolbarFeedback(
                  toolbar: Rect.fromLTWH(
                    GlassMetrics.toolbarPadding,
                    constraints.maxHeight -
                        GlassMetrics.toolbarPadding -
                        GlassMetrics.hitSize,
                    constraints.maxWidth - GlassMetrics.toolbarPadding * 2,
                    GlassMetrics.hitSize,
                  ),
                  message: _feedback!,
                  isError: _feedbackIsError,
                  onHoverChanged: _feedbackIsError
                      ? _onFeedbackHoverChanged
                      : null,
                  onDismiss: _feedbackIsError ? _dismissFeedback : null,
                ),
            ],
          ),
        ),
      );
    }
    if (_phase == CapturePhase.imageReady) return _resultPage(_imageResult());
    return _resultPage(_videoResult(), allowCopyVideo: true);
  }
}
