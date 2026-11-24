import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../common/constants/capture_phase.dart';
import '../common/constants/channel_names.dart';
import '../common/constants/glass_metrics.dart';
import '../common/constants/method_names.dart';
import '../common/utils/screenshot_filename.dart';
import '../common/widgets/app_motion.dart';
import '../common/widgets/native_glass.dart';
import '../common/widgets/result_window.dart';
import '../common/widgets/toolbar_feedback.dart';

/// 采集工具的统一悬浮控制条、长图保留页及视频结果；选区准备由截图选择层负责。
class CaptureApp extends StatefulWidget {
  /// channel 为会话状态及显式采集命令通道；可注入以验证界面状态。
  const CaptureApp({
    super.key,
    this.channel = const MethodChannel(ChannelNames.capture),
  });

  final MethodChannel channel;

  /// 无参数；返回采集控制状态，不创建翻译监听或数据库。
  @override
  State<CaptureApp> createState() => _CaptureAppState();
}

/// 维护实际采集状态和一秒响应；GIF参数由已保存的截图设置决定。
class _CaptureAppState extends State<CaptureApp> {
  // 首个原生状态到达前为空闲；原生每次状态都带 phase，缺少即按协议错误抛出（#124）。
  Map<String, dynamic> _state = {'phase': CapturePhase.idle.name};
  bool _pending = false;
  String? _pendingMethod;
  String? _feedback;
  bool _feedbackIsError = false;
  bool _feedbackHovered = false;
  Timer? _feedbackTimer;
  // 长截图默认使用「适合宽度」模式，每次新结果重置（#67 第 5 条、#145）。
  bool _fitWidth = true;

  CapturePhase get _phase => CapturePhase.parse(_state['phase'] as String);

  /// 无参数；订阅原生状态并请求当前会话，不枚举来源或打开准备页面。
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

  /// 无参数；加载当前资源快照，真实错误由当前界面呈现。
  Future<void> _initialize() async {
    await _invoke(MethodNames.getCaptureState);
  }

  /// 无参数；解除平台订阅并取消本窗口反馈计时。
  @override
  void dispose() {
    widget.channel.setMethodCallHandler(null);
    _feedbackTimer?.cancel();
    super.dispose();
  }

  /// state为完整快照；仅新的保存结果或错误触发反馈，重复进度回包不延长文字寿命。
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

  /// message 为操作结果；普通提示显示 1000ms，isError 为 true 时采用错误样式并保持 2000ms、
  /// 支持悬停暂停与手动关闭，不改变媒体状态（#144）。
  void _showFeedback(String message, {bool isError = false}) {
    _feedbackTimer?.cancel();
    setState(() {
      _feedback = message;
      _feedbackIsError = isError;
      if (!isError) _feedbackHovered = false;
    });
    _startFeedbackTimer();
  }

  /// 无参数；在非悬停状态启动提示倒计时（错误 2s、普通 1s），无返回值。
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

  /// hovered 为鼠标是否停留在错误气泡上；悬停期间暂停倒计时，移开后重计 2s，无返回值（#144）。
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

  /// 无参数；手动关闭当前提示气泡并重置状态，无返回值（#144）。
  void _dismissFeedback() {
    if (_feedback == null) return;
    _feedbackTimer?.cancel();
    setState(() {
      _feedback = null;
      _feedbackIsError = false;
      _feedbackHovered = false;
    });
  }

  /// method/arguments 为已知采集命令及参数；并发等待时忽略重入，返回命令是否成功完成（未抛出平台异常），错误只显示在当前窗口。
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

  /// 无参数；立即放弃当前会话，原生停止后台任务并保留已经保存的文件。
  Future<void> _discard() => _invoke(MethodNames.cancelCapture);

  /// 无参数；复制会话中的完整源像素PNG，成功后显示一秒，失败沿用命令错误。
  Future<void> _copyImage() async {
    await _invoke(MethodNames.copyScreenshot);
    if (!mounted || _feedback != null) return;
    _showFeedback('已复制');
  }

  /// 无参数；将完整录制或裁剪片段复制到剪贴板，成功后显示「已复制视频」，失败沿用原生错误反馈（#142）。
  Future<void> _copyVideo() async {
    final ok = await _invoke(MethodNames.copyRecording);
    if (!ok || !mounted || _feedback != null) return;
    _showFeedback('已复制视频');
  }

