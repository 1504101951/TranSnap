import 'drawing_preferences.dart';
import '../common/widgets/line_icon.dart';
import '../common/constants/motion_metrics.dart';
import '../common/constants/preference_keys.dart';

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:ui' as ui;
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../common/constants/channel_names.dart';
import '../common/constants/drawing_metrics.dart';
import '../common/constants/glass_metrics.dart';
import '../common/constants/method_names.dart';
import '../common/constants/screenshot_enums.dart';
import '../common/utils/geometry.dart';
import '../common/utils/screenshot_filename.dart';
import '../common/widgets/app_motion.dart';
import '../common/widgets/native_glass.dart';
import '../common/widgets/result_window.dart';
import '../common/widgets/toolbar_feedback.dart';
import '../common/widgets/native_brush_cursor.dart';
import '../common/widgets/native_resize_cursor.dart';
import 'beautify.dart';
import 'edit_document.dart';
import 'drawing_style.dart';
import 'drawing_controls.dart';
import 'measure_layer.dart';
import 'box_transform.dart';
import 'sticker_panel.dart';
import 'stickers.dart';
import 'recognized_text_panel.dart';
import 'screenshot_editor_layout.dart';
import '../settings/screenshot_toolbar_preferences.dart';
import '../common/constants/toolbar_grid.dart';
import '../common/constants/screenshot_actions.dart';

MouseCursor cursorForEditHandle(
  BoxHandle? handle, {
  required bool plusWhenIdle,
  required MethodChannel channel,
}) {
  switch (handle) {
    case BoxHandle.n:
    case BoxHandle.s:
      return SystemMouseCursors.resizeUpDown;
    case BoxHandle.e:
    case BoxHandle.w:
      return SystemMouseCursors.resizeLeftRight;
    case BoxHandle.nw:
    case BoxHandle.se:
      return NativeResizeCursor(
        ResizeCursorAxes.northWestSouthEast,
        channel: channel,
      );
    case BoxHandle.ne:
    case BoxHandle.sw:
      return NativeResizeCursor(
        ResizeCursorAxes.northEastSouthWest,
        channel: channel,
      );
    case BoxHandle.move:
    case BoxHandle.rotate:
      return SystemMouseCursors.grab;
    case null:
      return plusWhenIdle
          ? SystemMouseCursors.precise
          : SystemMouseCursors.basic;
  }
}

enum _ExpandedRow { recording, beautify, ratio }

final _arrowDirections = <LogicalKeyboardKey, Offset>{
  LogicalKeyboardKey.arrowLeft: Offset(-1, 0),
  LogicalKeyboardKey.arrowRight: Offset(1, 0),
  LogicalKeyboardKey.arrowUp: Offset(0, -1),
  LogicalKeyboardKey.arrowDown: Offset(0, 1),
};

class ScreenshotApp extends StatefulWidget {
  const ScreenshotApp({
    super.key,
    this.channel = const MethodChannel(ChannelNames.screenshot),
  });

  final MethodChannel channel;

  @override
  State<ScreenshotApp> createState() => _ScreenshotAppState();
}