  /// 无参数；两种采集共用四个独立材料气泡，状态只读，三操作沿用真实阶段约束。
  Widget _active() {
    final paused = _phase == CapturePhase.paused;
    final scrolling = _state['kind'] == 'scrolling';
    final seconds = ((_state['elapsed'] as num?)?.toDouble() ?? 0).floor();
    final elapsed =
        '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
    final liveDetail = (_state['detail'] as String?) ?? '';
    final liveStatus = liveDetail.isEmpty ? '实时翻译' : liveDetail;
    final progress = _state['kind'] == 'liveTranslation'
        // 同步录制时在翻译状态前显示录制时长。
        ? (_state['recording'] == true
              ? '录制：$elapsed · $liveStatus'
              : liveStatus)
        : scrolling
        ? '长截图：${_state['height'] ?? 0} 像素'
        : '录制：$elapsed';
    final label = switch (_phase) {
      // 录制倒计时期间显示剩余秒数，其余准备过程显示通用文案（#129）。
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

    /// description 为上方提示，child 为状态或操作，busy 为是否显示按钮等待进度环；返回不共享外壳的32pt玻璃气泡。
    Widget bubble(String description, Widget child, {bool busy = false}) =>
        Tooltip(
          message: description,
          preferBelow: false,
          verticalOffset: GlassMetrics.hitSize / 2 + GlassMetrics.toastGap,
          constraints: const BoxConstraints(
            minHeight: GlassMetrics.buttonHeight,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          child: NativeGlassSurface(
            material: true,
            radius: GlassMetrics.controlRadius,
            busy: busy,
            child: child,
          ),
        );

    /// index 为错峰序号，description 为提示与可访问名，icon 为操作图标，action 为空时禁用，busy 控制外圈等待进度环；返回明确命中尺寸的按钮。
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
      child: SizedBox.square(
        dimension: GlassMetrics.hitSize,
        child: bubble(
          description,
          IconButton(
            onPressed: action,
            padding: EdgeInsets.zero,
            icon: Icon(
              icon,
              size: GlassMetrics.icon,
              semanticLabel: description,
            ),
          ),
          busy: busy,
        ),
      ),
    );

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: GentleReveal(
            key: const ValueKey('capture-bubble-0'),
            staggerIndex: 0,
            blur: false,
            child: bubble(
              status,
              ConstrainedBox(
                constraints: const BoxConstraints(
                  minWidth: GlassMetrics.buttonMinWidth,
                  maxWidth: 188,
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
              ? () => _invoke(MethodNames.setCapturePaused, {'paused': !paused})
              : null,
          busy: _pending && _pendingMethod == MethodNames.setCapturePaused,
        ),
        const SizedBox(width: 6),
        action(
          2,
          '结束',
          LucideIcons.squareStop,
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
    );
  }

  /// seconds 为秒数；格式化为 m:ss，供录制结果播放条使用。
  String _formatDuration(double seconds) {
    final total = seconds.isFinite && seconds > 0 ? seconds.floor() : 0;
    return '${total ~/ 60}:${(total % 60).toString().padLeft(2, '0')}';
  }

  /// seconds 为目标秒数；仅转发合法位置给原生 AVPlayer，避免频繁拖动阻塞按钮禁用态。
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

  /// 无参数；返回统一结果窗骨架：中性衬底（四周 24pt 留白）+ 底部 52pt 实底操作栏，
  /// 标题栏与播放器控制条隐藏，全部操作收进底部栏（#67 第 4、7 条、#145）。
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
    // 文件复制没有可测量的编码进度；缺少 progress 的忙碌快照只显示保存状态。
    final saving = converting && _state['progress'] == null;
    final enabled = !_pending && !converting;
    // 转换中的导出类型；只有该类型的按钮变为取消，其余导出按钮禁用。
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
        // 最小窗口 600pt 下预留所有固定按钮，剩余宽度分配给播放进度滑块并封顶 220pt。
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

  /// child 为视频或长图结果，allowCopyVideo 为真时响应 ⌘C 复制视频；Escape 立即放弃当前会话并保留已保存文件。
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

  /// 无参数；返回长截图结果窗：中性衬底四周 24pt 留白，默认适合宽度且可切换实际大小，底部 52pt 操作栏提供放弃、缩放与复制保存（#67 第 5、7 条、#145）。
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

  /// context 为窗口上下文；使用项目统一原生玻璃主题与窗口背景。
  @override
  Widget build(BuildContext context) => NativeGlassApp(
    title: 'TranSnap 采集',
    home: Builder(builder: _buildPage),
  );

  /// context为内部主题；录制与长截图共用状态条，完成后分别展示视频或长图结果。
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
      // 面板上部保留提示空间；仅四个气泡绘制材料，外围不绘制背景或阴影。
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