class _ScreenshotAppState extends State<ScreenshotApp>
    with TickerProviderStateMixin {
  final EditDocument _document = EditDocument();
  final FocusNode _focusNode = FocusNode();
  _ExpandedRow? _expandedRow;
  bool get _recordingExpanded => _expandedRow == _ExpandedRow.recording;
  bool _liveTranslation = false;
  bool get _liveExpanded => _recordingExpanded && _liveTranslation;
  bool get _beautifyExpanded => _expandedRow == _ExpandedRow.beautify;

  double? _cropRatio;

  BeautifyStyle? _beautify;
  CaptureTarget _recordingTarget = CaptureTarget.region;

  List<StickerEntry> _stickers = const [];
  String? _stickerDirectory;

  ({BoxHandle handle, BoxFrame start})? _stickerDrag;

  int _recordingDelay = 0;
  bool _recordingClickEffectEnabled = false;
  bool _childrenRevealed = false;
  bool _toolbarExpanded = false;
  bool _toolbarGridShown = false;
  bool _toolbarSplitting = false;
  final _favoritesKey = GlobalKey();
  late final _toolbarGlide = AnimationController.unbounded(
    vsync: this,
    value: 1,
  );
  Offset _toolbarShift = Offset.zero;
  final _gridBlockKeys = <String, GlobalKey>{};
  List<({_ToolbarCells group, Offset offset, Size size})> _ghosts = const [];
  Size _ghostTarget = Size.zero;
  late final _ghostMerge = AnimationController.unbounded(
    vsync: this,
    value: 1,
  );

  Offset get _glideOffset => _toolbarShift * (1 - _toolbarGlide.value);
  DateTime? _lastToolbarTab;
  bool _toolbarHandleHovered = false;
  bool _toolbarLifted = false;

  static const _favoritesGroupKey = 'screenshot-favorites-group';
  static const _toolbarTabInterval = Duration(milliseconds: 300);
  Map<Object?, Object?>? _recordingApplication;
  List<Map<Object?, Object?>> _recordingApplications = [];
  bool _loadingApplications = false;
  int _applicationRequest = 0;
  final FocusNode _textFocus = FocusNode();
  final TextEditingController _textController = TextEditingController();
  final List<Offset> _strokePoints = [];

  Rect _strokeBounds = Rect.zero;

  Map<Object?, Object?> _capture = {};
  bool get _isOpenedImage =>
      _capture['canCaptureMedia'] != true && _capture['imageScale'] != null;
  final GlobalKey _editorKey = GlobalKey();
  DrawingPreferences _drawing = DrawingPreferences();
  Future<void> _drawingSave = Future.value();
  DrawingStyle get _nextStyle => _drawing.styleFor(_styleTool);
  set _nextStyle(DrawingStyle value) =>
      _drawing = _drawing.copyWith(tool: _styleTool, style: value);
  ShapeMode get _shapeMode => _drawing.brushMode;
  ShapeVariant get _styleShape => _styleSelection?.shape ?? _drawing.shape;
  String? _selectedShapeId;
  bool _shapeSelecting = false;

  bool _dialogOpen = false;

  final _stickerAnchor = GlobalKey();

  final _buttonKeys = <String, GlobalKey>{};

  ({String parent, String kind, List<String> cells})? _closing;

  ({String parent, String kind, List<String> cells})? _open;

  String? _lastActiveId;

  ({Offset start, Offset end})? _ruler;

  final ValueNotifier<Offset?> _picker = ValueNotifier(null);

  ByteData? _sourcePixels;
  Future<void>? _pixelLoad;

  ScreenshotConfirmAction _confirmAction = ScreenshotConfirmAction.copy;

  ScreenshotTool _tool = ScreenshotTool.crop;
  bool _busy = false;

  int _heldModifiers = 0;

  String? _busyId;
  bool _failed = false;
  bool _feedbackHovered = false;
  bool _feedbackAutoDismiss = true;
  bool _textInputOpen = false;
  String? _feedbackMessage;
  Timer? _feedbackTimer;
  final ValueNotifier<Rect> _toolbarRect = ValueNotifier(Rect.zero);

  void _setFeedback(
    String? value, {
    bool isError = false,
    bool autoDismiss = true,
  }) {
    _feedbackTimer?.cancel();
    _feedbackMessage = value;
    _failed = value != null && isError;
    _feedbackAutoDismiss = value != null && autoDismiss;
    if (value == null) _feedbackHovered = false;
    _startFeedbackTimer();
  }

  void _startFeedbackTimer() {
    _feedbackTimer?.cancel();
    if (_feedbackMessage == null ||
        !_feedbackAutoDismiss ||
        (_failed && _feedbackHovered)) {
      return;
    }
    final duration = _failed
        ? GlassMetrics.errorFeedbackDuration
        : GlassMetrics.feedbackDuration;
    _feedbackTimer = Timer(duration, () {
      if (!mounted) return;
      setState(() {
        _feedbackMessage = null;
        _failed = false;
        _feedbackHovered = false;
      });
    });
  }

  void _onFeedbackHoverChanged(bool hovered) {
    if (_feedbackHovered == hovered) return;
    _feedbackHovered = hovered;
    if (!_failed) return;
    if (hovered) {
      _feedbackTimer?.cancel();
    } else {
      _startFeedbackTimer();
    }
  }

  void _dismissFeedback() {
    if (_feedbackMessage == null) return;
    setState(() => _setFeedback(null));
  }

  String? _savedPath;
  List<_OcrOverlay> _ocrOverlays = [];

  Offset _translationOrigin = Offset.zero;

  ({String text, List<RecognizedCode> codes})? _recognition;

  final ValueNotifier<Offset> _recognizedOffset = ValueNotifier(Offset.zero);
  Offset? _doubleTapPoint;
  Offset? _dragStart;
  Offset? _dragCurrent;
  EditAnnotation? _previewAnnotation;

  DrawingStyle _textStyle = const DrawingStyle();
  double _fontSize = ScreenshotDefaults.fontSize;

  String? _selectedTextId;

  String? _lastTextTapId;
  DateTime _lastTextTapAt = DateTime.fromMillisecondsSinceEpoch(0);

  String? _editingTextId;

  BoxHandle? _resizeHandle;

  double _pixelRatio = 1;

  Rect? _previewCrop;

  ScreenshotToolbarPreferences _toolbar = ScreenshotToolbarPreferences();
  static const _toolIds = {
    ScreenshotActions.cursor: ScreenshotTool.cursor,
    ScreenshotActions.crop: ScreenshotTool.crop,
    ScreenshotActions.rect: ScreenshotTool.rect,
    ScreenshotActions.arrow: ScreenshotTool.arrow,
    ScreenshotActions.step: ScreenshotTool.step,
    ScreenshotActions.text: ScreenshotTool.text,
    ScreenshotActions.brush: ScreenshotTool.brush,
    ScreenshotActions.eyedropper: ScreenshotTool.eyedropper,
    ScreenshotActions.ruler: ScreenshotTool.ruler,
  };
  bool _cropSelected = false;

  String get _activeId => _recordingExpanded
      ? ScreenshotActions.record
      : _beautifyExpanded
      ? ScreenshotActions.beautify
      : _expandedRow == _ExpandedRow.ratio
      ? ScreenshotActions.ratio
      : _toolIds.entries.firstWhere((entry) => entry.value == _tool).key;

  String? get _group {
    final id = _activeId;
    return _toolbar.parentOf(id) ??
        (ScreenshotActions.composable[id]?.hostsChildren == true ? id : null);
  }

  List<String> _attributeIds(Map<String, VoidCallback?> actions) => actions.keys
      .where(
        (id) =>
            id != ScreenshotActions.reveal &&
            !ScreenshotActions.icons.containsKey(id),
      )
      .toList();

  void _syncClosing(bool reduced, Map<String, VoidCallback?> actions) {
    final active = _activeId;
    final children = _visibleChildren;
    final attributes = _attributeIds(actions);
    final strips = _strips();
    final hasSecondary =
        children.isNotEmpty || attributes.isNotEmpty || strips.isNotEmpty;
    final open = children.isNotEmpty && _group != null
        ? (parent: _group!, kind: 'children', cells: children)
        : attributes.isNotEmpty
        ? (parent: _group ?? active, kind: 'attributes', cells: attributes)
        : null;
    final previous = _closing == null ? _open : null;
    final placed = {
      for (final column in _toolbar.columns) ...column.slots,
      ...children,
      ...attributes,
    };
    if (reduced || hasSecondary) {
      _closing = null;
    } else if (_closing != null &&
        _lastActiveId != null &&
        _lastActiveId != active) {
      _closing = null;
    } else if (previous != null &&
        previous.cells.any((id) => !placed.contains(id))) {
      _closing = previous;
    }
    _open = open;
    _lastActiveId = active;
  }

  List<String> get _visibleChildren =>
      _childrenRevealed ? _visibleChildrenOf(_group) : const [];

  List<String> _visibleChildrenOf(String? parent) => [
    for (final id in _toolbar.children[parent] ?? const <String>[])
      if (!_toolbar.hidden.contains(id)) id,
  ];

  static const _busyCell = 'screenshot-busy';

  List<_ToolbarLine> _toolbarLines(
    Map<String, VoidCallback?> actions,
    int perLine,
  ) {
    List<_ToolbarLine> pair(List<_ToolbarCells> groups, {String? anchor}) => [
      for (var start = 0; start < groups.length; start += perLine)
        (
          groups: groups.sublist(
            start,
            math.min(start + perLine, groups.length),
          ),
          strip: null,
          anchor: anchor,
          indent: 0.0,
          caret: null,
        ),
    ];
    List<List<String>> chunk(List<String> ids) => [
      for (var start = 0; start < ids.length; start += ToolbarGrid.slots)
        ids.sublist(start, math.min(start + ToolbarGrid.slots, ids.length)),
    ];
    final attributes = _attributeIds(actions);
    final inserted = <_ToolbarCells>[
      for (final (index, cells) in chunk(_visibleChildren).indexed)
        (
          key: 'screenshot-children-group-$index',
          cells: <String?>[...cells],
          modifiers: null,
        ),
      for (final (index, cells) in chunk(attributes).indexed)
        (
          key: 'screenshot-attributes-group-$index',
          cells: <String?>[...cells],
          modifiers: null,
        ),
    ];
    final anchor = _group ?? _activeId;
    final closing = _closing;
    final groups = <_ToolbarCells>[];
    int? anchorGroup;
    int? closingGroup;
    final sources = [
      (
        key: _favoritesGroupKey,
        cells: <String?>[..._toolbar.favorites],
        modifiers: 0,
      ),
      if (_toolbarGridShown)
        for (final (index, column) in _toolbar.columns.indexed)
          (
            key: 'screenshot-grid-group-$index',
            cells: [
              for (final id in column.slots)
                id == null || _toolbar.hidden.contains(id) ? null : id,
            ],
            modifiers: column.modifiers,
          ),
    ];
    for (final source in sources) {
      if (source.key != _favoritesGroupKey &&
          source.cells.every((id) => id == null)) {
        continue;
      }
      if (anchorGroup == null && source.cells.contains(anchor)) {
        anchorGroup = groups.length;
      }
      if (closing != null &&
          closingGroup == null &&
          source.cells.contains(closing.parent)) {
        closingGroup = groups.length;
      }
      groups.add(source);
    }
    final shown = {
      for (final group in [...groups, ...inserted]) ...group.cells,
    };
    final status = [
      if (actions.containsKey(ScreenshotActions.reveal))
        ScreenshotActions.reveal,
      if (_busy && !shown.contains(_busyId)) _busyCell,
    ];
    if (status.isNotEmpty) {
      groups.add((
        key: 'screenshot-status-group',
        cells: status,
        modifiers: null,
      ));
    }
    final lines = pair(groups);
    final extra = <int, List<_ToolbarLine>>{};
    final leaving = [
      for (final id in closing?.cells ?? const <String>[])
        if (!shown.contains(id)) id,
    ];
    if (closing != null && leaving.isNotEmpty) {
      final at = closingGroup == null
          ? lines.length
          : closingGroup ~/ perLine + 1;
      (extra[at] ??= []).addAll(
        pair([
          for (final (index, cells) in chunk(leaving).indexed)
            (
              key: 'screenshot-closing-group-$index',
              cells: <String?>[...cells],
              modifiers: null,
            ),
        ], anchor: closing.parent),
      );
    }
    final after = anchorGroup == null
        ? lines.length
        : anchorGroup ~/ perLine + 1;
    final strips = _strips();
    (extra[after] ??= []).addAll([
      ...pair(inserted, anchor: anchor),
      for (final MapEntry(:key, :value) in strips.entries)
        (
          groups: const <_ToolbarCells>[],
          strip: key,
          anchor: value.anchor,
          indent: 0.0,
          caret: null,
        ),
    ]);
    return _placeTrays([
      for (var index = 0; index <= lines.length; index++) ...[
        ...?extra[index],
        if (index < lines.length) lines[index],
      ],
    ], strips);
  }

  static List<_ToolbarLine> _placeTrays(
    List<_ToolbarLine> lines,
    Map<String, _Strip> strips,
  ) {
    final centers = <String, double>{};
    void record(_ToolbarLine line) {
      if (line.strip != null) {
        const step = ToolbarGrid.trayButton + 4;
        for (final MapEntry(:key, :value)
            in strips[line.strip]!.hosts.entries) {
          centers[key] =
              line.indent +
              ToolbarGrid.trayPadding +
              value * step +
              ToolbarGrid.trayButton / 2;
        }
        return;
      }
      final tray = _isTray(line);
      var start = tray ? line.indent + ToolbarGrid.trayPadding : 0.0;
      for (final group in line.groups) {
        final step = tray ? ToolbarGrid.trayButton + 4 : 36.0;
        final head = tray ? 0.0 : ToolbarGrid.blockPadding + _hintRun(group);
        for (final (slot, id) in group.cells.indexed) {
          if (id == null) continue;
          centers[id] = start + head + slot * step + step / 2 - 2;
        }
        start += tray
            ? _trayRun(group.cells.length) +
                  ToolbarGrid.traySeparatorGap * 2 +
                  1
            : _blockLength(group) + ToolbarGrid.blockGap;
      }
    }

    _ToolbarLine hang(_ToolbarLine line, double limit) {
      const first = ToolbarGrid.trayPadding + ToolbarGrid.trayButton / 2;
      final center = centers[line.anchor];
      final bare = _lineLength(line, strips);
      final indent = center == null
          ? 0.0
          : math.min(
              math.max(0.0, center - first),
              math.max(0.0, limit - bare),
            );
      return (
        groups: line.groups,
        strip: line.strip,
        anchor: line.anchor,
        indent: indent,
        caret: center == null ? first : center - indent,
      );
    }

    final placed = <_ToolbarLine>[];
    for (final line in lines) {
      final next = _isTray(line) ? hang(line, double.infinity) : line;
      if (next.strip == null) record(next);
      placed.add(next);
    }
    final widest = [
      0.0,
      for (final line in placed)
        if (line.strip == null) _lineLength(line, strips),
    ].reduce(math.max);
    for (final (index, line) in placed.indexed) {
      if (line.strip == null) continue;
      placed[index] = hang(line, widest);
      record(placed[index]);
    }
    return placed;
  }

  Map<String, _Strip> _strips() {
    const step = ToolbarGrid.trayButton + 4;
    return {
      if (_beautifyExpanded)
        'screenshot-beautify-row': (
          count:
              1 +
              ((BeautifyMetrics.paddingMenuWidth + 4) / step).ceil() +
              ((BeautifyMetrics.radiusMenuWidth + 4) / step).ceil(),
          anchor: ScreenshotActions.beautify,
          hosts: const {},
        ),
    if (_expandedRow == _ExpandedRow.ratio)
      'ratio-row': (
        count: CropMetrics.ratios.length,
        anchor: ScreenshotActions.ratio,
        hosts: const {},
      ),
    if (_recordingExpanded && _tool == ScreenshotTool.crop)
      'recording-targets-row': (
        count: 7,
        anchor: ScreenshotActions.record,
        hosts: const {'recording-target-application': 1},
      ),
      if (_recordingExpanded &&
          _tool == ScreenshotTool.crop &&
          _recordingTarget == CaptureTarget.application)
        'recording-applications-row': (
          count: math.max(1, _recordingApplications.length),
          anchor: 'recording-target-application',
          hosts: const {},
        ),
    };
  }

  static double _cellsLength(int count) =>
      count * 32.0 + math.max(0, count - 1) * 4;

  static double _trayRun(int count) =>
      count * ToolbarGrid.trayButton + math.max(0, count - 1) * 4;

  static double _hintRun(_ToolbarCells group) =>
      group.modifiers == null ? 0 : ToolbarGrid.hintExtent + 4;

  static double _blockLength(_ToolbarCells group) =>
      ToolbarGrid.blockPadding * 2 +
      _hintRun(group) +
      _cellsLength(group.cells.length);

  static bool _isTray(_ToolbarLine line) =>
      line.groups.isNotEmpty &&
      line.groups.first.modifiers == null &&
      line.groups.first.key != 'screenshot-status-group';

  static double _lineLength(_ToolbarLine line, Map<String, _Strip> strips) {
    if (line.strip != null) {
      return line.indent +
          ToolbarGrid.trayPadding * 2 +
          _trayRun(strips[line.strip]!.count);
    }
    if (_isTray(line)) {
      return line.indent +
          ToolbarGrid.trayPadding * 2 +
          line.groups.fold(
            0.0,
            (sum, group) => sum + _trayRun(group.cells.length),
          ) +
          (line.groups.length - 1) * (ToolbarGrid.traySeparatorGap * 2 + 1);
    }
    return line.groups.fold(0.0, (sum, group) => sum + _blockLength(group)) +
        (line.groups.length - 1) * ToolbarGrid.blockGap;
  }

  static double _lineThickness(_ToolbarLine line) =>
      line.strip != null || _isTray(line)
      ? ToolbarGrid.trayThickness
      : ToolbarGrid.blockThickness;

  ({List<double> lengths, double grouped, double blocks, double thickness})
  _lineLengths(Map<String, VoidCallback?> actions, int perLine) {
    final strips = _strips();
    final lines = _toolbarLines(actions, perLine);
    return (
      lengths: [for (final line in lines) _lineLength(line, strips)],
      grouped: [
        0.0,
        for (final line in lines)
          if (line.strip == null) _lineLength(line, strips),
      ].reduce(math.max),
      blocks: [
        0.0,
        for (final line in lines)
          if (line.strip == null && !_isTray(line)) _lineLength(line, strips),
      ].reduce(math.max),
      thickness:
          lines.fold(0.0, (sum, line) => sum + _lineThickness(line)) +
          math.max(0, lines.length - 1) * ToolbarGrid.lineGap,
    );
  }

  bool _onModifierKey(KeyEvent event) {
    final held = ToolbarModifiers.pressed() & ~ToolbarModifiers.shift;
    if (held != _heldModifiers && mounted) {
      setState(() => _heldModifiers = held);
    }
    return false;
  }

  @override
  void initState() {
    super.initState();
    _document.addListener(_onDocumentChanged);
    HardwareKeyboard.instance.addHandler(_onModifierKey);
    widget.channel.setMethodCallHandler((call) async {
      if (call.method == MethodNames.screenshotToolbarChanged) {
        final map = Map<Object?, Object?>.from(call.arguments as Map);
        final next = ScreenshotToolbarPreferences.fromMap(map);
        if (mounted) {
          setState(() {
            _toolbar = next;
            _confirmAction = ScreenshotConfirmAction.parse(
              map[PreferenceKeys.screenshotConfirmAction] as String?,
            );
            _recordingDelay = map[PreferenceKeys.recordingDelay] as int? ?? 0;
            _recordingClickEffectEnabled =
                map[PreferenceKeys.recordingClickEffectEnabled] as bool? ??
                false;
            _readStickers(map);
          });
        }
      } else if (call.method == MethodNames.screenshotChanged) {
        _replace(Map<Object?, Object?>.from(call.arguments as Map));
      } else if (call.method == MethodNames.publishScreenshotTranslation) {
        final map = Map<Object?, Object?>.from(call.arguments as Map);
        if (!mounted || map['id'] != _capture['id']) return;
        final status = map['status'] as String;
        setState(() {
          _ocrOverlays = [
            for (final item in map['overlays'] as List)
              _OcrOverlay.fromMap(item as Map, _translationOrigin),
          ];
          _setFeedback(
            status.isEmpty ? null : status,
            isError: false,
            autoDismiss: map['failed'] != true,
          );
        });
      } else if (call.method == MethodNames.screenshotToolbarSlot) {
        final args = call.arguments as Map;
        if (_capture['id'] == null ||
            _capture['id'] != args['id'] ||
            _textInputOpen) {
          return;
        }
        _runToolbarSlot(args['modifiers'] as int, args['digit'] as int);
      } else if (call.method == MethodNames.screenshotToolbarTab) {
        if (_capture['id'] == null ||
            _capture['id'] != (call.arguments as Map)['id'] ||
            _textInputOpen) {
          return;
        }
        final now = DateTime.now();
        final last = _lastToolbarTab;
        if (last != null && now.difference(last) <= _toolbarTabInterval) {
          _lastToolbarTab = null;
          _toggleToolbarExpanded();
        } else {
          _lastToolbarTab = now;
        }
      } else if (call.method == MethodNames.deleteScreenshotSelection) {
        final id = (call.arguments as Map)['id'];
        if (_capture['id'] == null || _capture['id'] != id || _textInputOpen) {
          return;
        }
        _deleteSelection();
      } else if (call.method == MethodNames.nudgeScreenshotCrop) {
        final args = call.arguments as Map;
        if (_capture['id'] == null ||
            _capture['id'] != args['id'] ||
            _textInputOpen) {
          return;
        }
        _nudgeCrop(
          Offset(
            (args['dx'] as int).toDouble(),
            (args['dy'] as int).toDouble(),
          ),
          large: args['shift'] as bool,
          resize: args['option'] as bool,
        );
      } else if (call.method == MethodNames.confirmScreenshot) {
        final id = (call.arguments as Map)['id'];
        if (_capture['id'] == null || _capture['id'] != id) return;
        await _confirmScreenshot();
      } else if (call.method == MethodNames.escapePressed) {
        if (_expandedRow != null) {
          setState(() {
            _expandedRow = null;
            unawaited(_syncRecordingPreview());
            unawaited(_syncLivePreview());
          });
          return;
        }
        if (_dialogOpen) {
          Navigator.of(_editorKey.currentContext!).pop();
          return;
        }
        if (_recognition != null) {
          setState(() => _recognition = null);
          return;
        }
        if (_textInputOpen) {
          _commitText();
        } else {
          await _close();
        }
      } else if (call.method == MethodNames.undoPressed) {
        if (!_textInputOpen && _document.canUndo) _document.undo();
      } else if (call.method == MethodNames.redoPressed) {
        if (!_textInputOpen && _document.canRedo) _document.redo();
      }
    });
    _load();
    _textController.addListener(_fitEditingText);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  void _onDocumentChanged() {
    if (!mounted) return;
    setState(() {});
  }

  void _replace(Map<Object?, Object?> value) {
    if (!mounted) return;
    final firstFrame = Stopwatch()..start();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => unawaited(_perfMark('screenshot-dart-first-frame', firstFrame)),
    );
    _expandedRow = null;
    _childrenRevealed = false;
    _toolbarExpanded = false;
    _toolbarGridShown = false;
    _toolbarShift = Offset.zero;
    _toolbarGlide.value = 1;
    _ghosts = const [];
    _ghostMerge.value = 1;
    _lastToolbarTab = null;
    _liveTranslation = false;
    _toolbarHandleHovered = false;
    _toolbarLifted = false;
    _beautify = null;
    _cropRatio = null;
    unawaited(_syncLivePreview());
    _recordingTarget = CaptureTarget.region;
    _recordingApplication = null;
    _recordingApplications = [];
    _loadingApplications = false;
    _applicationRequest++;
    if (_dialogOpen) {
      Navigator.of(_editorKey.currentContext!).pop();
    }
    _feedbackTimer?.cancel();
    setState(() {
      _sourcePixels = null;
      _pixelLoad = null;
      _ruler = null;
      _picker.value = null;
      _capture = value;
      _toolbar = ScreenshotToolbarPreferences.fromMap(value);
      _confirmAction = ScreenshotConfirmAction.parse(
        value[PreferenceKeys.screenshotConfirmAction] as String?,
      );
      _recordingDelay = value[PreferenceKeys.recordingDelay] as int? ?? 0;
      _recordingClickEffectEnabled =
          value[PreferenceKeys.recordingClickEffectEnabled] as bool? ?? false;
      _readStickers(value);
      _drawing = DrawingPreferences.fromMap(
        value[PreferenceKeys.screenshotDrawing] as Map?,
      );
      _textStyle = _drawing.styles[ScreenshotTool.text]!;
      _fontSize = _drawing.fontSize;
      final error = value['error'] as String?;
      _setFeedback(
        error,
        isError: error != null,
        autoDismiss: value['pixels'] != null,
      );
      _savedPath = null;
      _busy = false;
      _dragStart = null;
      _dragCurrent = null;
      _previewAnnotation = null;
      _setTextInput(false);
      _textController.clear();
      _strokePoints.clear();
      _ocrOverlays = [];
      _recognition = null;
      _tool =
          (value['canCaptureMedia'] != true && value['imageScale'] != null)
          ? ScreenshotTool.cursor
          : ScreenshotTool.crop;
      _selectedTextId = null;
      _selectedShapeId = null;
      _shapeSelecting = false;
      _editingTextId = null;
      _resizeHandle = null;
      _cropSelected = false;
      _previewCrop = null;
      _document.clear();
    });
    unawaited(_loadSource(value));
  }

  Future<void> _loadSource(Map<Object?, Object?> value) async {
    final pixels = value['pixels'] as Uint8List?;
    if (pixels == null) return;
    final width = (value['width'] as num).toInt();
    final height = (value['height'] as num).toInt();
    final watch = Stopwatch()..start();
    final buffer = await ui.ImmutableBuffer.fromUint8List(pixels);
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    final ui.Image image;
    try {
      descriptor = ui.ImageDescriptor.raw(
        buffer,
        width: width,
        height: height,
        rowBytes: value['rowBytes'] as int,
        pixelFormat: ui.PixelFormat.bgra8888,
      );
      codec = await descriptor.instantiateCodec();
      image = (await codec.getNextFrame()).image;
    } catch (error, stack) {
      if (mounted && _capture['id'] == value['id']) {
        setState(
          () => _setFeedback(
            '无法载入这张图片（$width × $height 像素）。',
            isError: true,
            autoDismiss: false,
          ),
        );
      }
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'screenshot',
          context: ErrorDescription('载入截图源图'),
        ),
      );
      return;
    } finally {
      codec?.dispose();
      descriptor?.dispose();
      buffer.dispose();
    }
    unawaited(_perfMark('screenshot-dart-image', watch));
    if (!mounted || _capture['id'] != value['id']) {
      image.dispose();
      return;
    }
    setState(() {
      _document.loadCapture(image);
      final cropW = (value['cropWidth'] as num?)?.toDouble();
      final cropH = (value['cropHeight'] as num?)?.toDouble();
      if (cropW == null || cropH == null || cropW < 1 || cropH < 1) return;
      _document.setCrop(
        Rect.fromLTWH(
          (value['cropX'] as num?)?.toDouble() ?? 0,
          (value['cropY'] as num?)?.toDouble() ?? 0,
          cropW,
          cropH,
        ),
      );
      _cropSelected = !_isOpenedImage && value['cropSelected'] == true;
    });
  }

  Future<void> _perfMark(String stage, Stopwatch watch) =>
      widget.channel.invokeMethod<void>(MethodNames.perfMark, {
        'stage': stage,
        'ms': watch.elapsedMicroseconds / 1000,
      });

  EditAnnotation? get _styleSelection => _document.annotations
      .where((a) => a.id == (_selectedShapeId ?? _selectedTextId))
      .firstOrNull;

  ScreenshotTool get _styleTool {
    final selected = _styleSelection;
    if (selected == null) return _tool;
    return switch (selected.kind) {
      AnnotationKind.rectangle => ScreenshotTool.rect,
      AnnotationKind.arrow => ScreenshotTool.arrow,
      AnnotationKind.stroke => ScreenshotTool.brush,
      AnnotationKind.text => ScreenshotTool.text,
      AnnotationKind.mask => ScreenshotTool.rect,
      AnnotationKind.step => ScreenshotTool.step,
      AnnotationKind.sticker => ScreenshotTool.cursor,
    };
  }

  EditAnnotation? _hitShape(Offset point) {
    final tolerance = 6 * _pixelRatio;
    for (final a in _document.annotations.reversed) {
      if (a.kind == AnnotationKind.text) continue;
      if (!a.bounds.inflate(tolerance + a.strokeWidth / 2).contains(point)) {
        continue;
      }
      if (a.kind == AnnotationKind.mask) return a;
      if (a.kind == AnnotationKind.step) {
        if ((point - a.bounds.center).distance <=
            a.bounds.width / 2 + tolerance) {
          return a;
        }
        continue;
      }
      if (a.kind == AnnotationKind.rectangle) {
        if (a.shape.circular) {
          final distance = (point - a.bounds.center).distance;
          final radius = a.bounds.width / 2;
          if (a.shape.filled
              ? distance <= radius
              : (distance - radius).abs() <= tolerance + a.strokeWidth / 2) {
            return a;
          }
        } else if (a.shape.filled ||
            !a.bounds.deflate(tolerance + a.strokeWidth / 2).contains(point)) {
          return a;
        }
        continue;
      }
      final points = a.kind == AnnotationKind.stroke
          ? a.points
          : [a.start!, a.end!];
      for (var i = 1; i < points.length; i++) {
        final delta = points[i] - points[i - 1];
        final rel = point - points[i - 1];
        final t = delta.distanceSquared == 0
            ? 0.0
            : ((rel.dx * delta.dx + rel.dy * delta.dy) / delta.distanceSquared)
                  .clamp(0.0, 1.0);
        if ((point - (points[i - 1] + delta * t)).distance <=
            tolerance + a.strokeWidth / 2) {
          return a;
        }
      }
    }
    return null;
  }

  Future<void> _editBeautifyBackground() async {
    final captureId = _capture['id'];
    final current = _beautify;
    final preset = DrawingMetrics.gradients.first;
    var shadow = current?.shadow ?? true;
    _dialogOpen = true;
    _setTextInput(true);
    final result = await showDialog<Object>(
      context: _editorKey.currentContext!,
      builder: (dialogContext) => Dialog(
        child: ColorPicker(
          initial:
              current?.background ??
              (color: preset.from, gradient: FillGradient(end: preset.to)),
          onApply: (fill) => Navigator.pop(dialogContext, fill),
          onCancel: () => Navigator.pop(dialogContext),
          footer: StatefulBuilder(
            builder: (context, setLocal) => Row(
              children: [
                Checkbox(
                  key: const Key('beautify-shadow'),
                  value: shadow,
                  onChanged: (value) => setLocal(() => shadow = value!),
                ),
                const Text('阴影'),
                const Spacer(),
                NativeGlassSurface(
                  material: true,
                  child: TextButton(
                    key: const Key('beautify-none'),
                    onPressed: () => Navigator.pop(dialogContext, false),
                    child: const Text('无背景'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    _dialogOpen = false;
    if (!mounted || captureId != _capture['id']) return;
    _setTextInput(false);
    _focusNode.requestFocus();
    if (result == false) {
      setState(() => _beautify = null);
    } else if (result is ColorFill) {
      setState(
        () => _beautify = (current ?? BeautifyStyle(background: result))
            .copyWith(background: result, shadow: shadow),
      );
    }
  }

  Future<void> _editDrawingStyle({required bool color}) async {
    final editingText = _textInputOpen;
    final selected = editingText ? _previewAnnotation : _styleSelection;
    final captureId = _capture['id'];
    final tool = _styleTool;
    final initialFill =
        selected?.style.fill ??
        (tool == ScreenshotTool.rect && _styleShape.filled
            ? _drawing.styleFor(ScreenshotTool.rect).fill
            : tool == ScreenshotTool.text
            ? _textStyle.fill
            : _nextStyle.fill);
    final initialWidth = selected == null
        ? _nextStyle.strokeWidth
        : selected.strokeWidth / _pixelRatio;
    _dialogOpen = true;
    _setTextInput(true);
    final result = await showDialog<Object>(
      context: _editorKey.currentContext!,
      builder: (dialogContext) => Dialog(
        child: color
            ? ColorPicker(
                initial: initialFill,
                onApply: (value) => Navigator.pop(dialogContext, value),
                onCancel: () => Navigator.pop(dialogContext),
              )
            : StrokeWidthPicker(
                initial: initialWidth,
                onApply: (value) => Navigator.pop(dialogContext, value),
                onCancel: () => Navigator.pop(dialogContext),
              ),
      ),
    );
    _dialogOpen = false;
    if (!mounted || captureId != _capture['id']) return;
    _setTextInput(editingText);
    if (editingText) {
      _textFocus.requestFocus();
    } else {
      _focusNode.requestFocus();
    }
    if (result == null) return;
    setState(() {
      if (editingText && result is ColorFill) {
        _textStyle = _textStyle.copyWith(fill: result);
        _previewAnnotation = _previewAnnotation?.copyWith(
          style: _previewAnnotation!.style.copyWith(fill: result),
        );
        if (_editingTextId == null) {
          _drawing = _drawing.copyWith(
            tool: ScreenshotTool.text,
            style: _drawing.styles[ScreenshotTool.text]!.copyWith(fill: result),
          );
        }
      } else if (selected != null) {
        final current = _document.annotations
            .where((a) => a.id == selected.id)
            .firstOrNull;
        if (current == null) return;
        final style = current.style.copyWith(
          fill: result is ColorFill ? result : null,
          strokeWidth: result is double ? result * _pixelRatio : null,
        );
        if (style.color != current.color ||
            style.gradient != current.style.gradient ||
            style.strokeWidth != current.strokeWidth) {
          _document.updateAnnotation(current.copyWith(style: style));
        }
      } else if (result is ColorFill) {
        if (tool == ScreenshotTool.rect && _styleShape.filled) {
          _drawing = _drawing.copyWith(
            tool: ScreenshotTool.rect,
            style: _drawing
                .styleFor(ScreenshotTool.rect)
                .copyWith(fill: result),
          );
        } else {
          _nextStyle = _nextStyle.copyWith(fill: result);
          if (tool == ScreenshotTool.text) {
            _textStyle = _textStyle.copyWith(fill: result);
          }
        }
      } else if (result is double) {
        _nextStyle = _nextStyle.copyWith(strokeWidth: result);
      }
    });
    if ((selected == null || editingText) && _editingTextId == null) {
      _persistDrawing();
    }
  }

  void _chooseShape(ShapeVariant value) {
    final selected = _styleSelection;
    if (selected?.kind == AnnotationKind.rectangle) {
      final bounds = value.circular
          ? _circleBounds(selected!.bounds)
          : selected!.bounds;
      _document.updateAnnotation(
        selected.copyWith(shape: value, bounds: bounds),
      );
    } else {
      setState(() => _drawing = _drawing.copyWith(shape: value));
      _persistDrawing();
    }
  }

  void _chooseBrush(ShapeMode value) {
    final selected = _styleSelection;
    if (selected?.kind == AnnotationKind.stroke) {
      _document.updateAnnotation(selected!.copyWith(shapeMode: value));
    } else {
      setState(() => _drawing = _drawing.copyWith(brushMode: value));
      _persistDrawing();
    }
  }

  Rect _circleBounds(Rect bounds) => Rect.fromLTWH(
    bounds.left,
    bounds.top,
    math.min(bounds.width, bounds.height),
    math.min(bounds.width, bounds.height),
  );

  void _persistDrawing() {
    final snapshot = _drawing.toMap();
    _drawingSave = _drawingSave.then((_) async {
      try {
        await widget.channel.invokeMethod(
          MethodNames.saveDrawingPreferences,
          snapshot,
        );
      } on PlatformException catch (error) {
        if (mounted) {
          setState(() => _setFeedback(error.message, isError: true));
        }
      }
    });
  }

  Future<void> _load() async {
    try {
      final snapshot = (await widget.channel.invokeMapMethod(
        MethodNames.getScreenshot,
      ))!;
      if (_capture.isEmpty) _replace(snapshot);
    } on PlatformException catch (error) {
      if (mounted) {
        setState(
          () => _setFeedback(
            error.message,
            isError: true,
            autoDismiss: _document.hasImage,
          ),
        );
      }
    }
  }

  Future<void> _syncLivePreview() async {
    final id = _capture['id'];
    try {
      await widget.channel.invokeMethod<void>(
        _liveExpanded
            ? MethodNames.previewLiveRegion
            : MethodNames.cancelLivePreview,
        {'id': id},
      );
    } on PlatformException catch (error) {
      if (mounted && _capture['id'] == id && _liveExpanded) {
        setState(() => _setFeedback(error.message, isError: true));
      }
    }
  }

  Future<void> _syncRecordingPreview() async {
    final id = _capture['id'];
    try {
      await widget.channel.invokeMethod<void>(
        MethodNames.previewCaptureTarget,
        {
          'id': id,
          'kind':
              (_recordingExpanded
                      ? _recordingTarget
                      : CaptureTarget.region)
                  .name,
          'applicationID': _recordingApplication?['applicationID'],
        },
      );
    } on PlatformException catch (error) {
      if (mounted && _capture['id'] == id) {
        setState(() => _setFeedback(error.message, isError: true));
      }
    }
  }

  List<Rect>? get _recordingWindows {
    if (!_recordingExpanded ||
        _recordingTarget != CaptureTarget.application ||
        _recordingApplication == null) {
      return null;
    }
    final scale =
        (_capture['width'] as num) /
        ((_capture['displayWidth'] as num?) ?? (_capture['width'] as num));
    return ((_recordingApplication!['windows'] as List?) ?? []).map((item) {
      final rect = item as Map;
      return Rect.fromLTWH(
        ((rect['x'] as num) - ((_capture['captureDisplayX'] as num?) ?? 0)) *
            scale,
        ((rect['y'] as num) - ((_capture['captureDisplayY'] as num?) ?? 0)) *
            scale,
        (rect['width'] as num) * scale,
        (rect['height'] as num) * scale,
      );
    }).toList();
  }

  Future<void> _selectRecordingTarget(CaptureTarget target) async {
    final id = _capture['id'];
    final request = ++_applicationRequest;
    setState(() {
      _recordingTarget = target;
      _recordingApplication = null;
      _recordingApplications = [];
      _loadingApplications = target == CaptureTarget.application;
      _setFeedback(null);
    });
    await _syncRecordingPreview();
    if (target != CaptureTarget.application) return;
    try {
      final sources = await widget.channel.invokeListMethod<Object?>(
        MethodNames.captureSources,
        {'id': id},
      );
      if (!mounted ||
          _capture['id'] != id ||
          _recordingTarget != target ||
          request != _applicationRequest) {
        return;
      }
      setState(() {
        _recordingApplications = sources!
            .cast<Map>()
            .map(Map<Object?, Object?>.from)
            .toList();
        if (_recordingApplications.isEmpty) {
          _setFeedback('没有可录制的应用。', isError: true);
        }
      });
    } on PlatformException catch (error) {
      if (mounted &&
          _capture['id'] == id &&
          _recordingTarget == target &&
          request == _applicationRequest) {
        setState(() => _setFeedback(error.message, isError: true));
      }
    } finally {
      if (mounted &&
          _capture['id'] == id &&
          _recordingTarget == target &&
          request == _applicationRequest) {
        setState(() => _loadingApplications = false);
      }
    }
  }

  Future<void> _prepareCapture(
    CaptureTarget kind, {
    bool scrolling = false,
    bool live = false,
  }) async {
    if (_busy || _capture['canCaptureMedia'] != true) return;
    final id = _capture['id'];
    setState(() {
      _busy = true;
      _busyId = scrolling
          ? ScreenshotActions.scrolling
          : ScreenshotActions.record;
    });
    try {
      await widget.channel.invokeMethod<void>(MethodNames.prepareCapture, {
        'id': id,
        'kind': kind.name,
        'scrolling': scrolling,
        'live': live,
        if (!scrolling && !live) 'delay': _recordingDelay,
        if (kind == CaptureTarget.application)
          'applicationID': _recordingApplication!['applicationID'],
        if (kind == CaptureTarget.region) ...{
          'x': _document.cropRect.left.floorToDouble(),
          'y': _document.cropRect.top.floorToDouble(),
          'width': _document.cropRect.width.floorToDouble(),
          'height': _document.cropRect.height.floorToDouble(),
        },
      });
      if (!mounted || _capture['id'] != id) return;
      setState(() => _setFeedback(null));
    } on PlatformException catch (error) {
      if (mounted && _capture['id'] == id) {
        setState(() => _setFeedback(error.message, isError: true));
      }
    } finally {
      if (mounted && _capture['id'] == id) setState(() => _busy = false);
    }
  }

  Future<void> _saveRecordingOptions({
    required int delay,
    required bool clickEffectEnabled,
  }) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _busyId = null;
    });
    try {
      await widget.channel.invokeMethod<void>(
        MethodNames.saveRecordingOptions,
        {
          PreferenceKeys.recordingDelay: delay,
          PreferenceKeys.recordingClickEffectEnabled: clickEffectEnabled,
        },
      );
      if (!mounted) return;
      setState(() {
        _recordingDelay = delay;
        _recordingClickEffectEnabled = clickEffectEnabled;
      });
    } on PlatformException catch (error) {
      if (mounted) {
        setState(() => _setFeedback(error.message, isError: true));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showCopyFeedback(String message) {
    setState(() => _setFeedback(message));
  }

  Future<void> _confirmScreenshot() async {
    if (_dialogOpen) return;
    if (_busy) return;
    if (_recordingExpanded) {
      if (_recordingTarget == CaptureTarget.application &&
          _recordingApplication == null) {
        return;
      }
      await _prepareCapture(_recordingTarget, live: _liveExpanded);
      return;
    }
    if (_textInputOpen) {
      _commitText();
      return;
    }
    switch (_confirmAction) {
      case ScreenshotConfirmAction.copy:
        await _export('copy', closeAfterCopy: true);
      case ScreenshotConfirmAction.copyAndSave:
        await _export('copySave', closeAfterCopy: true);
    }
  }

  Future<void> _export(String action, {bool closeAfterCopy = false}) async {
    final id = _capture['id'];
    if (id == null || !_document.hasImage || _busy) return;
    setState(() {
      _busy = true;
      _busyId = switch (action) {
        'copy' => ScreenshotActions.copy,
        'save' => ScreenshotActions.save,
        'pin' => ScreenshotActions.pin,
        _ => null,
      };
      _setFeedback(null);
    });
    String? saved;
    try {
      final render = Stopwatch()..start();
      final bytes = await _document.renderPng(
        beautify: action == 'pin' ? null : _beautify,
        unit: _pixelRatio,
      );
      unawaited(_perfMark('export-render-png', render));
      if (!mounted || _capture['id'] != id) return;
      if (action == 'save' || action == 'copySave') {
        saved = await widget.channel.invokeMethod<String>(
          MethodNames.saveScreenshot,
          {
            'id': id,
            'bytes': bytes,
            'copy': action == 'copySave',
            'name': screenshotFilename(
              DateTime.fromMillisecondsSinceEpoch(
                _capture['capturedAt'] as int,
              ),
            ),
          },
        );
        if (saved == null) return;
        if (!mounted || _capture['id'] != id) return;
        setState(() {
          _savedPath = saved;
          _setFeedback('已保存截图');
        });
        if (action == 'save') return;
      }
      if (action == 'pin') {
        final origin = pinOriginAppKit(
          crop: _document.cropRect,
          display: Rect.fromLTWH(
            (_capture['displayX'] as num).toDouble(),
            (_capture['displayY'] as num).toDouble(),
            (_capture['displayWidth'] as num).toDouble(),
            (_capture['displayHeight'] as num).toDouble(),
          ),
          image: _document.imageSize,
        );
        final pinId = await widget.channel.invokeMethod<String>(
          MethodNames.pinScreenshot,
          {'id': id, 'bytes': bytes, 'x': origin.dx, 'y': origin.dy},
        );
        if (!mounted || _capture['id'] != id) return;
        if (pinId == null) {
          setState(() => _setFeedback('贴图失败', isError: true));
          return;
        }
        await widget.channel.invokeMethod<void>(MethodNames.closeScreenshot);
        return;
      }
      if (action == 'copy') {
        await widget.channel.invokeMethod<void>(MethodNames.copyScreenshot, {
          'id': id,
          'bytes': bytes,
        });
        if (!mounted || _capture['id'] != id) return;
      }
      _showCopyFeedback('已复制图片');
      if (closeAfterCopy) {
        await widget.channel.invokeMethod<void>(MethodNames.closeScreenshot);
      }
    } on PlatformException catch (error) {
      if (!mounted || _capture['id'] != id) return;
      setState(() {
        _savedPath = saved ?? _savedPath;
        _setFeedback(error.message, isError: true);
      });
    } finally {
      if (mounted && _capture['id'] == id) setState(() => _busy = false);
    }
  }

  Future<void> _sourcePixelsReady() {
    final image = _document.source;
    if (image == null) return Future.value();
    return _pixelLoad ??= image
        .toByteData(format: ui.ImageByteFormat.rawStraightRgba)
        .then((data) {
          if (mounted && image == _document.source) {
            setState(() => _sourcePixels = data);
          }
        });
  }

  Color? _colorAt(Offset point) {
    final pixels = _sourcePixels;
    if (pixels == null) return null;
    final x = point.dx.floor().clamp(0, _document.width - 1);
    final y = point.dy.floor().clamp(0, _document.height - 1);
    final offset = (y * _document.width + x) * 4;
    return Color.fromARGB(
      255,
      pixels.getUint8(offset),
      pixels.getUint8(offset + 1),
      pixels.getUint8(offset + 2),
    );
  }

  void _hoverPicker(Offset? point) {
    if (point == _picker.value) return;
    _picker.value = point;
    if (point != null) unawaited(_sourcePixelsReady());
  }

  Future<void> _pickColor(Offset point) async {
    _picker.value = point;
    await _sourcePixelsReady();
    final color = _colorAt(point);
    if (!mounted || color == null) return;
    final hex = colorHex(color);
    await widget.channel.invokeMethod<void>(MethodNames.copyText, {
      'text': hex,
    });
    if (mounted) _showCopyFeedback('已复制 $hex');
  }

  Future<void> _command(String method) async {
    setState(() {
      _busy = true;
      _busyId = null;
      _setFeedback(null);
    });
    try {
      final value = await widget.channel.invokeMethod<Object?>(method);
      if (!mounted) return;
      if (method == MethodNames.requestScreenAccess && value is Map) {
        setState(() => _capture['screenAccess'] = value['screenAccess']);
      }
    } on PlatformException catch (error) {
      if (mounted) {
        setState(
          () => _setFeedback(
            error.message,
            isError: true,
            autoDismiss: _document.hasImage,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showRecognizedText() async {
    final id = _capture['id'];
    final recognition = await _recognizeOcr();
    if (!mounted || _capture['id'] != id || recognition == null) return;
    if (recognition.text.trim().isEmpty && recognition.codes.isEmpty) {
      setState(() => _setFeedback('画面中没有可识别的文字、二维码或条码', isError: true));
      return;
    }
    setState(() {
      _recognition = recognition;
      _recognizedOffset.value = Offset.zero;
    });
  }

  Future<void> _copyRecognized(String text, String feedback) async {
    final id = _capture['id'];
    try {
      await widget.channel.invokeMethod<void>(MethodNames.copyText, {
        'text': text,
      });
      if (mounted && _capture['id'] == id) _showCopyFeedback(feedback);
    } on PlatformException catch (error) {
      if (mounted && _capture['id'] == id) {
        setState(() => _setFeedback(error.message, isError: true));
      }
    }
  }

  Future<void> _openLink(String url) async {
    final id = _capture['id'];
    try {
      final opened = await widget.channel.invokeMethod<bool>(
        MethodNames.openLink,
        {'id': id, 'url': url},
      );
      if (!mounted || _capture['id'] != id) return;
      if (opened == true) {
        await _close();
        return;
      }
      setState(() => _setFeedback('无法打开链接', isError: true));
    } on PlatformException catch (error) {
      if (mounted && _capture['id'] == id) {
        setState(() => _setFeedback(error.message, isError: true));
      }
    }
  }

  Future<void> _translateOcr() async {
    final id = _capture['id'];
    if (id == null || !_document.hasImage || _busy) return;
    setState(() {
      _busy = true;
      _busyId = ScreenshotActions.ocrTranslate;
      _setFeedback(null);
    });
    unawaited(
      widget.channel.invokeMethod<void>(MethodNames.prewarmTranslation),
    );
    try {
      final origin = _document.cropRect.topLeft;
      final bytes = await _document.renderPng();
      final blocks = await widget.channel.invokeListMethod<Object?>(
        MethodNames.recognizeBlocks,
        {'id': id, 'bytes': bytes},
      );
      if (!mounted || _capture['id'] != id) return;
      if (blocks!.isEmpty) {
        setState(() {
          _ocrOverlays = [];
          _setFeedback('画面中没有可识别的文字', isError: true);
        });
        return;
      }
      setState(() {
        _ocrOverlays = [];
        _translationOrigin = origin;
      });
      await widget.channel.invokeMethod<void>(
        MethodNames.translateScreenshotBlocks,
        {'id': id, 'blocks': blocks},
      );
    } on PlatformException catch (error) {
      if (mounted && _capture['id'] == id) {
        setState(() => _setFeedback(error.message, isError: true));
      }
    } finally {
      if (mounted && _capture['id'] == id) setState(() => _busy = false);
    }
  }

  Future<({String text, List<RecognizedCode> codes})?> _recognizeOcr() async {
    final id = _capture['id'];
    if (id == null || !_document.hasImage || _busy) return null;
    setState(() {
      _busy = true;
      _busyId = ScreenshotActions.ocrCopy;
      _setFeedback(null);
    });
    try {
      final bytes = await _document.renderPng();
      final result = (await widget.channel.invokeMapMethod<String, Object?>(
        MethodNames.recognizeText,
        {'id': id, 'bytes': bytes},
      ))!;
      return (
        text: result['text'] as String,
        codes: [
          for (final code in result['codes'] as List)
            (
              symbology: (code as Map)['symbology'] as String,
              payload: code['payload'] as String,
            ),
        ],
      );
    } on PlatformException catch (error) {
      if (mounted) {
        setState(() => _setFeedback(error.message, isError: true));
      }
      return null;
    } finally {
      if (mounted && _capture['id'] == id) setState(() => _busy = false);
    }
  }

  Future<void> _close() => _command(MethodNames.closeScreenshot);

  void _onDragStart(Offset imagePoint) {
    if (_textInputOpen) {
      _commitText();
      return;
    }
    if (_tool == ScreenshotTool.cursor && !_busy) {
      final sticker = _stickerHandleAt(imagePoint);
      if (sticker != null) {
        setState(() {
          _selectedShapeId = sticker.annotation.id;
          _selectedTextId = null;
          _cropSelected = false;
          _stickerDrag = (
            handle: sticker.handle,
            start: BoxFrame(
              sticker.annotation.bounds,
              sticker.annotation.rotation,
            ),
          );
          _dragStart = imagePoint;
          _dragCurrent = imagePoint;
          _previewAnnotation = sticker.annotation;
        });
        return;
      }
    }
    if (_tool == ScreenshotTool.cursor &&
        !_busy &&
        !_textInputOpen &&
        _hitText(imagePoint) == null) {
      final shape = _hitShape(imagePoint);
      if (shape != null) {
        setState(() {
          _selectedShapeId = shape.id;
          _selectedTextId = null;
          _cropSelected = false;
          _shapeSelecting = true;
        });
        return;
      }
    }
    _selectedShapeId = null;

    if (!_document.hasImage || _busy || _textInputOpen) return;
    if (_tool == ScreenshotTool.ruler) {
      setState(() => _ruler = (start: imagePoint, end: imagePoint));
      return;
    }
    if (_tool == ScreenshotTool.eyedropper) return;
    if ((_tool == ScreenshotTool.text || _tool == ScreenshotTool.cursor) &&
        _startTextGesture(imagePoint)) {
      return;
    }
    if (_tool == ScreenshotTool.crop || _tool == ScreenshotTool.cursor) {
      if (_cropSelected || _tool == ScreenshotTool.cursor) {
        final handle = _handleAt(_document.cropRect, imagePoint);
        if (handle != null) {
          setState(() {
            _resizeHandle = handle;
            _dragStart = imagePoint;
            _dragCurrent = imagePoint;
            _previewCrop = _document.cropRect;
            _cropSelected = true;
            _selectedTextId = null;
          });
          return;
        }
      }
      if (_tool == ScreenshotTool.cursor) {
        setState(() => _cropSelected = false);
        return;
      }
      setState(() {
        _cropSelected = false;
        _resizeHandle = null;
        _dragStart = imagePoint;
        _dragCurrent = imagePoint;
        _previewCrop = Rect.fromPoints(imagePoint, imagePoint);
        _selectedTextId = null;
      });
      return;
    }
    setState(() {
      _selectedTextId = null;
      _previewCrop = null;
      _dragStart = imagePoint;
      _dragCurrent = imagePoint;
      _strokePoints
        ..clear()
        ..add(imagePoint);
      _strokeBounds = Rect.fromPoints(imagePoint, imagePoint);
      _previewAnnotation = _draftAnnotation(imagePoint, imagePoint);
    });
  }

  void _onDragUpdate(Offset imagePoint) {
    if (_tool == ScreenshotTool.ruler && _ruler != null) {
      setState(() => _ruler = (start: _ruler!.start, end: imagePoint));
      return;
    }
    if (_shapeSelecting) return;
    if (_dragStart == null || _textInputOpen) return;
    setState(() {
      _dragCurrent = imagePoint;
      final stickerDrag = _stickerDrag;
      if (stickerDrag != null) {
        final shift = HardwareKeyboard.instance.isShiftPressed;
        final frame = dragBox(
          stickerDrag.start,
          stickerDrag.handle,
          from: _dragStart!,
          to: imagePoint,
          rules: BoxRules(
            area: _stickerArea,
            minSide: CropMetrics.minSide,
            keepRatio: shift,
            snapRotation: shift,
          ),
        );
        _previewAnnotation = _previewAnnotation!.copyWith(
          bounds: frame.rect,
          rotation: frame.rotation,
        );
        return;
      }
      if (_previewCrop != null) {
        if (_resizeHandle != null) {
          _previewCrop = dragBox(
            BoxFrame(_document.cropRect),
            _resizeHandle!,
            from: _dragStart!,
            to: imagePoint,
            rules: BoxRules(
              area: _imageArea,
              minSide: CropMetrics.minSide,
              ratio: _cropRatio,
            ),
          ).rect;
        } else if (_dragStart != null) {
          _previewCrop = _newSelection(_dragStart!, imagePoint);
        }
        return;
      }
      if (_resizeHandle != null && _selectedTextId != null) {
        final current = _document.annotations
            .where((item) => item.id == _selectedTextId)
            .firstOrNull;
        if (current != null) {
          _previewAnnotation = current.copyWith(
            bounds: _fittedTextBounds(
              current,
              dragBox(
                BoxFrame(current.bounds),
                _resizeHandle!,
                from: _dragStart!,
                to: imagePoint,
                rules: BoxRules(area: _imageArea, minSide: CropMetrics.minSide),
              ).rect,
              moved: _resizeHandle == BoxHandle.move,
            ),
          );
        }
        return;
      }
      if (_tool == ScreenshotTool.brush) {
        _strokePoints.add(imagePoint);
        _strokeBounds = _strokeBounds.expandToInclude(
          Rect.fromPoints(imagePoint, imagePoint),
        );
      }
      _previewAnnotation = _draftAnnotation(_dragStart!, imagePoint);
    });
  }

  void _onDragEnd() {
    if (_stickerDrag != null) {
      final preview = _previewAnnotation;
      setState(() {
        _stickerDrag = null;
        _dragStart = null;
        _dragCurrent = null;
        _previewAnnotation = null;
      });
      if (preview != null) _document.updateAnnotation(preview);
      return;
    }
    if (_shapeSelecting) {
      _shapeSelecting = false;
      return;
    }
    if (_dragStart == null) return;
    final start = _dragStart!;
    final end = _dragCurrent ?? start;
    final preview = _previewAnnotation;
    final handle = _resizeHandle;
    final selectedId = _selectedTextId;
    final cropPreview = _previewCrop;
    if (cropPreview != null) {
      Rect? next = handle != null ? cropPreview : null;
      if (next == null) {
        final rect = _newSelection(start, end);
        final minSide = 8 * _pixelRatio;
        if (rect.width >= minSide && rect.height >= minSide) {
          next = rect;
        }
      }
      setState(() {
        _dragStart = null;
        _dragCurrent = null;
        _previewAnnotation = null;
        _previewCrop = null;
        _resizeHandle = null;
        if (next != null) _cropSelected = true;
      });
      if (next != null) _document.setCrop(next);
      return;
    }
    setState(() {
      _dragStart = null;
      _dragCurrent = null;
      _previewAnnotation = null;
      _previewCrop = null;
      _resizeHandle = null;
    });
    if (handle != null && selectedId != null && preview != null) {
      final current = _document.annotations
          .where((item) => item.id == selectedId)
          .firstOrNull;
      if (current != null) {
        _document.updateAnnotation(current.copyWith(bounds: preview.bounds));
      }
      return;
    }
    if (_tool == ScreenshotTool.cursor) {
      return;
    }
    if (_tool == ScreenshotTool.text) {
      final rect = Rect.fromPoints(start, end);
      if (rect.width < ScreenshotDefaults.textBoxMinWidth * _pixelRatio) {
        _openTextInput(start);
      } else {
        _openTextInput(rect.topLeft, width: rect.width);
      }
      return;
    }
    if (_tool == ScreenshotTool.brush) {
      if (_strokePoints.length >= 2) {
        _document.addAnnotation(
          EditAnnotation(
            id: '',
            kind: AnnotationKind.stroke,
            shapeMode: _shapeMode,
            style: _nextStyle.copyWith(
              strokeWidth: _nextStyle.strokeWidth * _pixelRatio,
            ),
            bounds: boundsForPoints(_strokePoints),
            points: List<Offset>.from(_strokePoints),
          ),
        );
      }
      _strokePoints.clear();
      return;
    }
    if (preview == null) return;
    if (preview.kind != AnnotationKind.arrow &&
        (preview.bounds.width < 1 || preview.bounds.height < 1)) {
      return;
    }
    _document.addAnnotation(
      EditAnnotation(
        id: '',
        kind: preview.kind,
        shapeMode: preview.shapeMode,
        shape: preview.shape,
        style: preview.style,
        bounds: preview.bounds,
        start: preview.start,
        end: preview.end,
        text: preview.text,
        color: preview.color,
        strokeWidth: preview.strokeWidth,
        fontSize: preview.fontSize,
      ),
    );
  }

  bool _startTextGesture(Offset imagePoint) {
    final selected = _document.annotations
        .where((item) => item.id == _selectedTextId)
        .firstOrNull;
    if (selected != null) {
      final handle = _handleAt(selected.bounds, imagePoint)?.widthOnly;
      if (handle != null && handle != BoxHandle.move) {
        setState(() {
          _cropSelected = false;
          _resizeHandle = handle;
          _dragStart = imagePoint;
          _dragCurrent = imagePoint;
          _previewAnnotation = selected;
        });
        return true;
      }
    }
    final hit = _hitText(imagePoint);
    if (hit != null) {
      setState(() {
        _cropSelected = false;
        _selectedTextId = hit.id;
        _resizeHandle =
            _handleAt(hit.bounds, imagePoint)?.widthOnly ?? BoxHandle.move;
        _dragStart = imagePoint;
        _dragCurrent = imagePoint;
        _previewAnnotation = hit;
      });
      return true;
    }
    if (_tool == ScreenshotTool.cursor) {
      setState(() => _selectedTextId = null);
      return false;
    }
    setState(() {
      _selectedTextId = null;
      _cropSelected = false;
      _dragStart = imagePoint;
      _dragCurrent = imagePoint;
      _previewAnnotation = EditAnnotation(
        id: 'preview',
        kind: AnnotationKind.text,
        bounds: Rect.fromPoints(imagePoint, imagePoint),
        style: _textStyle,
        fontSize: _toImageFont(_fontSize),
      );
    });
    return true;
  }

  void _openExistingText(EditAnnotation annotation) {
    setState(() {
      _selectedTextId = annotation.id;
      _cropSelected = false;
      _editingTextId = annotation.id;
      _setTextInput(true);
      _textController.text = annotation.text;
      _textStyle = annotation.style;
      _fontSize = _nearestVisualFont(_toVisualFont(annotation.fontSize));
      _dragStart = annotation.bounds.topLeft;
      _previewAnnotation = annotation;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _textFocus.requestFocus();
    });
  }

  EditAnnotation? _hitText(Offset point) {
    for (final annotation in _document.annotations.reversed) {
      if (annotation.kind == AnnotationKind.text &&
          annotation.bounds.inflate(4).contains(point)) {
        return annotation;
      }
    }
    return null;
  }

  void _readStickers(Map<Object?, Object?> value) {
    _stickers = [
      for (final entry in value[PreferenceKeys.stickers] as List? ?? [])
        StickerEntry.fromMap(entry as Map),
    ];
    _stickerDirectory = value[PreferenceKeys.stickerDirectory] as String?;
  }

  void _deleteSelection() {
    final id = _selectedShapeId;
    if (id == null) return;
    setState(() => _selectedShapeId = null);
    _document.removeAnnotation(id);
  }

  Rect get _stickerArea => switch (_beautify) {
    final beautify? => _document.cropRect.inflate(
      beautify.padding * _pixelRatio,
    ),
    null => _imageArea,
  };

  ({EditAnnotation annotation, BoxHandle handle})? _stickerHandleAt(
    Offset point,
  ) {
    final selected = _styleSelection;
    if (selected != null && selected.kind == AnnotationKind.sticker) {
      final handle = hitBoxHandle(
        BoxFrame(selected.bounds, selected.rotation),
        point,
        pad: GlassMetrics.cropHandleHitRadius * _pixelRatio,
        edgePad: GlassMetrics.cropEdgeHitRadius * _pixelRatio,
        rotateDistance: StickerMetrics.rotateDistance * _pixelRatio,
      );
      if (handle != null) return (annotation: selected, handle: handle);
    }
    for (final annotation in _document.annotations.reversed) {
      if (annotation.kind != AnnotationKind.sticker) continue;
      final hit = hitBoxHandle(
        BoxFrame(annotation.bounds, annotation.rotation),
        point,
        pad: 0,
      );
      if (hit != null) return (annotation: annotation, handle: BoxHandle.move);
    }
    return null;
  }

  Future<void> _openStickerPanel() async {
    final captureId = _capture['id'];
    final anchorBox = _stickerAnchor.currentContext?.findRenderObject();
    final anchor = anchorBox is RenderBox && anchorBox.attached
        ? anchorBox.localToGlobal(Offset.zero) & anchorBox.size
        : null;
    _dialogOpen = true;
    final choice = await showDialog<StickerChoice>(
      context: _editorKey.currentContext!,
      barrierColor: Colors.transparent,
      useSafeArea: false,
      builder: (_) => CustomSingleChildLayout(
        delegate: StickerPanelLayout(anchor),
        child: StickerPanel(stickers: _stickers, directory: _stickerDirectory!),
      ),
    );
    _dialogOpen = false;
    if (!mounted || captureId != _capture['id']) return;
    switch (choice) {
      case PickedSticker(:final entry):
        await _placeSticker(
          Size(entry.width, entry.height),
          stickerId: entry.id,
        );
      case PickedEmoji(:final emoji):
        await _placeSticker(
          const Size.square(StickerMetrics.emojiDefaultSize),
          text: emoji,
        );
      case ManageStickers():
        unawaited(
          widget.channel.invokeMethod<void>(MethodNames.openStickerSettings),
        );
      case null:
        break;
    }
  }

  Future<void> _placeSticker(
    Size size, {
    String? stickerId,
    String text = '',
  }) async {
    final id = stickerId;
    if (id != null && !_document.stickerImages.containsKey(id)) {
      final bytes = await File('$_stickerDirectory/$id.png').readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      codec.dispose();
      _document.stickerImages[id] = frame.image;
    }
    if (!mounted) return;
    final crop = _document.cropRect;
    final width = size.width * _pixelRatio;
    final height = size.height * _pixelRatio;
    final fit = math.min(
      1.0,
      math.min(crop.width / width, crop.height / height),
    );
    final annotationId = _document.addAnnotation(
      EditAnnotation(
        id: '',
        kind: AnnotationKind.sticker,
        bounds: Rect.fromCenter(
          center: crop.center,
          width: width * fit,
          height: height * fit,
        ),
        stickerId: id,
        text: text,
      ),
    );
    setState(() {
      _tool = ScreenshotTool.cursor;
      _selectedShapeId = annotationId;
      _selectedTextId = null;
      _cropSelected = false;
    });
  }

  BoxHandle? _handleAt(Rect bounds, Offset point) => hitBoxHandle(
    BoxFrame(bounds),
    point,
    pad: GlassMetrics.cropHandleHitRadius * _pixelRatio,
    edgePad: GlassMetrics.cropEdgeHitRadius * _pixelRatio,
  );

  Rect get _imageArea => Rect.fromLTWH(
    0,
    0,
    _document.width.toDouble(),
    _document.height.toDouble(),
  );

  Rect _newSelection(Offset start, Offset end) => _cropRatio == null
      ? Rect.fromPoints(start, end)
      : ratioRect(
          anchor: start,
          toward: end,
          ratio: _cropRatio!,
          byHeight: false,
          bounds: Size(_document.width.toDouble(), _document.height.toDouble()),
          minSide: 0,
        );

  void _chooseRatio(double? ratio) {
    setState(() {
      _cropRatio = ratio;
      if (ratio != null) _cropSelected = true;
    });
    if (ratio == null) return;
    final crop = _document.cropRect;
    _document.setCrop(
      ratioRect(
        anchor: crop.topLeft,
        toward: crop.bottomRight,
        ratio: ratio,
        byHeight: false,
        bounds: Size(_document.width.toDouble(), _document.height.toDouble()),
        minSide: CropMetrics.minSide,
      ),
    );
  }

  bool _nudgeCrop(
    Offset direction, {
    required bool large,
    required bool resize,
  }) {
    if (!_document.hasImage ||
        _busy ||
        (_tool != ScreenshotTool.crop && _tool != ScreenshotTool.cursor) ||
        _selectedShapeId != null ||
        _selectedTextId != null) {
      return false;
    }
    final step =
        direction *
        (large ? CropMetrics.nudgeLargeStep : CropMetrics.nudgeStep);
    final crop = _document.cropRect;
    final bounds = Size(
      _document.width.toDouble(),
      _document.height.toDouble(),
    );
    final Rect next;
    if (!resize) {
      next = Rect.fromLTWH(
        (crop.left + step.dx).clamp(0, bounds.width - crop.width).toDouble(),
        (crop.top + step.dy).clamp(0, bounds.height - crop.height).toDouble(),
        crop.width,
        crop.height,
      );
    } else if (_cropRatio == null) {
      next = Rect.fromLTRB(
        crop.left,
        crop.top,
        (crop.right + step.dx)
            .clamp(crop.left + CropMetrics.minSide, bounds.width)
            .toDouble(),
        (crop.bottom + step.dy)
            .clamp(crop.top + CropMetrics.minSide, bounds.height)
            .toDouble(),
      );
    } else {
      next = ratioRect(
        anchor: crop.topLeft,
        toward: crop.bottomRight + step,
        ratio: _cropRatio!,
        byHeight: step.dy != 0,
        bounds: bounds,
        minSide: CropMetrics.minSide,
      );
    }
    setState(() => _cropSelected = true);
    _document.setCrop(next);
    return true;
  }

  EditAnnotation? _draftAnnotation(Offset start, Offset end) {
    final bounds = Rect.fromPoints(start, end);
    switch (_tool) {
      case ScreenshotTool.cursor:
      case ScreenshotTool.crop:
      case ScreenshotTool.eyedropper:
      case ScreenshotTool.ruler:
        return null;
      case ScreenshotTool.text:
        return EditAnnotation(
          id: 'preview',
          kind: AnnotationKind.text,
          bounds: bounds,
          style: _textStyle,
          fontSize: _toImageFont(_fontSize),
        );
      case ScreenshotTool.brush:
        return EditAnnotation(
          id: 'preview',
          kind: AnnotationKind.stroke,
          shapeMode: _shapeMode,
          style: _nextStyle.copyWith(
            strokeWidth: _nextStyle.strokeWidth * _pixelRatio,
          ),
          bounds: _strokePoints.isEmpty
              ? boundsForPoints([start, end])
              : _strokeBounds,
          points: _strokePoints.isEmpty
              ? [start, end]
              : UnmodifiableListView(_strokePoints),
        );
      case ScreenshotTool.rect:
        return EditAnnotation(
          id: 'preview',
          kind: AnnotationKind.rectangle,
          shape: _drawing.shape,
          style: _nextStyle.copyWith(
            strokeWidth: _nextStyle.strokeWidth * _pixelRatio,
          ),
          bounds: _drawing.shape.circular ? _circleBounds(bounds) : bounds,
        );
      case ScreenshotTool.step:
        return EditAnnotation(
          id: 'preview',
          kind: AnnotationKind.step,
          style: _nextStyle,
          bounds: Rect.fromCircle(
            center: end,
            radius: DrawingMetrics.stepDiameter * _pixelRatio / 2,
          ),
        );
      case ScreenshotTool.arrow:
        return EditAnnotation(
          id: 'preview',
          kind: AnnotationKind.arrow,
          style: _nextStyle.copyWith(
            strokeWidth: _nextStyle.strokeWidth * _pixelRatio,
          ),
          bounds: bounds,
          start: start,
          end: end,
        );
    }
  }

  void _openTextInput(Offset point, {double? width}) {
    _textStyle = _drawing.styles[ScreenshotTool.text]!;
    _fontSize = _drawing.fontSize;
    final box = _newTextBox(point, width: width);
    setState(() {
      _setTextInput(true);
      _cropSelected = false;
      _selectedTextId = null;
      _selectedShapeId = null;
      _shapeSelecting = false;
      _editingTextId = null;
      _textController.text = '';
      _dragStart = box.topLeft;
      _previewAnnotation = EditAnnotation(
        id: 'preview',
        kind: AnnotationKind.text,
        bounds: box,
        style: _textStyle,
        fontSize: _toImageFont(_fontSize),
      );
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _textFocus.requestFocus();
    });
  }

  void _commitText() {
    if (!_textController.value.composing.isCollapsed &&
        _textController.value.composing.isValid) {
      return;
    }
    final preview = _previewAnnotation;
    final text = _textController.text.trim();
    final editingId = _editingTextId;
    setState(() {
      _setTextInput(false);
      _dragStart = null;
      _dragCurrent = null;
      _previewAnnotation = null;
      _editingTextId = null;
    });
    if (preview == null) return;
    if (text.isEmpty) {
      if (editingId != null) _document.removeAnnotation(editingId);
      setState(() => _selectedTextId = null);
      return;
    }
    final fontSize = _toImageFont(_fontSize);
    final bounds = Rect.fromLTWH(
      preview.bounds.left,
      preview.bounds.top,
      preview.bounds.width,
      textBoxHeight(
        text: text,
        fontSize: fontSize,
        width: preview.bounds.width,
      ),
    );
    if (editingId != null) {
      final current = _document.annotations
          .where((item) => item.id == editingId)
          .firstOrNull;
      if (current == null) return;
      _document.updateAnnotation(
        current.copyWith(
          text: text,
          bounds: bounds,
          style: _textStyle,
          fontSize: fontSize,
        ),
      );
      setState(() => _selectedTextId = editingId);
      return;
    }
    final id = _document.addAnnotation(
      EditAnnotation(
        id: '',
        kind: AnnotationKind.text,
        bounds: bounds,
        text: text,
        style: _textStyle,
        fontSize: fontSize,
      ),
    );
    setState(() => _selectedTextId = id);
  }

  Rect _newTextBox(Offset point, {double? width}) {
    final image = _document.imageSize;
    final minWidth = ScreenshotDefaults.textBoxMinWidth * _pixelRatio;
    final wanted = width ?? ScreenshotDefaults.textBoxWidth * _pixelRatio;
    final left = point.dx
        .clamp(0, math.max(0, image.width - minWidth))
        .toDouble();
    final boxWidth = wanted
        .clamp(minWidth, math.max(minWidth, image.width - left))
        .toDouble();
    final fontSize = _toImageFont(_fontSize);
    final height = textBoxHeight(text: '', fontSize: fontSize, width: boxWidth);
    final top = point.dy
        .clamp(0, math.max(0, image.height - height))
        .toDouble();
    return Rect.fromLTWH(left, top, boxWidth, height);
  }

  Rect _fittedTextBounds(
    EditAnnotation annotation,
    Rect raw, {
    required bool moved,
  }) {
    if (moved) return raw;
    final minWidth = ScreenshotDefaults.textBoxMinWidth * _pixelRatio;
    final width = math.max(minWidth, raw.width);
    final left = raw.left == annotation.bounds.left
        ? raw.left
        : annotation.bounds.right - width;
    return Rect.fromLTWH(
      left,
      annotation.bounds.top,
      width,
      textBoxHeight(
        text: annotation.text,
        fontSize: annotation.fontSize,
        width: width,
      ),
    );
  }

  void _fitEditingText() {
    final preview = _previewAnnotation;
    if (!_textInputOpen || preview == null) return;
    final height = textBoxHeight(
      text: _textController.text,
      fontSize: preview.fontSize,
      width: preview.bounds.width,
    );
    if (height == preview.bounds.height) return;
    setState(() {
      _previewAnnotation = preview.copyWith(
        bounds: Rect.fromLTWH(
          preview.bounds.left,
          preview.bounds.top,
          preview.bounds.width,
          height,
        ),
      );
    });
  }

  void _onCropTap(Offset imagePoint) {
    final inside = _document.cropRect
        .inflate(4 * _pixelRatio)
        .contains(imagePoint);
    setState(() {
      _selectedTextId = null;
      _cropSelected = inside;
    });
  }

  void _placeStep(Offset imagePoint) {
    if (!_document.hasImage || _busy) return;
    final draft = _draftAnnotation(imagePoint, imagePoint)!;
    _document.addAnnotation(
      EditAnnotation(
        id: '',
        kind: draft.kind,
        style: draft.style,
        bounds: draft.bounds,
      ),
    );
  }

  void _onTextTap(Offset imagePoint) {
    if (_textInputOpen) {
      _commitText();
      return;
    }
    if (!_document.hasImage || _busy) return;
    final hit = _hitText(imagePoint);
    if (_tool == ScreenshotTool.cursor && hit == null) {
      final shape = _hitShape(imagePoint);
      if (shape != null) {
        setState(() {
          _selectedShapeId = shape.id;
          _selectedTextId = null;
          _cropSelected = false;
        });
        return;
      }
    }
    _selectedShapeId = null;
    if (_tool == ScreenshotTool.cursor) {
      if (hit == null) {
        _onCropTap(imagePoint);
      } else {
        setState(() {
          _selectedTextId = hit.id;
          _cropSelected = false;
        });
      }
      return;
    }
    if (hit != null) {
      final now = DateTime.now();
      final again =
          _lastTextTapId == hit.id &&
          now.difference(_lastTextTapAt) <= kDoubleTapTimeout;
      _lastTextTapId = hit.id;
      _lastTextTapAt = now;
      if (again) {
        _openExistingText(hit);
        return;
      }
      setState(() {
        _selectedTextId = hit.id;
        _cropSelected = false;
      });
      return;
    }
    _lastTextTapId = null;
    _openTextInput(imagePoint);
  }

  void _setTextInput(bool active) {
    _textInputOpen = active;
    unawaited(
      widget.channel.invokeMethod<void>(MethodNames.screenshotTextInput, {
        'id': _capture['id'],
        'active': active,
      }),
    );
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onModifierKey);
    _toolbarGlide.dispose();
    _ghostMerge.dispose();
    _feedbackTimer?.cancel();
    _picker.dispose();
    _toolbarRect.dispose();
    _recognizedOffset.dispose();
    _document.removeListener(_onDocumentChanged);
    _document.dispose();
    _focusNode.dispose();
    _textFocus.dispose();
    _textController.dispose();
    widget.channel.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final renderedTool = _tool;
    _pixelRatio = MediaQuery.devicePixelRatioOf(context);
    final actions = _toolbarActions();
    _syncClosing(MediaQuery.disableAnimationsOf(context), actions);
    final hasImage = _document.hasImage;
    return NativeGlassApp(
      title: 'TranSnap 截图',
      home: Focus(
        key: _editorKey,
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          if (_recognition != null) {
            if (event.logicalKey == LogicalKeyboardKey.escape) {
              setState(() => _recognition = null);
              _focusNode.requestFocus();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          }
          if (event.logicalKey == LogicalKeyboardKey.escape) {
            if (_expandedRow != null) {
              setState(() {
                _expandedRow = null;
                unawaited(_syncRecordingPreview());
                unawaited(_syncLivePreview());
              });
              return KeyEventResult.handled;
            }
            if (_textInputOpen) {
              _commitText();
            } else {
              _close();
            }
            return KeyEventResult.handled;
          }
          if (_textInputOpen) return KeyEventResult.ignored;
          if ((event.logicalKey == LogicalKeyboardKey.delete ||
                  event.logicalKey == LogicalKeyboardKey.backspace) &&
              _selectedShapeId != null) {
            _deleteSelection();
            return KeyEventResult.handled;
          }
          final direction = _arrowDirections[event.logicalKey];
          final keyboard = HardwareKeyboard.instance;
          if (direction != null &&
              !keyboard.isMetaPressed &&
              !keyboard.isControlPressed &&
              _nudgeCrop(
                direction,
                large: keyboard.isShiftPressed,
                resize: keyboard.isAltPressed,
              )) {
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.enter ||
              event.logicalKey == LogicalKeyboardKey.numpadEnter) {
            _confirmScreenshot();
            return KeyEventResult.handled;
          }
          final keys = HardwareKeyboard.instance.logicalKeysPressed;
          final meta =
              keys.contains(LogicalKeyboardKey.metaLeft) ||
              keys.contains(LogicalKeyboardKey.metaRight);
          if (meta && event.logicalKey == LogicalKeyboardKey.keyZ) {
            final shift =
                keys.contains(LogicalKeyboardKey.shiftLeft) ||
                keys.contains(LogicalKeyboardKey.shiftRight);
            if (shift) {
              if (_document.canRedo) _document.redo();
            } else {
              if (_document.canUndo) _document.undo();
            }
            return KeyEventResult.handled;
          }
          final digit = ToolbarGrid.digits[event.physicalKey];
          if (digit == null) return KeyEventResult.ignored;
          return _runToolbarSlot(ToolbarModifiers.pressed(), digit)
              ? KeyEventResult.handled
              : KeyEventResult.ignored;
        },
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: Stack(
            fit: StackFit.expand,
            children: [
              if (hasImage && _isOpenedImage)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: ResultWindowCanvas(
                        child: _EditorSurface(
                          key: ValueKey(_capture['id']),
                          openedImage: true,
                          imageScale:
                              (_capture['imageScale'] as num?)?.toDouble(),
                          channel: widget.channel,
                          document: _document,
                          tool: _tool,
                          dragStart: _dragStart,
                          dragCurrent: _dragCurrent,
                          previewAnnotation: _previewAnnotation,
                          previewCrop: _previewCrop,
                          recordingWindows: null,
                          recordingPreview: false,
                          pixelRatio: _pixelRatio,
                          brushCursor: NativeBrushCursor(
                            diameter: math.max(
                              NativeBrushCursor.minimumDiameter,
                              _drawing.styleFor(ScreenshotTool.brush).strokeWidth,
                            ),
                            color: _shapeMode == ShapeMode.mosaic
                                ? null
                                : _drawing
                                      .styleFor(ScreenshotTool.brush)
                                      .color
                                      .toARGB32(),
                            channel: widget.channel,
                          ),
                          busy: _busy,
                          textInputOpen: _textInputOpen && !_dialogOpen,
                          sourceImage: _document.source,
                          selectedShape: _selectedShapeId == null
                              ? null
                              : _styleSelection,
                          textController: _textController,
                          textFocus: _textFocus,
                          selectedText: _document.annotations
                              .where((item) => item.id == _selectedTextId)
                              .firstOrNull,
                          onDragStart: _onDragStart,
                          onDragUpdate: _onDragUpdate,
                          onDragEnd: _onDragEnd,
                          onTextTap: (point) {
                            if (_tool == renderedTool) _onTextTap(point);
                          },
                          onCropTap: _onCropTap,
                          onStepTap: (point) {
                            if (_tool == renderedTool) _placeStep(point);
                          },
                          ruler: _ruler,
                          picker: _picker,
                          pickerColor: _colorAt,
                          onPickerHover: _hoverPicker,
                          onPickerTap: (point) {
                            if (_tool == renderedTool) unawaited(_pickColor(point));
                          },
                          cropSelected: false,
                          activeHandle: _resizeHandle,
                          onDoubleTapDown: (point) => _doubleTapPoint = point,
                          onDoubleTap: () {
                            final point = _doubleTapPoint;
                            _doubleTapPoint = null;
                            if (point == null) return;
                            final hit = _tool == ScreenshotTool.cursor
                                ? _hitText(point)
                                : null;
                            if (hit != null) {
                              _openExistingText(hit);
                            } else {
                              _export('copy', closeAfterCopy: true);
                            }
                          },
                          toolbarBuilder: _buildToolbar,
                          toolbarSafeArea: null,
                          displaySize: null,
                          lines: (perLine) => _lineLengths(actions, perLine),
                          beautify: _beautify,
                          toolbarRect: _toolbarRect,
                          ocrOverlays: _ocrOverlays,
                        ),
                      ),
                    ),
                    _buildOpenedImageBar(context, actions),
                  ],
                )
              else if (hasImage)
                _EditorSurface(
                  key: ValueKey(_capture['id']),
                  imageScale: (_capture['imageScale'] as num?)?.toDouble(),
                  channel: widget.channel,
                  document: _document,
                  tool: _tool,
                  dragStart: _dragStart,
                  dragCurrent: _dragCurrent,
                  previewAnnotation: _previewAnnotation,
                  previewCrop:
                      _recordingExpanded &&
                          _recordingTarget != CaptureTarget.region
                      ? Offset.zero & _document.imageSize
                      : _previewCrop,
                  recordingWindows: _recordingWindows,
                  recordingPreview:
                      _recordingExpanded &&
                      _recordingTarget != CaptureTarget.region,
                  pixelRatio: _pixelRatio,
                  brushCursor: NativeBrushCursor(
                    diameter: math.max(
                      NativeBrushCursor.minimumDiameter,
                      _drawing.styleFor(ScreenshotTool.brush).strokeWidth,
                    ),
                    color: _shapeMode == ShapeMode.mosaic
                        ? null
                        : _drawing
                              .styleFor(ScreenshotTool.brush)
                              .color
                              .toARGB32(),
                    channel: widget.channel,
                  ),
                  busy:
                      _busy ||
                      (_recordingExpanded &&
                          _recordingTarget != CaptureTarget.region),
                  textInputOpen: _textInputOpen && !_dialogOpen,
                  sourceImage: _document.source,
                  selectedShape: _selectedShapeId == null
                      ? null
                      : _styleSelection,
                  textController: _textController,
                  textFocus: _textFocus,
                  selectedText: _document.annotations
                      .where((item) => item.id == _selectedTextId)
                      .firstOrNull,
                  onDragStart: _onDragStart,
                  onDragUpdate: _onDragUpdate,
                  onDragEnd: _onDragEnd,
                  onTextTap: (point) {
                    if (_tool == renderedTool) _onTextTap(point);
                  },
                  onCropTap: _onCropTap,
                  onStepTap: (point) {
                    if (_tool == renderedTool) _placeStep(point);
                  },
                  ruler: _ruler,
                  picker: _picker,
                  pickerColor: _colorAt,
                  onPickerHover: _hoverPicker,
                  onPickerTap: (point) {
                    if (_tool == renderedTool) unawaited(_pickColor(point));
                  },
                  cropSelected:
                      _cropSelected &&
                      !(_recordingExpanded &&
                          _recordingTarget != CaptureTarget.region),
                  activeHandle: _resizeHandle,
                  onDoubleTapDown: (point) => _doubleTapPoint = point,
                  onDoubleTap: () {
                    final point = _doubleTapPoint;
                    _doubleTapPoint = null;
                    if (point == null) return;
                    final hit = _tool == ScreenshotTool.cursor
                        ? _hitText(point)
                        : null;
                    if (hit != null) {
                      _openExistingText(hit);
                    } else {
                      _export('copy', closeAfterCopy: true);
                    }
                  },
                  toolbarBuilder: _buildToolbar,
                  toolbarSafeArea: _capture['toolbarSafeWidth'] == null
                      ? null
                      : Rect.fromLTWH(
                          (_capture['toolbarSafeX'] as num).toDouble(),
                          (_capture['toolbarSafeY'] as num).toDouble(),
                          (_capture['toolbarSafeWidth'] as num).toDouble(),
                          (_capture['toolbarSafeHeight'] as num).toDouble(),
                        ),
                  displaySize: _capture['displayWidth'] == null
                      ? null
                      : Size(
                          (_capture['displayWidth'] as num).toDouble(),
                          (_capture['displayHeight'] as num).toDouble(),
                        ),
                  lines: (perLine) => _lineLengths(actions, perLine),
                  beautify: _beautify,
                  toolbarRect: _toolbarRect,
                  ocrOverlays: _ocrOverlays,
                )
              else
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 400),
                    child: Material(
                      color: const Color(0xF0111111),
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _feedbackMessage ??
                                  (_capture['screenAccess'] == false
                                      ? '截图需要屏幕录制权限'
                                      : '正在准备截图'),
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                              ),
                            ),
                            if (_capture['screenAccess'] == false &&
                                _capture['imageScale'] == null) ...[
                              const SizedBox(height: 16),
                              NativeGlassSurface(
                                material: true,
                                child: FilledButton(
                                  onPressed: _busy
                                      ? null
                                      : () => _command(
                                          MethodNames.requestScreenAccess,
                                        ),
                                  child: const Text('申请屏幕录制权限'),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              if (!hasImage)
                Positioned(
                  right: 16,
                  top: 16,
                  child: NativeGlassSurface(
                    material: true,
                    child: IconButton(
                      key: const Key(ScreenshotActions.close),
                      tooltip: '关闭',
                      onPressed: _busy ? null : _close,
                      icon: const LineIcon(LucideIcons.x),
                    ),
                  ),
                ),
              if (_recognition != null)
                LayoutBuilder(
                  builder: (context, constraints) {
                    final panelWidth = math.min(
                      RecognizedTextPanel.size.width,
                      math.max(
                        0.0,
                        constraints.maxWidth - GlassMetrics.space16,
                      ),
                    );
                    final panelHeight = math.min(
                      RecognizedTextPanel.size.height,
                      math.max(
                        0.0,
                        constraints.maxHeight - GlassMetrics.space16,
                      ),
                    );
                    final maxDx = math.max(
                      0.0,
                      (constraints.maxWidth - panelWidth) / 2 -
                          GlassMetrics.space8,
                    );
                    final maxDy = math.max(
                      0.0,
                      (constraints.maxHeight - panelHeight) / 2 -
                          GlassMetrics.space8,
                    );
                    Offset clampOffset(Offset value) => Offset(
                      value.dx.clamp(-maxDx, maxDx).toDouble(),
                      value.dy.clamp(-maxDy, maxDy).toDouble(),
                    );
                    return Center(
                      child: ValueListenableBuilder<Offset>(
                        valueListenable: _recognizedOffset,
                        builder: (context, offset, child) =>
                            Transform.translate(
                              offset: clampOffset(offset),
                              child: child,
                            ),
                        child: SizedBox(
                          width: panelWidth,
                          height: panelHeight,
                          child: RecognizedTextPanel(
                            text: _recognition!.text,
                            codes: _recognition!.codes,
                            onCopyAll: () =>
                                _copyRecognized(_recognition!.text, '已复制文字'),
                            onCopyCode: (payload) =>
                                _copyRecognized(payload, '已复制内容'),
                            onOpenLink: _openLink,
                            onClose: () {
                              setState(() => _recognition = null);
                              _focusNode.requestFocus();
                            },
                            onDrag: (delta) => _recognizedOffset.value =
                                clampOffset(_recognizedOffset.value + delta),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              if (hasImage && _isOpenedImage)
                ..._buildOpenedImageTray(context, actions),
              if (hasImage && _feedbackMessage != null)
                ValueListenableBuilder<Rect>(
                  valueListenable: _toolbarRect,
                  builder: (context, toolbarRect, _) => ToolbarFeedback(
                    toolbar: _isOpenedImage
                        ? Rect.fromLTWH(
                            0,
                            MediaQuery.sizeOf(context).height -
                                GlassMetrics.resultBarHeight,
                            MediaQuery.sizeOf(context).width,
                            GlassMetrics.resultBarHeight,
                          )
                        : toolbarRect,
                    message: _feedbackMessage!,
                    isError: _failed,
                    onHoverChanged: _failed ? _onFeedbackHoverChanged : null,
                    onDismiss: _failed ? _dismissFeedback : null,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  double _toImageFont(double visual) => visual * _pixelRatio;

  double _toVisualFont(double imageFont) => imageFont / _pixelRatio;

  double _nearestVisualFont(double visual) {
    return ScreenshotDefaults.fontSizes.reduce(
      (a, b) => (a - visual).abs() < (b - visual).abs() ? a : b,
    );
  }

  void _applyStyleToCurrent() {
    final imageFont = _toImageFont(_fontSize);
    if (_textInputOpen && _previewAnnotation != null) {
      final preview = _previewAnnotation!;
      _previewAnnotation = preview.copyWith(
        style: _textStyle,
        fontSize: imageFont,
        bounds: Rect.fromLTWH(
          preview.bounds.left,
          preview.bounds.top,
          preview.bounds.width,
          textBoxHeight(
            text: _textController.text,
            fontSize: imageFont,
            width: preview.bounds.width,
          ),
        ),
      );
      return;
    }
    final id = _selectedTextId;
    if (id == null) return;
    final current = _document.annotations
        .where((item) => item.id == id)
        .firstOrNull;
    if (current == null || current.kind != AnnotationKind.text) return;
    _document.updateAnnotation(
      current.copyWith(
        style: _textStyle,
        fontSize: imageFont,
        bounds: Rect.fromLTWH(
          current.bounds.left,
          current.bounds.top,
          current.bounds.width,
          textBoxHeight(
            text: current.text,
            fontSize: imageFont,
            width: current.bounds.width,
          ),
        ),
      ),
    );
  }

  void _nudgeFontSize(int delta) {
    final selected = _textInputOpen ? _previewAnnotation : _styleSelection;
    if (selected?.kind == AnnotationKind.text) {
      _textStyle = selected!.style;
      _fontSize = _nearestVisualFont(_toVisualFont(selected.fontSize));
    }
    final sizes = ScreenshotDefaults.fontSizes;
    final index = sizes.indexOf(_fontSize);
    final next = (index < 0 ? 1 : index) + delta;
    if (next < 0 || next >= sizes.length) return;
    setState(() {
      _fontSize = sizes[next];
      _applyStyleToCurrent();
    });
    if (_selectedTextId == null && _editingTextId == null) {
      _drawing = _drawing.copyWith(fontSize: _fontSize);
      _persistDrawing();
    }
  }

  void _toggleToolbarExpanded() =>
      _setToolbarExpanded(!_toolbarExpanded);

  Offset? _favoritesPosition() {
    final box = _favoritesKey.currentContext?.findRenderObject();
    return box is RenderBox && box.hasSize
        ? box.localToGlobal(Offset.zero)
        : null;
  }

  void _setToolbarExpanded(bool expand) {
    if (expand == _toolbarExpanded) return;
    final reduced = MediaQuery.disableAnimationsOf(context);
    final before = _favoritesPosition();
    final ghosts = expand || reduced || before == null
        ? const <({_ToolbarCells group, Offset offset, Size size})>[]
        : _departingGhosts(before);
    final favorites = _favoritesKey.currentContext?.size ?? Size.zero;
    _ghostMerge.stop();
    setState(() {
      _toolbarExpanded = expand;
      _toolbarGridShown = expand;
      _toolbarSplitting = expand;
      _ghosts = ghosts;
      _ghostTarget = favorites;
    });
    if (expand) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _toolbarSplitting = false,
      );
    } else if (ghosts.isNotEmpty) {
      _ghostMerge.value = 0;
      _ghostMerge
          .animateWith(SpringSimulation(AppMotion.settleSpring, 0, 1, 0))
          .then((_) {
            if (mounted) setState(() => _ghosts = const []);
          });
    }
    _glideFavoritesFrom(before);
  }

  List<({_ToolbarCells group, Offset offset, Size size})> _departingGhosts(
    Offset favorites,
  ) => [
    for (final (index, column) in _toolbar.columns.indexed)
      if (_gridBlockKeys['screenshot-grid-group-$index']?.currentContext
          ?.findRenderObject()
          case final RenderBox box when box.attached && box.hasSize)
        (
          group: (
            key: 'screenshot-grid-group-$index',
            cells: [
              for (final id in column.slots)
                id == null || _toolbar.hidden.contains(id) ? null : id,
            ],
            modifiers: column.modifiers,
          ),
          offset: box.localToGlobal(Offset.zero) - favorites,
          size: box.size,
        ),
  ];

  void _glideFavoritesFrom(Offset? before) {
    if (before == null || MediaQuery.disableAnimationsOf(context)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final after = _favoritesPosition();
      if (!mounted || after == null) return;
      final shift = before - (after - _glideOffset);
      if (shift.distance < 0.5) return;
      _toolbarShift = shift;
      _toolbarGlide.value = 0;
      _toolbarGlide
          .animateWith(SpringSimulation(AppMotion.bouncySpring, 0, 1, 0))
          .then((_) => _toolbarGlide.value = 1);
    });
  }

  bool _runToolbarSlot(int modifiers, int digit) {
    final action = _toolbar.actionAt(modifiers, digit);
    if (action == null) return false;
    if (modifiers != 0 && !_toolbarExpanded) _setToolbarExpanded(true);
    _toolbarActions()[action]?.call();
    return true;
  }

  Map<String, VoidCallback?> _toolbarActions() {
    final showDrawingAttributes = !_beautifyExpanded;
    final textControls =
        showDrawingAttributes &&
        (_tool == ScreenshotTool.text ||
            (_selectedTextId != null &&
                _document.annotations.any(
                  (item) =>
                      item.id == _selectedTextId &&
                      item.kind == AnnotationKind.text,
                )));
    final styleTool = _styleTool;
    final brushMode = _styleSelection?.shapeMode ?? _shapeMode;
    final actions = <String, VoidCallback?>{
      ScreenshotActions.record: _capture['canCaptureMedia'] == true
          ? () {
              setState(() {
                _tool = ScreenshotTool.crop;
                _expandedRow = _recordingExpanded
                    ? null
                    : _ExpandedRow.recording;
                _selectedShapeId = null;
                _selectedTextId = null;
              });
              unawaited(_syncRecordingPreview());
              unawaited(_syncLivePreview());
            }
          : null,
      ScreenshotActions.scrolling: _capture['canCaptureMedia'] == true
          ? () => _prepareCapture(CaptureTarget.region, scrolling: true)
          : null,
      if (showDrawingAttributes && styleTool == ScreenshotTool.rect)
        for (final shape in ShapeVariant.values)
          '${ScreenshotActions.shapePrefix}${shape.name}': () =>
              _chooseShape(shape),
      if (showDrawingAttributes && styleTool == ScreenshotTool.brush)
        for (final mode in ShapeMode.values)
          '${ScreenshotActions.brushPrefix}${mode.name}': () =>
              _chooseBrush(mode),
      if (showDrawingAttributes && supportsDrawingColor(styleTool, brushMode))
        ScreenshotActions.palette: () => _editDrawingStyle(color: true),
      if (showDrawingAttributes &&
          supportsStrokeWidth(styleTool) &&
          !(styleTool == ScreenshotTool.rect && _styleShape.filled))
        ScreenshotActions.width: () => _editDrawingStyle(color: false),
      for (final entry in _toolIds.entries)
        if (entry.value != ScreenshotTool.cursor)
          entry.key: () => setState(() {
            if (_textInputOpen) _commitText();
            _tool = _activeId == entry.key
                ? ScreenshotTool.cursor
                : entry.value;
            _expandedRow = null;
            _ruler = null;
            _picker.value = null;
            unawaited(_syncRecordingPreview());
            unawaited(_syncLivePreview());
            _recordingApplication = null;
            _selectedShapeId = null;
            _selectedTextId = null;
          }),
      ScreenshotActions.beautify: _document.hasImage
          ? () {
              setState(() {
                _expandedRow = _beautifyExpanded ? null : _ExpandedRow.beautify;
              });
              unawaited(_syncRecordingPreview());
              unawaited(_syncLivePreview());
            }
          : null,
      ScreenshotActions.ratio: _document.hasImage
          ? () {
              setState(() {
                _tool = ScreenshotTool.crop;
                _expandedRow = _expandedRow == _ExpandedRow.ratio
                    ? null
                    : _ExpandedRow.ratio;
                _selectedShapeId = null;
                _selectedTextId = null;
              });
              unawaited(_syncRecordingPreview());
              unawaited(_syncLivePreview());
            }
          : null,
      ScreenshotActions.pin: _document.hasImage ? () => _export('pin') : null,
      ScreenshotActions.save: _document.hasImage ? () => _export('save') : null,
      ScreenshotActions.copy: _document.hasImage ? () => _export('copy') : null,
      ScreenshotActions.sticker: _document.hasImage ? _openStickerPanel : null,
      ScreenshotActions.ocrCopy: _document.hasImage
          ? _showRecognizedText
          : null,
      ScreenshotActions.ocrTranslate: _document.hasImage ? _translateOcr : null,
      ScreenshotActions.close: _close,
      if (textControls) ...{
        ScreenshotActions.sizeDown: () => _nudgeFontSize(-1),
        ScreenshotActions.sizeUp: () => _nudgeFontSize(1),
      },
      if (_savedPath != null)
        ScreenshotActions.reveal: () => widget.channel.invokeMethod<void>(
          MethodNames.revealFile,
          {'path': _savedPath},
        ),
    };
    if (_busy) return actions.map((id, _) => MapEntry(id, null));
    if (_childrenRevealed) return actions;
    return actions.map(
      (id, action) => MapEntry(
        id,
        action == null
            ? null
            : () {
                final revealOnly =
                    _activeId == id && _visibleChildrenOf(id).isNotEmpty;
                setState(() => _childrenRevealed = true);
                if (!revealOnly) action();
              },
      ),
    );
  }

  Widget _buildOpenedImageBar(
    BuildContext context,
    Map<String, VoidCallback?> actions,
  ) {
    final brushMode = _styleSelection?.shapeMode ?? _shapeMode;
    final isMosaic =
        _tool == ScreenshotTool.brush && brushMode == ShapeMode.mosaic;
    return ResultWindowBar(
      leading: [
        ResultIconButton(
          buttonKey: const Key(ScreenshotActions.rect),
          icon: LucideIcons.square,
          tooltip: '图形',
          selected: _tool == ScreenshotTool.rect,
          onPressed: actions[ScreenshotActions.rect],
        ),
        ResultIconButton(
          buttonKey: const Key(ScreenshotActions.arrow),
          icon: LucideIcons.arrowUpRight,
          tooltip: '箭头',
          selected: _tool == ScreenshotTool.arrow,
          onPressed: actions[ScreenshotActions.arrow],
        ),
        ResultIconButton(
          buttonKey: const Key(ScreenshotActions.text),
          icon: LucideIcons.type,
          tooltip: '文字',
          selected: _tool == ScreenshotTool.text,
          onPressed: actions[ScreenshotActions.text],
        ),
        ResultIconButton(
          buttonKey: const Key(ScreenshotActions.brush),
          icon: LucideIcons.brush,
          tooltip: '画笔',
          selected: _tool == ScreenshotTool.brush && !isMosaic,
          onPressed: _busy
              ? null
              : () => setState(() {
                  if (_textInputOpen) _commitText();
                  _tool = ScreenshotTool.brush;
                  if (_shapeMode == ShapeMode.mosaic) {
                    _drawing = _drawing.copyWith(brushMode: ShapeMode.solid);
                    _persistDrawing();
                  }
                  _selectedShapeId = null;
                  _selectedTextId = null;
                }),
        ),
        ResultIconButton(
          buttonKey: const Key('${ScreenshotActions.brushPrefix}mosaic-tool'),
          icon: LucideIcons.grid,
          tooltip: '马赛克',
          selected: isMosaic,
          onPressed: _busy
              ? null
              : () => setState(() {
                  if (_textInputOpen) _commitText();
                  _tool = ScreenshotTool.brush;
                  if (_shapeMode != ShapeMode.mosaic) {
                    _drawing = _drawing.copyWith(brushMode: ShapeMode.mosaic);
                    _persistDrawing();
                  }
                  _selectedShapeId = null;
                  _selectedTextId = null;
                }),
        ),
        const ResultBarDivider(),
        ResultIconButton(
          buttonKey: const Key('screenshot-undo'),
          icon: LucideIcons.undo2,
          tooltip: '撤销',
          onPressed: !_busy && _document.canUndo ? _document.undo : null,
        ),
        ResultIconButton(
          buttonKey: const Key('screenshot-redo'),
          icon: LucideIcons.redo2,
          tooltip: '重做',
          onPressed: !_busy && _document.canRedo ? _document.redo : null,
        ),
      ],
      trailing: [
        ResultTextButton(
          buttonKey: const Key(ScreenshotActions.ocrCopy),
          label: '识别文字',
          icon: LucideIcons.scanText,
          onPressed: actions[ScreenshotActions.ocrCopy],
          busy: _busy && _busyId == ScreenshotActions.ocrCopy,
        ),
        ResultTextButton(
          buttonKey: const Key(ScreenshotActions.ocrTranslate),
          label: '翻译',
          icon: LucideIcons.languages,
          onPressed: actions[ScreenshotActions.ocrTranslate],
          busy: _busy && _busyId == ScreenshotActions.ocrTranslate,
        ),
        ResultTextButton(
          buttonKey: const Key(ScreenshotActions.pin),
          label: '贴图',
          icon: LucideIcons.pin,
          onPressed: actions[ScreenshotActions.pin],
          busy: _busy && _busyId == ScreenshotActions.pin,
        ),
        const ResultBarDivider(),
        ResultTextButton(
          buttonKey: const Key(ScreenshotActions.copy),
          label: '复制',
          icon: LucideIcons.copy,
          onPressed: actions[ScreenshotActions.copy],
          busy: _busy && _busyId == ScreenshotActions.copy,
        ),
        ResultTextButton(
          buttonKey: const Key(ScreenshotActions.save),
          label: '保存',
          icon: LucideIcons.save,
          primary: true,
          onPressed: actions[ScreenshotActions.save],
          busy: _busy && _busyId == ScreenshotActions.save,
        ),
      ],
    );
  }

  List<Widget> _buildOpenedImageTray(
    BuildContext context,
    Map<String, VoidCallback?> actions,
  ) {
    final styleTool = _styleTool;
    final brushMode = _styleSelection?.shapeMode ?? _shapeMode;
    final items = <Widget>[];
    var anchorIndex = -1;

    void addItem(
      String id,
      IconData? icon, {
      bool selected = false,
      Widget? glyph,
    }) {
      if (items.isNotEmpty) items.add(const SizedBox(width: 4));
      items.add(
        ResultIconButton(
          buttonKey: Key(id),
          icon: icon,
          glyph: glyph,
          tooltip: ScreenshotActions.labels[id] ?? id,
          compact: true,
          selected: selected,
          onPressed: actions[id],
        ),
      );
    }

    void addDivider() {
      if (items.isEmpty) return;
      final dark = Theme.of(context).brightness == Brightness.dark;
      items.add(
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: SizedBox(
            width: 1,
            height: 16,
            child: ColoredBox(color: ResultWindowColors.hairline(dark)),
          ),
        ),
      );
    }

    switch (styleTool) {
      case ScreenshotTool.rect:
        anchorIndex = 1;
        addItem(
          '${ScreenshotActions.shapePrefix}rectangle',
          LucideIcons.square,
          selected: _styleShape == ShapeVariant.rectangle,
        );
        addItem(
          '${ScreenshotActions.shapePrefix}circle',
          LucideIcons.circle,
          selected: _styleShape == ShapeVariant.circle,
        );
        addItem(
          '${ScreenshotActions.shapePrefix}filledRectangle',
          null,
          glyph: const ShapeFillIcon(circle: false),
          selected: _styleShape == ShapeVariant.filledRectangle,
        );
        addItem(
          '${ScreenshotActions.shapePrefix}filledCircle',
          null,
          glyph: const ShapeFillIcon(circle: true),
          selected: _styleShape == ShapeVariant.filledCircle,
        );
        addDivider();
        addItem(ScreenshotActions.palette, LucideIcons.palette);
        if (!_styleShape.filled) {
          addItem(ScreenshotActions.width, LucideIcons.slidersHorizontal);
        }
      case ScreenshotTool.arrow:
        anchorIndex = 2;
        addItem(ScreenshotActions.palette, LucideIcons.palette);
        addItem(ScreenshotActions.width, LucideIcons.slidersHorizontal);
      case ScreenshotTool.text:
        anchorIndex = 3;
        addItem(ScreenshotActions.palette, LucideIcons.palette);
        if (actions.containsKey(ScreenshotActions.sizeDown)) {
          addItem(ScreenshotActions.sizeDown, LucideIcons.aArrowDown);
        }
        if (actions.containsKey(ScreenshotActions.sizeUp)) {
          addItem(ScreenshotActions.sizeUp, LucideIcons.aArrowUp);
        }
      case ScreenshotTool.brush:
        if (brushMode == ShapeMode.mosaic) {
          anchorIndex = 5;
          addItem(ScreenshotActions.width, LucideIcons.slidersHorizontal);
        } else {
          anchorIndex = 4;
          addItem(
            '${ScreenshotActions.brushPrefix}solid',
            LucideIcons.brush,
            selected: brushMode == ShapeMode.solid,
          );
          addItem(
            '${ScreenshotActions.brushPrefix}highlighter',
            LucideIcons.highlighter,
            selected: brushMode == ShapeMode.highlighter,
          );
          addDivider();
          addItem(ScreenshotActions.palette, LucideIcons.palette);
          addItem(ScreenshotActions.width, LucideIcons.slidersHorizontal);
        }
      default:
        return const [];
    }
    if (items.isEmpty || anchorIndex < 0) return const [];
    final anchorCenterX =
        GlassMetrics.space12 + anchorIndex * 36.0 + GlassMetrics.hitSize / 2;
    const trayLeft = GlassMetrics.space12;
    return [
      Positioned(
        key: const Key('opened-image-upward-tray'),
        left: trayLeft,
        bottom: GlassMetrics.resultBarHeight + GlassMetrics.space8,
        child: ResultUpwardTray(
          anchorCenterX: anchorCenterX - trayLeft,
          children: items,
        ),
      ),
    ];
  }

  Widget _buildToolbar(
    BuildContext context,
    Axis axis,
    int perLine,
    ValueChanged<Offset> onToolbarDrag,
  ) {
    var dragHandlePlaced = false;
    final actions = _toolbarActions();
    final cross = axis == Axis.horizontal ? Axis.vertical : Axis.horizontal;
    final colors = Theme.of(context).colorScheme;
    final icons = <String, IconData>{
      ...ScreenshotActions.icons,
      ScreenshotActions.palette: LucideIcons.palette,
      ScreenshotActions.width: LucideIcons.slidersHorizontal,
      ScreenshotActions.sizeDown: LucideIcons.aArrowDown,
      ScreenshotActions.sizeUp: LucideIcons.aArrowUp,
      ScreenshotActions.reveal: LucideIcons.folderOpen,
      '${ScreenshotActions.shapePrefix}rectangle': LucideIcons.square,
      '${ScreenshotActions.shapePrefix}circle': LucideIcons.circle,
      '${ScreenshotActions.brushPrefix}solid': LucideIcons.brush,
      '${ScreenshotActions.brushPrefix}mosaic': LucideIcons.grid,
      '${ScreenshotActions.brushPrefix}highlighter': LucideIcons.highlighter,
    };
    final dark = Theme.of(context).brightness == Brightness.dark;
    final reduced = AppMotion.reduced(context);
    Widget button(
      String id, {
      bool compact = false,
      bool raised = false,
      int? digit,
    }) {
      final selected =
          id == _activeId ||
          id == _group ||
          id == '${ScreenshotActions.shapePrefix}${_styleShape.name}' ||
          id ==
              '${ScreenshotActions.brushPrefix}${(_styleSelection?.shapeMode ?? _shapeMode).name}';
      final accentFill = NativeGlassTheme.accentFillOf(context);
      final onAccent = NativeGlassTheme.onAccentOf(context);
      final size = compact ? ToolbarGrid.trayButton : 32.0;
      final radius = compact ? ToolbarGrid.trayButtonRadius : 8.0;
      final line = (dark ? Colors.white : Colors.black).withValues(alpha: 0.10);
      final iconButton = Semantics(
        selected: selected,
        child: SizedBox(
          width: size,
          height: size,
          child: IconButton(
            key: Key(id),
            tooltip: [
              ScreenshotActions.labels[id]!,
              ?_toolbar.shortcutLabel(id),
            ].join(' '),
            onPressed: actions[id],
            style: ButtonStyle(
              padding: const WidgetStatePropertyAll(EdgeInsets.zero),
              backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
              foregroundColor: WidgetStatePropertyAll(
                selected ? onAccent : colors.onSurface,
              ),
              shape: WidgetStatePropertyAll(
                RoundedSuperellipseBorder(
                  borderRadius: BorderRadius.circular(radius),
                ),
              ),
            ),
            icon: switch (id) {
              '${ScreenshotActions.shapePrefix}filledRectangle' =>
                ShapeFillIcon(circle: false, size: compact ? 14 : 16),
              '${ScreenshotActions.shapePrefix}filledCircle' =>
                ShapeFillIcon(circle: true, size: compact ? 14 : 16),
              _ => LineIcon(
                icons[id] ?? LucideIcons.circleDot,
                size: compact ? 14 : 16,
              ),
            },
          ),
        ),
      );
      final face = AnimatedContainer(
        duration: reduced ? Duration.zero : GlassMetrics.transition,
        curve: Curves.easeOutCubic,
        transform: Matrix4.translationValues(0, raised && !reduced ? -1 : 0, 0),
        foregroundDecoration: raised && !selected
            ? ShapeDecoration(
                shape: RoundedSuperellipseBorder(
                  borderRadius: BorderRadius.circular(radius),
                  side: BorderSide(color: line, width: 0.5),
                ),
              )
            : null,
        decoration: ShapeDecoration(
          color: selected
              ? accentFill
              : raised
              ? (dark ? const Color(0xFF3D3D41) : Colors.white)
              : Colors.transparent,
          shape: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.circular(radius),
          ),
          shadows: raised
              ? const [
                  BoxShadow(
                    color: Color(0x38000000),
                    blurRadius: 6,
                    offset: Offset(0, 3),
                  ),
                ]
              : const [],
        ),
        child: Stack(
          children: [
            NativeGlassButtonFeedback(
              radius: radius,
              enabled: actions[id] != null,
              bezel: false,
              child: iconButton,
            ),
            if (raised && digit != null)
              Positioned(
                top: 2,
                right: 2,
                child: IgnorePointer(
                  child: Text(
                    '$digit',
                    style: TextStyle(
                      fontSize: 9,
                      height: 1,
                      fontWeight: FontWeight.w700,
                      color: selected ? onAccent : colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
      final ring = BusyRing(
        active: _busy && id == _busyId,
        color: NativeGlassTheme.accentOf(context),
        radius: radius + MotionMetrics.busyRingOutset,
        child: face,
      );
      final anchored = id == ScreenshotActions.sticker
          ? KeyedSubtree(key: _stickerAnchor, child: ring)
          : ring;
      return KeyedSubtree(
        key: _buttonKeys.putIfAbsent(id, GlobalKey.new),
        child: anchored,
      );
    }

    final blockColor = dark ? const Color(0xFF2A2A2D) : const Color(0xFFFBFBFC);
    final trayColor = dark ? const Color(0xFF1D1D1F) : const Color(0xFFECECED);

    ShapeDecoration panel(Color color, double radius, double lift) =>
        ShapeDecoration(
      color: color,
      shape: RoundedSuperellipseBorder(
        borderRadius: BorderRadius.circular(radius),
        side: BorderSide(
          color: dark
              ? Colors.white.withValues(alpha: 0.12)
              : Colors.black.withValues(alpha: 0.14),
          width: 0.5,
        ),
      ),
      shadows: [
        BoxShadow.lerp(
          const BoxShadow(
            color: Color(0x33000000),
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
          const BoxShadow(
            color: Color(0x4D000000),
            blurRadius: 30,
            offset: Offset(0, 12),
          ),
          lift,
        )!,
      ],
    );
    final liftDuration = reduced
        ? Duration.zero
        : MotionMetrics.iconSwitchDuration;

    Widget lifted(Color color, double radius, Widget child) =>
        TweenAnimationBuilder<double>(
          tween: Tween(end: _toolbarLifted ? 1.0 : 0.0),
          duration: liftDuration,
          builder: (context, lift, child) => DecoratedBox(
            decoration: panel(color, radius, lift),
            child: child,
          ),
          child: child,
        );

    Widget block(Widget child) => lifted(
      blockColor,
      ToolbarGrid.blockRadius,
      Padding(
        padding: const EdgeInsets.all(ToolbarGrid.blockPadding),
        child: child,
      ),
    );

    Widget groupOf(
      _ToolbarCells group, {
      bool compact = false,
      bool ghost = false,
    }) {
      final size = compact ? ToolbarGrid.trayButton : 32.0;
      final raised =
          group.modifiers != null && group.modifiers == _heldModifiers;
      final cells = [
        for (final (slot, id) in group.cells.indexed)
          if (id == null)
            SizedBox(width: size, height: size)
          else if (id == _busyCell)
            BusyRing(
              key: const Key(_busyCell),
              active: true,
              color: NativeGlassTheme.accentOf(context),
              child: SizedBox(width: size, height: size),
            )
          else
            button(
              id,
              compact: compact,
              raised: raised,
              digit: group.modifiers == null ? null : slot + 1,
            ),
      ];
      final isClosing = group.key.startsWith('screenshot-closing-group-');
      final isChildren = group.key.startsWith('screenshot-children-group-');
      final isAttributes = group.key.startsWith('screenshot-attributes-group-');
      final parent = isClosing
          ? _closing?.parent
          : isChildren
          ? _group
          : isAttributes
          ? (_group ?? _activeId)
          : null;
      if (parent != null) {
        final kind = isClosing
            ? (_closing?.kind ?? 'children')
            : isChildren
            ? 'children'
            : 'attributes';
        final chunkIndex = group.key.split('-').last;
        return LiquidSplit(
          key: ValueKey('liquid-$parent-$kind-$chunkIndex'),
          flexKey: Key(group.key),
          axis: axis,
          items: cells,
          anchor: _buttonKeys.putIfAbsent(parent, GlobalKey.new),
          color: NativeGlassTheme.accentOf(context),
          collapsing: isClosing,
          onCollapsed: () {
            if (mounted) setState(() => _closing = null);
          },
        );
      }
      final row = Flex(
        key: Key(group.key),
        direction: axis,
        mainAxisSize: MainAxisSize.min,
        spacing: 4,
        children: cells,
      );
      if (group.modifiers == null) {
        return BouncyPresence(
          key: ValueKey('presence-${group.key}'),
          fromScale: 0.90,
          child: block(row),
        );
      }
      final label = ToolbarModifiers.label(group.modifiers!);
      final hint = SizedBox(
        width: axis == Axis.horizontal ? ToolbarGrid.hintExtent : 32,
        height: axis == Axis.horizontal ? 32 : ToolbarGrid.hintExtent,
        child: label.isEmpty
            ? Center(
                child: DecoratedBox(
                  key: Key('toolbar-hint-${group.key}'),
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: colors.onSurfaceVariant,
                      width: ToolbarGrid.tabKeycapBorder,
                    ),
                    borderRadius: BorderRadius.circular(
                      ToolbarGrid.tabKeycapRadius,
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 2.5,
                      vertical: 2,
                    ),
                    child: Text(
                      'tab',
                      style: TextStyle(
                        fontSize: ToolbarGrid.tabKeycapFont,
                        height: 1,
                        fontWeight: FontWeight.w700,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              )
            : Center(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    label,
                    key: Key('toolbar-hint-${group.key}'),
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: ToolbarGrid.hintFont,
                      fontWeight: FontWeight.w600,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
      );
      final handleActive = _toolbarHandleHovered || _toolbarLifted;
      final hintControl = !dragHandlePlaced
          ? Tooltip(
              message: _toolbarExpanded
                  ? '拖动移动工具栏，双击图标或连按两次 Tab 收起为常用工具栏'
                  : '拖动移动工具栏，双击图标或连按两次 Tab 展开完整工具栏',
              preferBelow: false,
              child: MouseRegion(
                cursor: _toolbarLifted
                    ? SystemMouseCursors.grabbing
                    : SystemMouseCursors.grab,
                onEnter: (_) => setState(() => _toolbarHandleHovered = true),
                onExit: (_) => setState(() => _toolbarHandleHovered = false),
                child: GestureDetector(
                  key: const Key('toolbar-drag-handle'),
                  behavior: HitTestBehavior.opaque,
                  dragStartBehavior: DragStartBehavior.down,
                  onPanStart: (_) => setState(() => _toolbarLifted = true),
                  onPanUpdate: (details) => onToolbarDrag(details.delta),
                  onPanEnd: (_) => setState(() => _toolbarLifted = false),
                  onPanCancel: () => setState(() => _toolbarLifted = false),
                  onDoubleTap: _toggleToolbarExpanded,
                  child: AnimatedContainer(
                    duration: liftDuration,
                    decoration: ShapeDecoration(
                      color: handleActive
                          ? colors.onSurface.withValues(alpha: 0.06)
                          : Colors.transparent,
                      shape: RoundedSuperellipseBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    child: AppMotion.iconSwitcher(
                      context,
                      handleActive
                          ? SizedBox(
                              key: const Key('toolbar-drag-grip'),
                              width: axis == Axis.horizontal
                                  ? ToolbarGrid.hintExtent
                                  : 32,
                              height: axis == Axis.horizontal
                                  ? 32
                                  : ToolbarGrid.hintExtent,
                              child: Center(
                                child: LineIcon(
                                  LucideIcons.gripVertical,
                                  size: 14,
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                            )
                          : KeyedSubtree(
                              key: const ValueKey('toolbar-drag-hint'),
                              child: hint,
                            ),
                    ),
                  ),
                ),
              ),
            )
          : hint;
      dragHandlePlaced = true;
      final framed = block(
        AnimatedOpacity(
          opacity: _heldModifiers != 0 && !raised ? 0.4 : 1,
          duration: reduced ? Duration.zero : GlassMetrics.transition,
          child: Flex(
            direction: axis,
            mainAxisSize: MainAxisSize.min,
            spacing: 4,
            children: [hintControl, row],
          ),
        ),
      );
      if (ghost) return framed;
      if (group.key == _favoritesGroupKey) {
        return KeyedSubtree(key: _favoritesKey, child: framed);
      }
      return LiquidBlockSplit(
        key: ValueKey('split-${group.key}'),
        origin: _favoritesKey,
        order: int.tryParse(group.key.split('-').last) ?? 0,
        entering: _toolbarSplitting,
        child: KeyedSubtree(
          key: _gridBlockKeys.putIfAbsent(group.key, GlobalKey.new),
          child: framed,
        ),
      );
    }

    Widget captureButton(
      String label,
      Widget icon,
      VoidCallback? action, {
      bool selected = false,
    }) {
      final accentFill = NativeGlassTheme.accentFillOf(context);
      final onAccent = NativeGlassTheme.onAccentOf(context);
      const radius = ToolbarGrid.trayButtonRadius;
      return DecoratedBox(
        decoration: ShapeDecoration(
          color: selected ? accentFill : Colors.transparent,
          shape: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.circular(radius),
          ),
        ),
        child: NativeGlassButtonFeedback(
          radius: radius,
          enabled: !_busy && action != null,
          bezel: false,
          child: SizedBox.square(
            dimension: ToolbarGrid.trayButton,
            child: MergeSemantics(
              child: Semantics(
                label: label,
                selected: selected,
                child: IconButton(
                  tooltip: label,
                  onPressed: _busy ? null : action,
                  icon: icon,
                  style: ButtonStyle(
                    padding: const WidgetStatePropertyAll(EdgeInsets.zero),
                    backgroundColor: const WidgetStatePropertyAll(
                      Colors.transparent,
                    ),
                    foregroundColor: WidgetStatePropertyAll(
                      selected ? onAccent : colors.onSurface,
                    ),
                    shape: WidgetStatePropertyAll(
                      RoundedSuperellipseBorder(
                        borderRadius: BorderRadius.circular(radius),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    final stripSpecs = _strips();

    Widget captureRow(String key, List<Widget> children) {
      final anchorId = stripSpecs[key]!.anchor;
      return LiquidSplit(
        key: ValueKey('liquid-strip-$anchorId-$key'),
        flexKey: Key(key),
        axis: axis,
        scrollable: true,
        items: children,
        anchor: _buttonKeys.putIfAbsent(anchorId, GlobalKey.new),
        color: NativeGlassTheme.accentOf(context),
      );
    }

    final beautify = _beautify;
    final beautifyMenuFlat = ShapeDecoration(
      color: Colors.transparent,
      shape: RoundedSuperellipseBorder(
        borderRadius: BorderRadius.circular(ToolbarGrid.trayButtonRadius),
      ),
    );
    final beautifyControls = <Widget>[
      if (_beautifyExpanded) ...[
        captureButton(
          '背景',
          beautify == null
              ? const LineIcon(LucideIcons.ban, size: 14)
              : Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: beautify.background.gradient == null
                        ? beautify.background.color
                        : null,
                    gradient: switch (beautify.background.gradient) {
                      final gradient? => LinearGradient(
                        colors: [beautify.background.color, gradient.end],
                      ),
                      null => null,
                    },
                  ),
                ),
          _editBeautifyBackground,
          selected: beautify != null,
        ),
        SizedBox(
          width: BeautifyMetrics.paddingMenuWidth,
          height: ToolbarGrid.trayButton,
          child: NativeGlassMenuButton<double>(
            value: beautify?.padding ?? BeautifyMetrics.defaultPadding,
            dense: true,
            flat: beautifyMenuFlat,
            items: {
              for (final value in BeautifyMetrics.paddings)
                value: '内边距 ${value.round()}',
            },
            onChanged: beautify == null
                ? null
                : (value) => setState(
                    () => _beautify = beautify.copyWith(padding: value),
                  ),
          ),
        ),
        SizedBox(
          width: BeautifyMetrics.radiusMenuWidth,
          height: ToolbarGrid.trayButton,
          child: NativeGlassMenuButton<double>(
            value: beautify?.cornerRadius ?? BeautifyMetrics.roundRadius,
            dense: true,
            flat: beautifyMenuFlat,
            items: {
              BeautifyMetrics.squareRadius: '直角',
              BeautifyMetrics.roundRadius: '圆角',
            },
            onChanged: beautify == null
                ? null
                : (value) => setState(
                    () => _beautify = beautify.copyWith(cornerRadius: value),
                  ),
          ),
        ),
      ],
    ];
    final strips = <String, Widget>{
      if (beautifyControls.isNotEmpty)
        'screenshot-beautify-row': captureRow(
          'screenshot-beautify-row',
          beautifyControls,
        ),
      if (_expandedRow == _ExpandedRow.ratio)
        'ratio-row': captureRow('ratio-row', [
          for (final preset in CropMetrics.ratios)
            captureButton(
              preset.label == '自由' ? '自由比例' : '比例 ${preset.label}',
              Text(
                preset.label,
                style: const TextStyle(fontSize: CropMetrics.ratioFontSize),
              ),
              () => _chooseRatio(preset.ratio),
              selected: _cropRatio == preset.ratio,
            ),
        ]),
      if (_recordingExpanded && _tool == ScreenshotTool.crop)
        'recording-targets-row': captureRow('recording-targets-row', [
          for (final target in const {
            CaptureTarget.region: ('当前选区', LucideIcons.crop),
            CaptureTarget.application: ('窗口', LucideIcons.layoutGrid),
            CaptureTarget.display: ('全屏', LucideIcons.monitor),
          }.entries)
            (() {
              final button = captureButton(
                target.value.$1,
                LineIcon(target.value.$2, size: 14),
                () => _selectRecordingTarget(target.key),
                selected: _recordingTarget == target.key,
              );
              return target.key == CaptureTarget.application
                  ? KeyedSubtree(
                      key: _buttonKeys.putIfAbsent(
                        'recording-target-application',
                        GlobalKey.new,
                      ),
                      child: button,
                    )
                  : button;
            })(),
          MenuAnchor(
              style: NativeGlassMenuPanel.anchorStyle,
              menuChildren: [
                NativeGlassMenuPanel(
                  children: [
                    for (final delay in RecordingOptions.delays)
                      NativeGlassMenuItem(
                        label: delay == 0 ? '不延时' : '延时 $delay 秒',
                        checked: delay == _recordingDelay,
                        onPressed: () => _saveRecordingOptions(
                          delay: delay,
                          clickEffectEnabled: _recordingClickEffectEnabled,
                        ),
                      ),
                    const Divider(height: 9, thickness: 1),
                    NativeGlassMenuItem(
                      label: '包含点击特效',
                      checked: _recordingClickEffectEnabled,
                      onPressed: _recordingTarget == CaptureTarget.application
                          ? null
                          : () => _saveRecordingOptions(
                              delay: _recordingDelay,
                              clickEffectEnabled: !_recordingClickEffectEnabled,
                            ),
                    ),
                  ],
                ),
              ],
              builder: (context, controller, _) => captureButton(
                _recordingDelay == 0 ? '录制选项' : '录制选项：延时 $_recordingDelay 秒',
                const LineIcon(LucideIcons.sliders, size: 14),
                () =>
                    controller.isOpen ? controller.close() : controller.open(),
                selected: controller.isOpen,
              ),
            ),
          captureButton(
            '实时翻译',
            const LineIcon(LucideIcons.captions, size: 14),
            () {
              setState(() => _liveTranslation = !_liveTranslation);
              unawaited(_syncLivePreview());
            },
            selected: _liveTranslation,
          ),
          captureButton(
            _liveExpanded ? '开始实时翻译' : '开始录制',
            const LineIcon(LucideIcons.circleDot, size: 14),
            _loadingApplications ||
                    (_recordingTarget == CaptureTarget.application &&
                        _recordingApplication == null)
                ? null
                : () => _prepareCapture(_recordingTarget, live: _liveExpanded),
          ),
          captureButton(
            _liveExpanded ? '取消实时翻译' : '取消录制',
            const LineIcon(LucideIcons.x, size: 14),
            () => setState(() {
              _expandedRow = null;
              unawaited(_syncRecordingPreview());
              unawaited(_syncLivePreview());
              _recordingApplication = null;
            }),
          ),
        ]),
      if (_recordingExpanded &&
          _tool == ScreenshotTool.crop &&
          _recordingTarget == CaptureTarget.application)
        'recording-applications-row': captureRow('recording-applications-row', [
          if (_loadingApplications)
            const SizedBox(
              width: ToolbarGrid.trayButton,
              height: ToolbarGrid.trayButton,
              child: LineIcon(LucideIcons.hourglass, size: 14),
            ),
          for (final app in _recordingApplications)
            captureButton(
              app['name'] as String,
              app['icon'] is Uint8List
                  ? Image.memory(
                      app['icon'] as Uint8List,
                      width: 14,
                      height: 14,
                    )
                  : const LineIcon(
                      LucideIcons.layoutGrid,
                      size: 14,
                      semanticLabel: '应用图标不可用',
                    ),
              _loadingApplications
                  ? null
                  : () {
                      setState(() => _recordingApplication = app);
                      unawaited(_syncRecordingPreview());
                    },
              selected:
                  _recordingApplication?['applicationID'] ==
                  app['applicationID'],
            ),
        ]),
    };
    final line = (dark ? Colors.white : Colors.black).withValues(alpha: 0.10);
    Widget separator() => Padding(
      padding: axis == Axis.horizontal
          ? const EdgeInsets.symmetric(horizontal: ToolbarGrid.traySeparatorGap)
          : const EdgeInsets.symmetric(vertical: ToolbarGrid.traySeparatorGap),
      child: Center(
        child: SizedBox(
          width: axis == Axis.horizontal ? 1 : ToolbarGrid.traySeparatorLength,
          height: axis == Axis.horizontal ? ToolbarGrid.traySeparatorLength : 1,
          child: ColoredBox(color: line),
        ),
      ),
    );

    Widget tray(_ToolbarLine row) {
      final strip = row.strip != null;
      final children = <Widget>[];
      for (final (index, group) in row.groups.indexed) {
        if (index > 0) children.add(separator());
        children.add(groupOf(group, compact: true));
      }
      final body = lifted(
        trayColor,
        ToolbarGrid.trayRadius,
        Padding(
          padding: const EdgeInsets.all(ToolbarGrid.trayPadding),
          child: strip
              ? strips[row.strip]!
              : Flex(
                  direction: axis,
                  mainAxisSize: MainAxisSize.min,
                  children: children,
                ),
        ),
      );
      final caret = row.caret! - ToolbarGrid.trayCaretWidth / 2;
      final pointer = Positioned(
        left: axis == Axis.horizontal ? caret : -ToolbarGrid.trayCaretHeight,
        top: axis == Axis.horizontal ? -ToolbarGrid.trayCaretHeight : caret,
        child: CustomPaint(
          size: axis == Axis.horizontal
              ? const Size(
                  ToolbarGrid.trayCaretWidth,
                  ToolbarGrid.trayCaretHeight,
                )
              : const Size(
                  ToolbarGrid.trayCaretHeight,
                  ToolbarGrid.trayCaretWidth,
                ),
          painter: _TrayCaretPainter(color: trayColor, axis: axis),
        ),
      );
      return Flex(
        direction: axis,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: axis == Axis.horizontal ? row.indent : null,
            height: axis == Axis.horizontal ? null : row.indent,
          ),
          Flexible(
            child: Stack(clipBehavior: Clip.none, children: [body, pointer]),
          ),
        ],
      );
    }

    final toolbar = Flex(
      key: const Key('screenshot-toolbar'),
      direction: cross,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: ToolbarGrid.lineGap,
      children: [
        for (final row in _toolbarLines(actions, perLine))
          SizedBox(
            width: axis == Axis.vertical ? _lineThickness(row) : null,
            height: axis == Axis.horizontal ? _lineThickness(row) : null,
            child: row.strip != null || _isTray(row)
                ? tray(row)
                : Flex(
                    direction: axis,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: ToolbarGrid.blockGap,
                    children: [for (final group in row.groups) groupOf(group)],
                  ),
          ),
      ],
    );
    final ghosts = [
      for (final ghost in _ghosts)
        (ghost: ghost, child: groupOf(ghost.group, ghost: true)),
    ];
    return AnimatedBuilder(
      animation: _toolbarGlide,
      builder: (context, child) =>
          Transform.translate(offset: _glideOffset, child: child),
      child: ghosts.isEmpty
          ? toolbar
          : Stack(
              clipBehavior: Clip.none,
              children: [
                toolbar,
                for (final (:ghost, :child) in ghosts)
                  AnimatedBuilder(
                    animation: _ghostMerge,
                    child: IgnorePointer(child: ExcludeSemantics(child: child)),
                    builder: (context, child) {
                      final t = _ghostMerge.value;
                      final target = Offset(
                        (_ghostTarget.width - ghost.size.width) / 2,
                        0,
                      );
                      final at = Offset.lerp(ghost.offset, target, t)!;
                      final blur =
                          MotionMetrics.blockSplitBlur * t.clamp(0.0, 1.0);
                      return Positioned(
                        key: ValueKey('ghost-${ghost.group.key}'),
                        left: at.dx,
                        top: at.dy,
                        child: Opacity(
                          opacity: (1 - t).clamp(0.0, 1.0),
                          child: Transform(
                            alignment: Alignment.topCenter,
                            transform: Matrix4.diagonal3Values(
                              1 +
                                  (_ghostTarget.width / ghost.size.width - 1) *
                                      t.clamp(0.0, 1.0),
                              1,
                              1,
                            ),
                            child: ImageFiltered(
                              enabled: blur > 0.01,
                              imageFilter: ui.ImageFilter.blur(
                                sigmaX: blur,
                                sigmaY: blur,
                              ),
                              child: child,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
              ],
            ),
    );
  }
}

class _EditorSurface extends StatefulWidget {
  const _EditorSurface({
    super.key,
    this.openedImage = false,
    this.imageScale,
    required this.channel,
    required this.document,
    required this.tool,
    required this.dragStart,
    required this.dragCurrent,
    required this.previewAnnotation,
    this.previewCrop,
    this.recordingWindows,
    this.recordingPreview = false,
    required this.pixelRatio,
    required this.brushCursor,
    required this.busy,
    required this.textInputOpen,
    required this.textController,
    required this.textFocus,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onTextTap,
    required this.onCropTap,
    required this.onStepTap,
    required this.ruler,
    required this.picker,
    required this.pickerColor,
    required this.onPickerHover,
    required this.onPickerTap,
    required this.cropSelected,
    required this.activeHandle,
    required this.onDoubleTap,
    required this.onDoubleTapDown,
    required this.toolbarBuilder,
    this.toolbarSafeArea,
    this.displaySize,
    required this.lines,
    this.beautify,
    required this.toolbarRect,
    required this.ocrOverlays,
    this.selectedText,
    this.sourceImage,
    this.selectedShape,
  });

  final bool openedImage;
  final double? imageScale;
  final Rect? toolbarSafeArea;
  final Size? displaySize;

  final ({
    List<double> lengths,
    double grouped,
    double blocks,
    double thickness,
  })
  Function(int perLine)
  lines;

  final BeautifyStyle? beautify;
  final ValueNotifier<Rect> toolbarRect;
  final MethodChannel channel;
  final EditDocument document;
  final ScreenshotTool tool;
  final Offset? dragStart;
  final Offset? dragCurrent;
  final EditAnnotation? previewAnnotation;
  final Rect? previewCrop;

  final List<Rect>? recordingWindows;
  final bool recordingPreview;
  final double pixelRatio;

  final MouseCursor brushCursor;
  final bool busy;
  final bool textInputOpen;
  final TextEditingController textController;
  final FocusNode textFocus;
  final EditAnnotation? selectedText;
  final ui.Image? sourceImage;
  final EditAnnotation? selectedShape;
  final ValueChanged<Offset> onDragStart;
  final ValueChanged<Offset> onDragUpdate;
  final VoidCallback onDragEnd;
  final ValueChanged<Offset> onTextTap;
  final ValueChanged<Offset> onCropTap;

  final ValueChanged<Offset> onStepTap;

  final ({Offset start, Offset end})? ruler;
  final ValueListenable<Offset?> picker;
  final Color? Function(Offset point) pickerColor;

  final ValueChanged<Offset?> onPickerHover;
  final ValueChanged<Offset> onPickerTap;
  final bool cropSelected;
  final BoxHandle? activeHandle;
  final VoidCallback onDoubleTap;
  final ValueChanged<Offset> onDoubleTapDown;

  final Widget Function(
    BuildContext context,
    Axis axis,
    int perLine,
    ValueChanged<Offset> onToolbarDrag,
  )
  toolbarBuilder;
  final List<_OcrOverlay> ocrOverlays;

  @override
  State<_EditorSurface> createState() => _EditorSurfaceState();
}

class _EditorSurfaceState extends State<_EditorSurface> {
  final _vertical = ScrollController();
  final _horizontal = ScrollController();
  Offset _toolbarDragOffset = Offset.zero;
  Rect? _lastCropRect;

  void _onToolbarDrag(Offset delta, Rect baseRect, Rect safeBounds) {
    final next = baseRect.shift(_toolbarDragOffset + delta);
    final maxLeft = math.max(safeBounds.left, safeBounds.right - next.width);
    final maxTop = math.max(safeBounds.top, safeBounds.bottom - next.height);
    final clampedLeft = next.left.clamp(safeBounds.left, maxLeft).toDouble();
    final clampedTop = next.top.clamp(safeBounds.top, maxTop).toDouble();
    setState(() {
      _toolbarDragOffset = Offset(
        clampedLeft - baseRect.left,
        clampedTop - baseRect.top,
      );
    });
  }

  @override
  void dispose() {
    _vertical.dispose();
    _horizontal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([_vertical, _horizontal]),
      builder: (context, _) => LayoutBuilder(
        builder: (context, constraints) {
          final cropRect = widget.document.cropRect;
          if (_lastCropRect != cropRect) {
            _lastCropRect = cropRect;
            _toolbarDragOffset = Offset.zero;
          }
          final safeBounds =
              widget.toolbarSafeArea == null || widget.displaySize == null
              ? (Offset.zero & constraints.biggest)
              : Rect.fromLTRB(
                  widget.toolbarSafeArea!.left *
                      constraints.maxWidth /
                      widget.displaySize!.width,
                  widget.toolbarSafeArea!.top *
                      constraints.maxHeight /
                      widget.displaySize!.height,
                  widget.toolbarSafeArea!.right *
                      constraints.maxWidth /
                      widget.displaySize!.width,
                  widget.toolbarSafeArea!.bottom *
                      constraints.maxHeight /
                      widget.displaySize!.height,
                );
          final imageSize = widget.document.imageSize;
          final imageScale = widget.imageScale;
          final resultSize = imageScale == null ? null : imageSize / imageScale;
          final canvasPad = widget.openedImage
              ? GlassMetrics.resultCanvasPadding
              : 0.0;
          final paddedWidth = resultSize == null
              ? 0.0
              : resultSize.width + canvasPad * 2;
          final paddedHeight = resultSize == null
              ? 0.0
              : resultSize.height + canvasPad * 2;
          final hOffset = _horizontal.hasClients ? _horizontal.offset : 0.0;
          final vOffset = _vertical.hasClients ? _vertical.offset : 0.0;
          final resultRect = resultSize == null
              ? null
              : Rect.fromLTWH(
                  paddedWidth <= constraints.maxWidth
                      ? (constraints.maxWidth - resultSize.width) / 2
                      : canvasPad - hOffset,
                  widget.openedImage
                      ? (paddedHeight <= constraints.maxHeight
                            ? (constraints.maxHeight - resultSize.height) / 2
                            : canvasPad - vOffset)
                      : -vOffset,
                  resultSize.width,
                  resultSize.height,
                );
          ScreenshotEditorLayout placeFor(
            ({
              List<double> lengths,
              double grouped,
              double blocks,
              double thickness,
            })
            lines,
          ) => ScreenshotEditorLayout.place(
            viewport: constraints.biggest,
            imageRect: resultRect,
            available:
                widget.toolbarSafeArea == null || widget.displaySize == null
                ? null
                : Rect.fromLTRB(
                    widget.toolbarSafeArea!.left *
                        constraints.maxWidth /
                        widget.displaySize!.width,
                    widget.toolbarSafeArea!.top *
                        constraints.maxHeight /
                        widget.displaySize!.height,
                    widget.toolbarSafeArea!.right *
                        constraints.maxWidth /
                        widget.displaySize!.width,
                    widget.toolbarSafeArea!.bottom *
                        constraints.maxHeight /
                        widget.displaySize!.height,
                  ),
            image: imageSize,
            crop: widget.document.cropRect,
            toolbarLength: [...lines.lengths, 32.0].reduce(math.max),
            centerLength: lines.blocks,
            thickness: math.max(lines.thickness, ToolbarGrid.blockThickness),
          );
          var perLine = ToolbarGrid.groupsPerLine;
          var lines = widget.lines(perLine);
          var layout = placeFor(lines);
          final length = layout.axis == Axis.horizontal
              ? layout.toolbar.width
              : layout.toolbar.height;
          if (length < lines.grouped) {
            perLine = 1;
            lines = widget.lines(perLine);
            layout = placeFor(lines);
          }
          final shiftedToolbar = layout.toolbar.shift(_toolbarDragOffset);
          final maxToolbarLeft = math.max(
            safeBounds.left,
            safeBounds.right - shiftedToolbar.width,
          );
          final maxToolbarTop = math.max(
            safeBounds.top,
            safeBounds.bottom - shiftedToolbar.height,
          );
          final toolbarRect = Rect.fromLTWH(
            shiftedToolbar.left.clamp(safeBounds.left, maxToolbarLeft).toDouble(),
            shiftedToolbar.top.clamp(safeBounds.top, maxToolbarTop).toDouble(),
            shiftedToolbar.width,
            shiftedToolbar.height,
          );
          if (widget.toolbarRect.value != toolbarRect) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && widget.toolbarRect.value != toolbarRect) {
                widget.toolbarRect.value = toolbarRect;
              }
            });
          }
          final fitted = layout.canvas;
          Rect cropDisplay = mapRectToFitted(
            widget.previewCrop ?? widget.document.cropRect,
            imageSize,
            fitted,
          );
          if (widget.previewCrop == null &&
              widget.tool == ScreenshotTool.crop &&
              widget.dragStart != null &&
              widget.dragCurrent != null) {
            cropDisplay = mapRectToFitted(
              Rect.fromPoints(widget.dragStart!, widget.dragCurrent!),
              imageSize,
              fitted,
            );
          }
          Offset toImage(Offset local) {
            final x = (local.dx / fitted.width) * imageSize.width;
            final y = (local.dy / fitted.height) * imageSize.height;
            return Offset(
              x.clamp(0, imageSize.width),
              y.clamp(0, imageSize.height),
            );
          }

          final singleTapTool = const {
            ScreenshotTool.text,
            ScreenshotTool.step,
            ScreenshotTool.eyedropper,
            ScreenshotTool.ruler,
          }.contains(widget.tool);
          final canvasContent = MouseRegion(
            opaque: false,
            onHover: widget.tool == ScreenshotTool.eyedropper
                ? (event) => widget.onPickerHover(toImage(event.localPosition))
                : null,
            onExit: (_) => widget.onPickerHover(null),
            child: GestureDetector(
              key: const Key('screenshot-canvas'),
              dragStartBehavior: DragStartBehavior.down,
              behavior: HitTestBehavior.opaque,
              onDoubleTapDown:
                  widget.textInputOpen || widget.busy || singleTapTool
                  ? null
                  : (details) =>
                        widget.onDoubleTapDown(toImage(details.localPosition)),
              onDoubleTap: widget.textInputOpen || widget.busy || singleTapTool
                  ? null
                  : widget.onDoubleTap,
              onPanStart: widget.busy
                  ? null
                  : (details) =>
                        widget.onDragStart(toImage(details.localPosition)),
              onPanUpdate: widget.busy || widget.textInputOpen
                  ? null
                  : (details) =>
                        widget.onDragUpdate(toImage(details.localPosition)),
              onPanEnd: widget.busy || widget.textInputOpen
                  ? null
                  : (_) => widget.onDragEnd(),
              onTapUp: !widget.busy
                  ? (details) {
                      final point = toImage(details.localPosition);
                      if (widget.textInputOpen) {
                        widget.onTextTap(point);
                      } else if (widget.tool == ScreenshotTool.crop) {
                        widget.onCropTap(point);
                      } else if (widget.tool == ScreenshotTool.text ||
                          widget.tool == ScreenshotTool.cursor) {
                        widget.onTextTap(point);
                      } else if (widget.tool == ScreenshotTool.step) {
                        widget.onStepTap(point);
                      } else if (widget.tool == ScreenshotTool.eyedropper) {
                        widget.onPickerTap(point);
                      }
                    }
                  : null,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  RawImage(
                    image: widget.document.source,
                    fit: BoxFit.fill,
                    filterQuality: FilterQuality.none,
                    isAntiAlias: false,
                  ),
                  RepaintBoundary(
                    child: CustomPaint(
                      painter: _OverlayPainter(
                        sourceImage: widget.sourceImage,
                        stickers: widget.document.stickerImages,
                        pixelRatio: widget.pixelRatio,
                        selectedShape: widget.selectedShape,
                        annotations: widget.document.annotations,
                        previewAnnotation: widget.previewAnnotation,
                        imageSize: imageSize,
                        accent: NativeGlassTheme.accentOf(context),
                      ),
                    ),
                  ),
                  ValueListenableBuilder<Offset?>(
                    valueListenable: widget.picker,
                    builder: (context, picker, _) =>
                        widget.ruler == null && picker == null
                        ? const SizedBox.shrink()
                        : MeasureLayer(
                            imageSize: imageSize,
                            ruler: widget.ruler,
                            picker: picker,
                            pickerColor: picker == null
                                ? null
                                : widget.pickerColor(picker),
                          ),
                  ),
                  ...[
                    for (final overlay in widget.ocrOverlays)
                      Positioned.fromRect(
                        key: ValueKey(overlay.rect),
                        rect: mapRectToFitted(
                          overlay.rect,
                          imageSize,
                          Offset.zero & fitted.size,
                        ).intersect(Offset.zero & fitted.size),
                        child: IgnorePointer(
                          child: ColoredBox(
                            color: const Color(0xCCFFFFFF),
                            child: _FitText(overlay.text),
                          ),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          );

          return _CornerCursor(
            cursorFor: (local) {
              if (widget.textInputOpen) return SystemMouseCursors.text;
              if (widget.activeHandle != null) {
                return cursorForEditHandle(
                  widget.activeHandle,
                  plusWhenIdle: false,
                  channel: widget.channel,
                );
              }
              final point = toImage(local - fitted.topLeft);
              final pad = GlassMetrics.cropHandleHitRadius * widget.pixelRatio;
              if (widget.tool == ScreenshotTool.cursor ||
                  widget.tool == ScreenshotTool.text) {
                final box =
                    (widget.previewAnnotation ?? widget.selectedText)?.bounds;
                final handle = box == null
                    ? null
                    : hitBoxHandle(
                        BoxFrame(box),
                        point,
                        pad: pad,
                        edgePad:
                            GlassMetrics.cropEdgeHitRadius * widget.pixelRatio,
                      )?.widthOnly;
                if (handle != null && handle != BoxHandle.move) {
                  return cursorForEditHandle(
                    handle,
                    plusWhenIdle: false,
                    channel: widget.channel,
                  );
                }
                for (final annotation in widget.document.annotations.reversed) {
                  if (annotation.kind == AnnotationKind.text &&
                      annotation.bounds.inflate(4).contains(point)) {
                    return cursorForEditHandle(
                      hitBoxHandle(
                            BoxFrame(annotation.bounds),
                            point,
                            pad: pad,
                            edgePad:
                                GlassMetrics.cropEdgeHitRadius *
                                widget.pixelRatio,
                          )?.widthOnly ??
                          BoxHandle.move,
                      plusWhenIdle: false,
                      channel: widget.channel,
                    );
                  }
                }
                if (widget.tool == ScreenshotTool.text) {
                  return SystemMouseCursors.basic;
                }
              }
              if (widget.tool == ScreenshotTool.crop ||
                  widget.tool == ScreenshotTool.cursor) {
                if (widget.tool == ScreenshotTool.crop &&
                    !widget.cropSelected) {
                  return SystemMouseCursors.precise;
                }
                final handle = hitBoxHandle(
                  BoxFrame(widget.previewCrop ?? widget.document.cropRect),
                  point,
                  pad: pad,
                  edgePad: GlassMetrics.cropEdgeHitRadius * widget.pixelRatio,
                );
                if (handle != null) {
                  return cursorForEditHandle(
                    handle,
                    plusWhenIdle: false,
                    channel: widget.channel,
                  );
                }
                return widget.tool == ScreenshotTool.crop
                    ? SystemMouseCursors.precise
                    : SystemMouseCursors.basic;
              }
              if (widget.tool == ScreenshotTool.brush) {
                return widget.brushCursor;
              }
              if (widget.tool == ScreenshotTool.eyedropper ||
                  widget.tool == ScreenshotTool.ruler) {
                return SystemMouseCursors.precise;
              }
              return SystemMouseCursors.basic;
            },
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (resultSize == null)
                  Positioned.fromRect(rect: fitted, child: canvasContent)
                else
                  Positioned.fill(
                    child: Scrollbar(
                      controller: _vertical,
                      thumbVisibility: true,
                      child: SingleChildScrollView(
                        controller: _vertical,
                        child: SingleChildScrollView(
                          controller: _horizontal,
                          scrollDirection: Axis.horizontal,
                          child: SizedBox(
                            width: math.max(
                              constraints.maxWidth,
                              paddedWidth,
                            ),
                            height: math.max(
                              constraints.maxHeight,
                              paddedHeight,
                            ),
                            child: Align(
                              alignment: widget.openedImage
                                  ? Alignment.center
                                  : Alignment.topCenter,
                              child: Padding(
                                padding: EdgeInsets.all(canvasPad),
                                child: widget.openedImage
                                    ? ResultMediaFrame(
                                        child: SizedBox(
                                          width: resultSize.width,
                                          height: resultSize.height,
                                          child: canvasContent,
                                        ),
                                      )
                                    : SizedBox(
                                        width: resultSize.width,
                                        height: resultSize.height,
                                        child: canvasContent,
                                      ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                if (!widget.openedImage)
                  IgnorePointer(
                    child: CustomPaint(
                      size: constraints.biggest,
                      painter: _DimPainter(
                        accent: NativeGlassTheme.accentOf(context),
                        recordingPreview: widget.recordingPreview,
                        cropDisplay: cropDisplay,
                        beautify: widget.beautify,
                        beautifyUnit:
                            fitted.width / (imageSize.width / widget.pixelRatio),
                        showHandles: widget.cropSelected,
                        windows: widget.recordingWindows
                            ?.map(
                              (rect) => mapRectToFitted(rect, imageSize, fitted),
                            )
                            .toList(),
                      ),
                    ),
                  ),
                if (!widget.openedImage &&
                    (widget.tool == ScreenshotTool.crop ||
                        widget.tool == ScreenshotTool.cursor) &&
                    widget.recordingWindows == null &&
                    !widget.textInputOpen)
                  Positioned(
                    left:
                        cropDisplay.left +
                        (cropDisplay.top -
                                    CropMetrics.labelGap -
                                    CropMetrics.labelHeight <
                                fitted.top
                            ? CropMetrics.labelGap
                            : 0),
                    top:
                        cropDisplay.top -
                                CropMetrics.labelGap -
                                CropMetrics.labelHeight <
                            fitted.top
                        ? cropDisplay.top + CropMetrics.labelGap
                        : cropDisplay.top -
                              CropMetrics.labelGap -
                              CropMetrics.labelHeight,
                    child: IgnorePointer(
                      child: Container(
                        key: const Key('crop-size-label'),
                        height: CropMetrics.labelHeight,
                        padding: const EdgeInsets.symmetric(
                          horizontal: CropMetrics.labelPadding,
                        ),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: CropMetrics.labelBackground,
                          borderRadius: BorderRadius.circular(
                            CropMetrics.labelRadius,
                          ),
                        ),
                        child: Text(
                          '${(widget.previewCrop ?? widget.document.cropRect).width.round()} × '
                          '${(widget.previewCrop ?? widget.document.cropRect).height.round()}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: CropMetrics.labelFontSize,
                            fontFeatures: [ui.FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ),
                  ),
                if (widget.textInputOpen)
                  Positioned.fromRect(
                    rect: mapRectToFitted(
                      (widget.previewAnnotation ?? widget.selectedText)
                              ?.bounds ??
                          Rect.fromLTWH(
                            widget.dragStart?.dx ?? 0,
                            widget.dragStart?.dy ?? 0,
                            ScreenshotDefaults.textBoxWidth * widget.pixelRatio,
                            0,
                          ),
                      imageSize,
                      fitted,
                    ),
                    child: GestureDetector(
                      onDoubleTap: () {},
                      child: Material(
                        color: Colors.transparent,
                        child: NativeGlassSurface(
                          material: true,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.surface
                                  .withValues(alpha: 0.72),
                              borderRadius: BorderRadius.circular(
                                GlassMetrics.space4,
                              ),
                            ),
                            child: TextField(
                              key: const Key('screenshot-text-field'),
                              controller: widget.textController,
                              focusNode: widget.textFocus,
                              autofocus: true,
                              maxLines: null,
                              textInputAction: TextInputAction.newline,
                              style: TextStyle(
                                color:
                                    (widget.previewAnnotation ??
                                            widget.selectedText)
                                        ?.color ??
                                    ScreenshotDefaults.strokeColor,
                                fontSize:
                                    ((widget.previewAnnotation ??
                                                widget.selectedText)
                                            ?.fontSize ??
                                        ScreenshotDefaults.fontSize) *
                                    fitted.width /
                                    imageSize.width,
                              ),
                              cursorColor: NativeGlassTheme.accentOf(context),
                              decoration: InputDecoration.collapsed(
                                hintText: '输入文字',
                                hintStyle: TextStyle(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                if (!widget.openedImage && lines.lengths.isNotEmpty)
                  Positioned.fromRect(
                    rect: toolbarRect,
                    child: Visibility(
                      visible: widget.dragStart == null || widget.textInputOpen,
                      maintainState: true,
                      maintainAnimation: true,
                      child: widget.toolbarBuilder(
                        context,
                        layout.axis,
                        perLine,
                        (delta) =>
                            _onToolbarDrag(delta, layout.toolbar, safeBounds),
                      ),
                    ),
                  ),
                if (widget.selectedText != null ||
                    (widget.previewAnnotation?.kind == AnnotationKind.text))
                  IgnorePointer(
                    child: CustomPaint(
                      size: constraints.biggest,
                      painter: _TextBoxPainter(
                        accent: NativeGlassTheme.accentOf(context),
                        box: mapRectToFitted(
                          (widget.previewAnnotation ?? widget.selectedText)!
                              .bounds,
                          imageSize,
                          fitted,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _CornerCursor extends StatefulWidget {
  const _CornerCursor({required this.cursorFor, required this.child});

  final MouseCursor Function(Offset local) cursorFor;
  final Widget child;

  @override
  State<_CornerCursor> createState() => _CornerCursorState();
}

class _CornerCursorState extends State<_CornerCursor> {
  MouseCursor _cursor = SystemMouseCursors.basic;
  Offset? _position;

  @override
  void didUpdateWidget(covariant _CornerCursor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_position != null) _cursor = widget.cursorFor(_position!);
  }

  void _update(Offset position) {
    _position = position;
    final next = widget.cursorFor(position);
    if (next != _cursor) setState(() => _cursor = next);
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      opaque: false,
      cursor: _cursor,
      onEnter: (event) => _update(event.localPosition),
      onHover: (event) => _update(event.localPosition),
      onExit: (_) {
        _position = null;
        if (_cursor != SystemMouseCursors.basic) {
          setState(() => _cursor = SystemMouseCursors.basic);
        }
      },
      child: Listener(
        onPointerMove: (event) => _update(event.localPosition),
        child: widget.child,
      ),
    );
  }
}

class _TextBoxPainter extends CustomPainter {
  _TextBoxPainter({required this.box, required this.accent});

  final Rect box;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    _DimPainter(
      cropDisplay: box,
      showHandles: true,
      accent: accent,
    ).paintHandles(canvas);
  }

  @override
  bool shouldRepaint(covariant _TextBoxPainter oldDelegate) =>
      oldDelegate.box != box || oldDelegate.accent != accent;
}

class _DimPainter extends CustomPainter {
  _DimPainter({
    required this.cropDisplay,
    required this.showHandles,
    required this.accent,
    this.windows,
    this.recordingPreview = false,
    this.beautify,
    this.beautifyUnit = 1,
  });

  final BeautifyStyle? beautify;
  final double beautifyUnit;

  final List<Rect>? windows;
  final bool recordingPreview;

  final Rect cropDisplay;
  final bool showHandles;

  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final outer = Path()..addRect(Offset.zero & size);
    var visible = Path()..addRect(cropDisplay);
    if (windows != null) {
      visible = Path();
      for (final rect in windows!) {
        visible = Path.combine(
          PathOperation.union,
          visible,
          Path()..addRect(rect),
        );
      }
    }
    final shade = Path.combine(PathOperation.difference, outer, visible);
    canvas.drawPath(shade, Paint()..color = const Color(0x99000000));
    if (beautify != null && windows == null) {
      paintBeautifyBackdrop(canvas, cropDisplay, beautify!, unit: beautifyUnit);
    }
    if (windows != null) {
      final border = Paint()
        ..color = accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1;
      for (final rect in windows!) {
        canvas.drawRect(rect, border);
      }
    }
    paintHandles(canvas);
  }

  void paintHandles(Canvas canvas) {
    final border = Paint()
      ..color = recordingPreview ? accent : Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawRect(cropDisplay, border);
    if (!showHandles) return;
    const handle = GlassMetrics.cropHandle;
    final fill = Paint()..color = recordingPreview ? accent : Colors.white;
    for (final point in <Offset>[
      cropDisplay.topLeft,
      cropDisplay.topCenter,
      cropDisplay.topRight,
      cropDisplay.centerLeft,
      cropDisplay.centerRight,
      cropDisplay.bottomLeft,
      cropDisplay.bottomCenter,
      cropDisplay.bottomRight,
    ]) {
      canvas.drawCircle(point, handle / 2, fill);
      canvas.drawCircle(
        point,
        handle / 2,
        Paint()
          ..color = accent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _DimPainter oldDelegate) =>
      oldDelegate.recordingPreview != recordingPreview ||
      oldDelegate.beautify != beautify ||
      oldDelegate.beautifyUnit != beautifyUnit ||
      oldDelegate.windows != windows ||
      oldDelegate.cropDisplay != cropDisplay ||
      oldDelegate.showHandles != showHandles ||
      oldDelegate.accent != accent;
}

class _OverlayPainter extends CustomPainter {
  _OverlayPainter({
    required this.annotations,
    required this.previewAnnotation,
    required this.imageSize,
    required this.accent,
    this.sourceImage,
    this.selectedShape,
    this.stickers = const {},
    this.pixelRatio = 1,
  });

  final List<EditAnnotation> annotations;
  final EditAnnotation? previewAnnotation;
  final Size imageSize;
  final Color accent;
  final ui.Image? sourceImage;
  final EditAnnotation? selectedShape;

  final Map<String, ui.Image> stickers;
  final double pixelRatio;

  @override
  void paint(Canvas canvas, Size size) {
    final scaleX = size.width / imageSize.width;
    final scaleY = size.height / imageSize.height;
    canvas.save();
    canvas.scale(scaleX, scaleY);
    final draggingId = previewAnnotation?.id;
    final numbers = stepNumbers(annotations);
    for (final annotation in annotations) {
      if (draggingId != null &&
          draggingId != 'preview' &&
          annotation.id == draggingId) {
        continue;
      }
      EditDocument.paintAnnotation(
        canvas,
        annotation,
        sourceImage: sourceImage,
        stepNumber: numbers[annotation.id],
        stickers: stickers,
      );
    }
    if (previewAnnotation != null) {
      EditDocument.paintAnnotation(
        canvas,
        previewAnnotation!,
        sourceImage: sourceImage,
        stepNumber: numbers.length + 1,
        stickers: stickers,
      );
    }
    final selected = previewAnnotation?.id == selectedShape?.id
        ? previewAnnotation
        : selectedShape;
    if (selected != null) {
      final stroke = Paint()
        ..color = accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1 / scaleX;
      if (selected.kind == AnnotationKind.sticker) {
        _paintStickerSelection(canvas, selected, stroke, scaleX);
      } else {
        canvas.drawRect(selected.bounds.inflate(2), stroke);
      }
    }
    canvas.restore();
  }

  void _paintStickerSelection(
    Canvas canvas,
    EditAnnotation sticker,
    Paint stroke,
    double scale,
  ) {
    final rect = sticker.bounds;
    final center = rect.center;
    final handle = GlassMetrics.cropHandle / scale;
    final knob = StickerMetrics.rotateHandle / scale;
    final knobCenter = Offset(
      center.dx,
      rect.top - StickerMetrics.rotateDistance * pixelRatio,
    );
    final fill = Paint()..color = const Color(0xFFFFFFFF);
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(sticker.rotation);
    canvas.translate(-center.dx, -center.dy);
    canvas.drawRect(rect, stroke);
    for (final point in [
      rect.topLeft,
      rect.topCenter,
      rect.topRight,
      rect.centerRight,
      rect.bottomRight,
      rect.bottomCenter,
      rect.bottomLeft,
      rect.centerLeft,
    ]) {
      final square = Rect.fromCenter(
        center: point,
        width: handle,
        height: handle,
      );
      canvas.drawRect(square, fill);
      canvas.drawRect(square, stroke);
    }
    canvas.drawLine(rect.topCenter, knobCenter, stroke);
    canvas.drawCircle(knobCenter, knob / 2, fill);
    canvas.drawCircle(knobCenter, knob / 2, stroke);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _OverlayPainter oldDelegate) {
    return oldDelegate.annotations != annotations ||
        oldDelegate.previewAnnotation != previewAnnotation ||
        oldDelegate.selectedShape != selectedShape ||
        oldDelegate.sourceImage != sourceImage ||
        oldDelegate.pixelRatio != pixelRatio ||
        oldDelegate.imageSize != imageSize ||
        oldDelegate.accent != accent;
  }
}

typedef _ToolbarCells = ({String key, List<String?> cells, int? modifiers});

typedef _ToolbarLine = ({
  List<_ToolbarCells> groups,
  String? strip,
  String? anchor,
  double indent,
  double? caret,
});

typedef _Strip = ({int count, String anchor, Map<String, int> hosts});

class _OcrOverlay {
  const _OcrOverlay({required this.text, required this.rect});

  factory _OcrOverlay.fromMap(Map<Object?, Object?> map, Offset origin) =>
      _OcrOverlay(
        text: map['text'] as String,
        rect: Rect.fromLTWH(
          origin.dx + (map['x'] as num).toDouble(),
          origin.dy + (map['y'] as num).toDouble(),
          (map['width'] as num).toDouble(),
          (map['height'] as num).toDouble(),
        ),
      );

  final String text;
  final Rect rect;
}

const _overlayTextStyle = TextStyle(
  color: Colors.black,
  fontWeight: FontWeight.w600,
);

double fitOverlayFontSize({
  required String text,
  required Size box,
  required TextStyle style,
}) {
  var low = 1.0;
  var high = math.max(1.0, box.height);
  var best = low;
  final painter = TextPainter(
    textAlign: TextAlign.center,
    textDirection: TextDirection.ltr,
  );
  while (high - low > 0.5) {
    final size = (low + high) / 2;
    painter
      ..text = TextSpan(
        text: text,
        style: style.copyWith(fontSize: size),
      )
      ..layout(maxWidth: box.width);
    if (painter.height <= box.height + 0.5) {
      best = size;
      low = size;
    } else {
      high = size;
    }
  }
  painter.dispose();
  return best;
}

class _FitText extends StatelessWidget {
  const _FitText(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final box = constraints.biggest;
      if (box.width <= 1 || box.height <= 1) return const SizedBox.shrink();
      final style = DefaultTextStyle.of(context).style.merge(_overlayTextStyle);
      return Center(
        child: CharReveal(
          text: text,
          style: style.copyWith(
            fontSize: fitOverlayFontSize(text: text, box: box, style: style),
          ),
          builder: (context, span) => Text.rich(
            span,
            textAlign: TextAlign.center,
            textScaler: TextScaler.noScaling,
          ),
        ),
      );
    },
  );
}

class _TrayCaretPainter extends CustomPainter {
  const _TrayCaretPainter({required this.color, required this.axis});

  final Color color;
  final Axis axis;

  @override
  void paint(Canvas canvas, Size size) {
    final path = axis == Axis.horizontal
        ? (Path()
            ..moveTo(0, size.height)
            ..lineTo(size.width / 2, 0)
            ..lineTo(size.width, size.height)
            ..close())
        : (Path()
            ..moveTo(size.width, 0)
            ..lineTo(0, size.height / 2)
            ..lineTo(size.width, size.height)
            ..close());
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_TrayCaretPainter old) =>
      old.color != color || old.axis != axis;
}
