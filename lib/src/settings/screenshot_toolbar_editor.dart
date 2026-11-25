import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../common/widgets/line_icon.dart';
import '../common/constants/glass_metrics.dart';
import '../common/constants/screenshot_actions.dart';
import '../common/constants/toolbar_grid.dart';
import '../common/widgets/native_glass.dart';
import 'screenshot_toolbar_preferences.dart';

class ScreenshotToolbarEditor extends StatefulWidget {
  const ScreenshotToolbarEditor({
    super.key,
    required this.value,
    required this.onChanged,
    this.reserved = const {},
    this.systemSlots = const {},
  });
  final ScreenshotToolbarPreferences value;
  final ValueChanged<ScreenshotToolbarPreferences> onChanged;

  final Map<({int modifiers, int digit}), String> reserved;

  final Set<({int modifiers, int digit})> systemSlots;

  static const cellWidth = 64.0;
  static const cellHeight = 64.0;
  static const cellGap = 4.0;
  static const headerWidth = 72.0;
  static const headerGap = 8.0;
  static const rowGap = 8.0;
  static const gridWidth =
      headerWidth +
      headerGap +
      ToolbarGrid.slots * cellWidth +
      (ToolbarGrid.slots - 1) * cellGap;

  static const headerRowHeight = 20.0;
  static const labelFont = 11.0;
  static const noteFont = 11.0;
  static const eyeIcon = 14.0;
  static const eyeHit = GlassMetrics.minTouchTarget;

  static const childRowHeight = 40.0;

  static Color conflictColor(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? const Color(0xFFFF6961)
      : const Color(0xFFB3261E);

  static const cellFillLight = Color(0xFFFFFFFF);
  static const cellFillDark = Color(0xFF2C2C2E);
  static const cellLineLight = Color(0x1A000000);
  static const cellLineDark = Color(0x1AFFFFFF);
  static const hairline = 0.5;
  static const selectedBorder = 1.5;

  static ({Color fill, Color line}) cellColors(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? (fill: cellFillDark, line: cellLineDark)
      : (fill: cellFillLight, line: cellLineLight);

  static const draggingOpacity = 0.6;
  static const targetBorder = 2.0;

  @override
  State<ScreenshotToolbarEditor> createState() =>
      _ScreenshotToolbarEditorState();
}

typedef _Slot = ({int column, int slot});

class _ScreenshotToolbarEditorState extends State<ScreenshotToolbarEditor> {
  late ScreenshotToolbarPreferences _value = widget.value;
  String? _error;

  String? _selected;

  final Map<String, FocusNode> _handles = {};

  final Map<int, FocusNode> _columnHandles = {};

  @override
  void dispose() {
    for (final node in [..._handles.values, ..._columnHandles.values]) {
      node.dispose();
    }
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ScreenshotToolbarEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != oldWidget.value) _value = widget.value;
  }

  void _submit(ScreenshotToolbarPreferences next) {
    try {
      next.validate();
      setState(() {
        _value = next;
        _error = null;
      });
      widget.onChanged(next);
    } on FormatException catch (error) {
      setState(() => _error = error.message);
    }
  }

  _Slot? _slotOf(String id) {
    for (final (column, value) in _value.columns.indexed) {
      final slot = value.slots.indexOf(id);
      if (slot >= 0) return (column: column, slot: slot);
    }
    return null;
  }

  Map<String, List<String>> _childrenCopy() => {
    for (final entry in _value.children.entries) entry.key: [...entry.value],
  };

  bool _canBeChild(String id) => (_value.children[id] ?? const []).isEmpty;

  ScreenshotToolbarPreferences? _placeInSlot(String id, _Slot target) {
    final columns = [..._value.columns];
    final children = _childrenCopy();
    final occupant = columns[target.column].slots[target.slot];
    if (occupant == id) return null;
    final from = _slotOf(id);
    final parent = _value.parentOf(id);
    if (from != null) {
      columns[from.column] = columns[from.column].withSlot(from.slot, occupant);
    } else {
      final siblings = children[parent]!;
      final index = siblings.indexOf(id);
      siblings.removeAt(index);
      if (occupant != null) {
        if (occupant == parent || !_canBeChild(occupant)) return null;
        siblings.insert(index, occupant);
      }
      if (siblings.isEmpty) children.remove(parent);
    }
    columns[target.column] = columns[target.column].withSlot(target.slot, id);
    return _value.copyWith(columns: columns, children: children);
  }

  ScreenshotToolbarPreferences? _placeAsChild(
    String id,
    String parent,
    int index,
  ) {
    if (id == parent || !_canBeChild(id)) return null;
    final columns = [..._value.columns];
    final children = _childrenCopy();
    final from = _slotOf(id);
    var position = index;
    if (from != null) {
      columns[from.column] = columns[from.column].withSlot(from.slot, null);
    } else {
      final siblings = children[_value.parentOf(id)]!;
      final old = siblings.indexOf(id);
      siblings.removeAt(old);
      if (_value.parentOf(id) == parent && old < position) position -= 1;
      if (siblings.isEmpty) children.remove(_value.parentOf(id));
    }
    final list = children[parent] ??= [];
    list.insert(position.clamp(0, list.length), id);
    return _value.copyWith(columns: columns, children: children);
  }

  void _moveByKey(String id, int dColumn, int dSlot) {
    final from = _slotOf(id)!;
    final column = from.column + dColumn;
    final slot = from.slot + dSlot;
    if (column < 0 ||
        column >= _value.columns.length ||
        slot < 0 ||
        slot >= ToolbarGrid.slots) {
      return;
    }
    final targetSlot = (
      modifiers: _value.columns[column].modifiers,
      digit: slot + 1,
    );
    if (widget.reserved.containsKey(targetSlot)) {
      setState(
        () => _error = '该格位已被全局快捷键“${widget.reserved[targetSlot]}”占用，无法移入。',
      );
      return;
    }
    final next = _placeInSlot(id, (column: column, slot: slot));
    if (next == null) return;
    _submit(next);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _handles[id]?.requestFocus(),
    );
  }

  void _shiftChild(String id, int delta) {
    final parent = _value.parentOf(id)!;
    final siblings = [..._value.children[parent]!];
    final index = siblings.indexOf(id) + delta;
    if (index < 0 || index >= siblings.length) return;
    siblings
      ..remove(id)
      ..insert(index, id);
    _submit(_value.copyWith(children: _childrenCopy()..[parent] = siblings));
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _handles[id]?.requestFocus(),
    );
  }

  _Slot? _firstAvailableSlot() {
    for (final (columnIndex, column) in _value.columns.indexed) {
      for (var slot = 0; slot < ToolbarGrid.slots; slot++) {
        final key = (modifiers: column.modifiers, digit: slot + 1);
        if (column.slots[slot] == null && !widget.reserved.containsKey(key)) {
          return (column: columnIndex, slot: slot);
        }
      }
    }
    return null;
  }

  void _promoteChild(String id) {
    final target = _firstAvailableSlot();
    if (target == null) {
      setState(() => _error = '当前网格没有可用的非保留空格位，请先添加组或腾出格位。');
      return;
    }
    final next = _placeInSlot(id, target);
    if (next != null) _submit(next);
  }

  void _demoteToChild(String id, String parent) {
    final next = _placeAsChild(
      id,
      parent,
      (_value.children[parent] ?? const []).length,
    );
    if (next != null) _submit(next);
  }

  Future<void> _pickChildToDemote(String parent, List<String> movable) async {
    final chosen = await showDialog<String>(
      context: context,
      builder: (dialogContext) => NativeGlassDialog(
        maxWidth: 420,
        title: Text('移入到“${ScreenshotActions.labels[parent]}”子级'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final id in movable)
                Padding(
                  padding: const EdgeInsets.only(bottom: GlassMetrics.space4),
                  child: NativeGlassSurface(
                    material: true,
                    child: TextButton(
                      onPressed: () => Navigator.pop(dialogContext, id),
                      child: Row(
                        children: [
                          LineIcon(
                            ScreenshotActions.icons[id],
                            size: GlassMetrics.icon,
                          ),
                          const SizedBox(width: GlassMetrics.space8),
                          Text(ScreenshotActions.labels[id]!),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          NativeGlassSurface(
            material: true,
            child: TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
          ),
        ],
      ),
    );
    if (chosen != null && mounted) _demoteToChild(chosen, parent);
  }

  bool get _isDefault {
    final defaults = ScreenshotToolbarPreferences();
    if (_value.columns.length != defaults.columns.length) return false;
    for (var i = 0; i < _value.columns.length; i++) {
      final current = _value.columns[i];
      final baseline = defaults.columns[i];
      if (current.modifiers != baseline.modifiers) return false;
      for (var s = 0; s < ToolbarGrid.slots; s++) {
        if (current.slots[s] != baseline.slots[s]) return false;
      }
    }
    if (_value.children.length != defaults.children.length) return false;
    for (final entry in defaults.children.entries) {
      final currentList = _value.children[entry.key];
      if (currentList == null || currentList.length != entry.value.length) {
        return false;
      }
      for (var i = 0; i < entry.value.length; i++) {
        if (currentList[i] != entry.value[i]) return false;
      }
    }
    return _value.hidden.length == defaults.hidden.length &&
        _value.hidden.containsAll(defaults.hidden);
  }

  Future<void> _confirmReset() async {
    final confirmed = await NativeGlassDialog.confirm(
      context: context,
      title: '恢复默认工具栏',
      message: '确定将截图工具栏恢复为默认分组与快捷键吗？当前自定义排列将被替换。',
      confirmLabel: '恢复默认',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    final defaults = ScreenshotToolbarPreferences();
    for (final column in defaults.columns) {
      for (var slot = 0; slot < ToolbarGrid.slots; slot++) {
        if (column.slots[slot] == null) continue;
        final owner =
            widget.reserved[(modifiers: column.modifiers, digit: slot + 1)];
        if (owner != null) {
          setState(() => _error = '默认布局中的部分格位已被全局快捷键“$owner”占用，无法直接恢复默认。');
          return;
        }
      }
    }
    _submit(defaults);
    setState(() => _selected = null);
  }

  void _addColumn() {
    final used = {for (final column in _value.columns) column.modifiers};
    final modifiers = ToolbarModifiers.allowed.firstWhere(
      (value) => !used.contains(value),
    );
    _submit(
      _value.copyWith(
        columns: [
          ..._value.columns,
          ToolbarColumn(
            modifiers,
            List<String?>.filled(ToolbarGrid.slots, null),
          ),
        ],
      ),
    );
  }

  void _moveColumn(int from, int to) {
    if (from == to || to < 0 || to >= _value.columns.length) return;
    final modifiers = _value.columns[from].modifiers;
    final columns = [..._value.columns];
    columns.insert(to, columns.removeAt(from));
    _submit(_value.copyWith(columns: columns));
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _columnHandles[modifiers]?.requestFocus(),
    );
  }

  void _removeColumn(int column) {
    _submit(_value.copyWith(columns: [..._value.columns]..removeAt(column)));
  }

  void _setModifiers(int column, int modifiers) {
    for (var slot = 0; slot < ToolbarGrid.slots; slot++) {
      if (_value.columns[column].slots[slot] == null) continue;
      final owner = widget.reserved[(modifiers: modifiers, digit: slot + 1)];
      if (owner != null) {
        setState(() => _error = '切换到该修饰键会与全局快捷键“$owner”冲突，请先腾出对应格位。');
        return;
      }
    }
    final columns = [..._value.columns];
    columns[column] = ToolbarColumn(modifiers, columns[column].slots);
    _submit(_value.copyWith(columns: columns));
  }

  void _toggleVisible(String id) {
    final visible = !_value.hidden.contains(id);
    _submit(
      _value.copyWith(
        hidden: visible
            ? {..._value.hidden, id}
            : ({..._value.hidden}..remove(id)),
      ),
    );
  }

  bool _columnHidden(ToolbarColumn column) {
    final ids = column.slots.nonNulls;
    return ids.isNotEmpty && ids.every(_value.hidden.contains);
  }

  void _toggleColumnVisible(ToolbarColumn column) {
    final ids = column.slots.nonNulls.toSet();
    _submit(
      _value.copyWith(
        hidden: _columnHidden(column)
            ? _value.hidden.difference(ids)
            : {..._value.hidden, ...ids},
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selected != null && _slotOf(_selected!) != null
        ? _selected
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: GlassMetrics.space8),
            child: NativeGlassBanner(message: _error!, isError: true),
          ),
        ConstrainedBox(
          key: const ValueKey('toolbar-grid'),
          constraints: const BoxConstraints(
            maxWidth: ScreenshotToolbarEditor.gridWidth,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: ScreenshotToolbarEditor.rowGap,
            children: [
              Row(
                key: const ValueKey('toolbar-digits'),
                children: [
                  const SizedBox(
                    width:
                        ScreenshotToolbarEditor.headerWidth +
                        ScreenshotToolbarEditor.headerGap,
                  ),
                  Expanded(
                    child: Row(
                      spacing: ScreenshotToolbarEditor.cellGap,
                      children: [
                        for (var digit = 1; digit <= ToolbarGrid.slots; digit++)
                          Expanded(
                            child: SizedBox(
                              height: ScreenshotToolbarEditor.headerRowHeight,
                              child: Center(
                                child: Text(
                                  '$digit',
                                  style: TextStyle(
                                    fontSize: ScreenshotToolbarEditor.labelFont,
                                    fontWeight: FontWeight.w600,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              for (final (index, column) in _value.columns.indexed)
                _column(context, index, column),
            ],
          ),
        ),
        const SizedBox(height: GlassMetrics.space8),
        Wrap(
          spacing: GlassMetrics.actionGap,
          runSpacing: GlassMetrics.space8,
          children: [
            if (_value.columns.length < ToolbarGrid.maxColumns)
              NativeGlassSurface(
                material: true,
                child: TextButton(
                  key: const ValueKey('toolbar-add-column'),
                  onPressed: _addColumn,
                  child: const Text('添加组'),
                ),
              ),
            NativeGlassSurface(
              material: true,
              child: TextButton(
                key: const ValueKey('toolbar-reset-default'),
                onPressed: _isDefault ? null : _confirmReset,
                child: const Text('恢复默认'),
              ),
            ),
          ],
        ),
        if (selected != null) ...[
          const SizedBox(height: GlassMetrics.actionGap),
          _childrenList(context, selected),
        ],
      ],
    );
  }

  Widget _column(BuildContext context, int index, ToolbarColumn column) {
    final used = {
      for (final other in _value.columns)
        if (other != column) other.modifiers,
    };
    final empty = column.slots.every((slot) => slot == null);
    final label = column.modifiers == 0
        ? '无修饰组'
        : '${ToolbarModifiers.label(column.modifiers)} 组';
    return DragTarget<int>(
      key: ValueKey('toolbar-column-$index'),
      onWillAcceptWithDetails: (details) => details.data != index,
      onAcceptWithDetails: (details) => _moveColumn(details.data, index),
      builder: (context, candidates, rejected) {
        final from = candidates.firstOrNull;
        final side = BorderSide(
          color: NativeGlassTheme.accentOf(context),
          width: ScreenshotToolbarEditor.targetBorder,
        );
        return DecoratedBox(
          decoration: BoxDecoration(
            border: from == null
                ? null
                : from < index
                ? Border(bottom: side)
                : Border(top: side),
          ),
          child: _columnBody(context, index, column, used, empty, label),
        );
      },
    );
  }

  Widget _columnBody(
    BuildContext context,
    int index,
    ToolbarColumn column,
    Set<int> used,
    bool empty,
    String label,
  ) {
    final handle = SizedBox(
      width: GlassMetrics.hitSize,
      height: GlassMetrics.hitSize,
      child: Builder(
        builder: (context) => LineIcon(
          LucideIcons.gripVertical,
          size: GlassMetrics.icon,
          color: Focus.of(context).hasFocus
              ? Theme.of(context).colorScheme.primary
              : null,
        ),
      ),
    );
    final header = SizedBox(
      width: ScreenshotToolbarEditor.headerWidth,
      height: ScreenshotToolbarEditor.cellHeight,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: GlassMetrics.buttonHeight,
            child: NativeGlassMenuButton<int>(
              key: ValueKey('toolbar-modifiers-$index'),
              dense: true,
              flat: ShapeDecoration(
                color: ScreenshotToolbarEditor.cellColors(context).fill,
                shape: RoundedSuperellipseBorder(
                  borderRadius: BorderRadius.circular(
                    GlassMetrics.controlRadius,
                  ),
                  side: BorderSide(
                    color: ScreenshotToolbarEditor.cellColors(context).line,
                    width: ScreenshotToolbarEditor.hairline,
                  ),
                ),
              ),
              value: column.modifiers,
              items: {
                for (final modifiers in ToolbarModifiers.allowed)
                  if (!used.contains(modifiers))
                    modifiers: modifiers == 0
                        ? '无修饰'
                        : ToolbarModifiers.label(modifiers),
              },
              onChanged: (modifiers) => _setModifiers(index, modifiers),
            ),
          ),
          Row(
            children: [
              Semantics(
                label: '移动$label',
                onIncrease: () => _moveColumn(index, index + 1),
                onDecrease: () => _moveColumn(index, index - 1),
                child: Focus(
                  focusNode: _columnHandles.putIfAbsent(
                    column.modifiers,
                    FocusNode.new,
                  ),
                  onKeyEvent: (node, event) {
                    if (event is! KeyDownEvent) return KeyEventResult.ignored;
                    final delta = switch (event.logicalKey) {
                      LogicalKeyboardKey.arrowUp => -1,
                      LogicalKeyboardKey.arrowDown => 1,
                      _ => 0,
                    };
                    if (delta == 0) return KeyEventResult.ignored;
                    _moveColumn(index, index + delta);
                    return KeyEventResult.handled;
                  },
                  child: Builder(
                    builder: (context) => Tooltip(
                      message: '拖动调整$label的位置，快捷键不变',
                      child: Listener(
                        onPointerDown: (_) => Focus.of(context).requestFocus(),
                        child: MouseRegion(
                          cursor: SystemMouseCursors.grab,
                          child: Draggable<int>(
                            key: ValueKey('drag-column-$index'),
                            data: index,
                            feedback: Material(
                              color: Colors.transparent,
                              child: Opacity(
                                opacity:
                                    ScreenshotToolbarEditor.draggingOpacity,
                                child: Text(label),
                              ),
                            ),
                            childWhenDragging: Opacity(
                              opacity: ScreenshotToolbarEditor.draggingOpacity,
                              child: handle,
                            ),
                            child: handle,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (!empty)
                IconButton(
                  key: ValueKey('toolbar-hide-column-$index'),
                  tooltip: _columnHidden(column) ? '显示$label' : '隐藏$label',
                  constraints: const BoxConstraints.tightFor(
                    width: GlassMetrics.hitSize,
                    height: GlassMetrics.hitSize,
                  ),
                  padding: EdgeInsets.zero,
                  icon: LineIcon(
                    _columnHidden(column)
                        ? LucideIcons.eyeOff
                        : LucideIcons.eye,
                    size: GlassMetrics.icon,
                  ),
                  onPressed: () => _toggleColumnVisible(column),
                ),
              if (empty)
                IconButton(
                  key: ValueKey('toolbar-remove-column-$index'),
                  tooltip: '删除组',
                  constraints: const BoxConstraints.tightFor(
                    width: GlassMetrics.hitSize,
                    height: GlassMetrics.hitSize,
                  ),
                  padding: EdgeInsets.zero,
                  icon: const LineIcon(LucideIcons.x, size: GlassMetrics.icon),
                  onPressed: () => _removeColumn(index),
                ),
            ],
          ),
        ],
      ),
    );
    return Row(
      children: [
        header,
        const SizedBox(width: ScreenshotToolbarEditor.headerGap),
        Expanded(
          child: Row(
            spacing: ScreenshotToolbarEditor.cellGap,
            children: [
              for (final (slot, id) in column.slots.indexed)
                Expanded(
                  child: _cell(
                    context,
                    (column: index, slot: slot),
                    column.modifiers,
                    id,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _cell(BuildContext context, _Slot at, int modifiers, String? id) {
    final slot = (modifiers: modifiers, digit: at.slot + 1);
    final reservedFor = widget.reserved[slot];
    final systemConflict = id != null && widget.systemSlots.contains(slot);
    return DragTarget<String>(
      key: ValueKey('toolbar-slot-${at.column}-${at.slot}'),
      onWillAcceptWithDetails: (details) =>
          reservedFor == null && _placeInSlot(details.data, at) != null,
      onAcceptWithDetails: (details) {
        final next = _placeInSlot(details.data, at);
        if (next != null) _submit(next);
      },
      builder: (context, candidates, rejected) {
        final colors = Theme.of(context).colorScheme;
        final shape = RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(GlassMetrics.controlRadius),
          side: candidates.isNotEmpty
              ? BorderSide(
                  color: NativeGlassTheme.accentOf(context),
                  width: ScreenshotToolbarEditor.targetBorder,
                )
              : systemConflict
              ? BorderSide(
                  color: ScreenshotToolbarEditor.conflictColor(context),
                  width: ScreenshotToolbarEditor.targetBorder,
                )
              : id == _selected
              ? BorderSide(
                  color: NativeGlassTheme.accentOf(context),
                  width: ScreenshotToolbarEditor.selectedBorder,
                )
              : id == null
              ? BorderSide.none
              : BorderSide(
                  color: ScreenshotToolbarEditor.cellColors(context).line,
                  width: ScreenshotToolbarEditor.hairline,
                ),
        );
        final content = id == null
            ? CustomPaint(
                painter: _DashedBorder(colors.outlineVariant),
                child: reservedFor == null
                    ? const SizedBox.expand()
                    : Center(
                        child: Padding(
                          padding: const EdgeInsets.all(2),
                          child: Text(
                            '已用于$reservedFor',
                            textAlign: TextAlign.center,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: ScreenshotToolbarEditor.noteFont,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
              )
            : _toolCell(context, id, conflict: systemConflict);
        return Container(
          height: ScreenshotToolbarEditor.cellHeight,
          decoration: ShapeDecoration(
            shape: shape,
            color: id == null
                ? null
                : ScreenshotToolbarEditor.cellColors(context).fill,
          ),
          child: content,
        );
      },
    );
  }

  Widget _toolCell(BuildContext context, String id, {required bool conflict}) {
    final label = ScreenshotActions.labels[id]!;
    final visible = !_value.hidden.contains(id);
    final colors = Theme.of(context).colorScheme;
    final body = Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        LineIcon(
          ScreenshotActions.icons[id],
          size: GlassMetrics.icon,
          color: visible ? null : colors.onSurfaceVariant,
        ),
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: ScreenshotToolbarEditor.labelFont,
            color: visible ? null : colors.onSurfaceVariant,
          ),
        ),
        if (conflict)
          Text(
            '系统优先',
            key: ValueKey('toolbar-conflict-$id'),
            maxLines: 1,
            style: TextStyle(
              fontSize: ScreenshotToolbarEditor.noteFont,
              color: ScreenshotToolbarEditor.conflictColor(context),
            ),
          ),
      ],
    );
    final cell = GestureDetector(
      key: ValueKey('toolbar-cell-$id'),
      behavior: HitTestBehavior.opaque,
      onTap: ScreenshotActions.composable[id]!.hostsChildren
          ? () => setState(() => _selected = _selected == id ? null : id)
          : null,
      child: Stack(
        children: [
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: body,
            ),
          ),
          Positioned(
            top: 0,
            right: 0,
            child: _eye(
              id,
              label,
              visible,
              size: ScreenshotToolbarEditor.eyeIcon,
              hit: ScreenshotToolbarEditor.eyeHit,
            ),
          ),
        ],
      ),
    );
    final draggable = _handle(
      context,
      id,
      label,
      onKey: (logical) => switch (logical) {
        LogicalKeyboardKey.arrowUp => () => _moveByKey(id, -1, 0),
        LogicalKeyboardKey.arrowDown => () => _moveByKey(id, 1, 0),
        LogicalKeyboardKey.arrowLeft => () => _moveByKey(id, 0, -1),
        LogicalKeyboardKey.arrowRight => () => _moveByKey(id, 0, 1),
        LogicalKeyboardKey.enter || LogicalKeyboardKey.space
            when ScreenshotActions.composable[id]!.hostsChildren =>
          () => setState(() => _selected = _selected == id ? null : id),
        _ => null,
      },
      child: cell,
    );
    return conflict
        ? Tooltip(message: '与系统快捷键冲突，系统优先', child: draggable)
        : draggable;
  }

  Widget _childrenList(BuildContext context, String parent) {
    final children = _value.children[parent] ?? const <String>[];
    final title = '${ScreenshotActions.labels[parent]}的子级';
    final movable = <String>[
      for (final column in _value.columns)
        for (final id in column.slots)
          if (id != null && id != parent && _canBeChild(id)) id,
    ];
    return Column(
      key: ValueKey('toolbar-children-$parent'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            if (movable.isNotEmpty)
              NativeGlassSurface(
                material: true,
                child: TextButton(
                  key: ValueKey('toolbar-add-child-$parent'),
                  onPressed: () => _pickChildToDemote(parent, movable),
                  child: const Text('移入工具…'),
                ),
              ),
          ],
        ),
        const SizedBox(height: GlassMetrics.space4),
        for (final (index, id) in children.indexed)
          _childRow(context, parent, index, id),
        DragTarget<String>(
          key: ValueKey('toolbar-children-end-$parent'),
          onWillAcceptWithDetails: (details) =>
              _placeAsChild(details.data, parent, children.length) != null,
          onAcceptWithDetails: (details) {
            final next = _placeAsChild(details.data, parent, children.length);
            if (next != null) _submit(next);
          },
          builder: (context, candidates, rejected) => Container(
            height: ScreenshotToolbarEditor.childRowHeight,
            alignment: Alignment.centerLeft,
            decoration: candidates.isEmpty
                ? null
                : BoxDecoration(
                    border: Border(
                      top: BorderSide(
                        color: NativeGlassTheme.accentOf(context),
                        width: ScreenshotToolbarEditor.targetBorder,
                      ),
                    ),
                  ),
            child: Text(
              children.isEmpty ? '把工具拖到这里成为子级' : '拖到这里放在末尾',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _childRow(BuildContext context, String parent, int index, String id) {
    final label = ScreenshotActions.labels[id]!;
    final visible = !_value.hidden.contains(id);
    return DragTarget<String>(
      key: ValueKey('toolbar-child-$id'),
      onWillAcceptWithDetails: (details) =>
          _placeAsChild(details.data, parent, index) != null,
      onAcceptWithDetails: (details) {
        final next = _placeAsChild(details.data, parent, index);
        if (next != null) _submit(next);
      },
      builder: (context, candidates, rejected) => Container(
        constraints: const BoxConstraints(
          minHeight: ScreenshotToolbarEditor.childRowHeight,
        ),
        decoration: BoxDecoration(
          border: Border(
            top: candidates.isEmpty
                ? BorderSide(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  )
                : BorderSide(
                    color: NativeGlassTheme.accentOf(context),
                    width: ScreenshotToolbarEditor.targetBorder,
                  ),
          ),
        ),
        child: Row(
          children: [
            _handle(
              context,
              id,
              label,
              onKey: (logical) => switch (logical) {
                LogicalKeyboardKey.arrowUp => () => _shiftChild(id, -1),
                LogicalKeyboardKey.arrowDown => () => _shiftChild(id, 1),
                _ => null,
              },
            ),
            LineIcon(ScreenshotActions.icons[id], size: GlassMetrics.icon),
            const SizedBox(width: GlassMetrics.actionGap),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: visible
                      ? null
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            NativeGlassSurface(
              material: true,
              child: IconButton(
                key: ValueKey('promote-child-$id'),
                tooltip: '移出到一级工具栏',
                icon: const LineIcon(LucideIcons.arrowUp, size: GlassMetrics.icon),
                visualDensity: VisualDensity.standard,
                onPressed: () => _promoteChild(id),
              ),
            ),
            const SizedBox(width: GlassMetrics.actionGap),
            _eye(id, label, visible),
          ],
        ),
      ),
    );
  }

  Widget _handle(
    BuildContext context,
    String id,
    String label, {
    required VoidCallback? Function(LogicalKeyboardKey key) onKey,
    Widget? child,
  }) {
    final handle = Builder(
      builder: (context) {
        final focused = Focus.of(context).hasFocus;
        return Container(
          width: child == null ? GlassMetrics.hitSize : null,
          height: child == null ? GlassMetrics.hitSize : null,
          decoration: ShapeDecoration(
            shape: RoundedSuperellipseBorder(
              borderRadius: BorderRadius.circular(GlassMetrics.controlRadius),
              side: focused
                  ? BorderSide(
                      color: Theme.of(context).colorScheme.primary,
                      width: 2,
                    )
                  : BorderSide.none,
            ),
          ),
          child:
              child ?? const LineIcon(LucideIcons.gripHorizontal, size: GlassMetrics.icon),
        );
      },
    );
    return Semantics(
      label: '移动 $label',
      onIncrease: onKey(LogicalKeyboardKey.arrowDown),
      onDecrease: onKey(LogicalKeyboardKey.arrowUp),
      child: Focus(
        focusNode: _handles.putIfAbsent(id, FocusNode.new),
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          final move = onKey(event.logicalKey);
          if (move == null) return KeyEventResult.ignored;
          move();
          return KeyEventResult.handled;
        },
        child: Builder(
          builder: (context) => Tooltip(
            message: '拖到格位获得该格快捷键；聚焦后用方向键移动 $label',
            child: Listener(
              onPointerDown: (_) => Focus.of(context).requestFocus(),
              child: MouseRegion(
                cursor: SystemMouseCursors.grab,
                child: Draggable<String>(
                  key: ValueKey('drag-$id'),
                  data: id,
                  feedback: Material(
                    color: Colors.transparent,
                    child: Opacity(
                      opacity: ScreenshotToolbarEditor.draggingOpacity,
                      child: LineIcon(ScreenshotActions.icons[id], size: 24),
                    ),
                  ),
                  childWhenDragging: Opacity(
                    opacity: ScreenshotToolbarEditor.draggingOpacity,
                    child: handle,
                  ),
                  child: handle,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _eye(
    String id,
    String label,
    bool visible, {
    double size = 18,
    double hit = GlassMetrics.hitSize,
  }) => Semantics(
    toggled: visible,
    child: IconButton(
      key: ValueKey('visibility-$id'),
      tooltip: '${visible ? '隐藏' : '显示'} $label',
      constraints: BoxConstraints.tightFor(width: hit, height: hit),
      padding: EdgeInsets.zero,
      style: IconButton.styleFrom(
        backgroundColor: Colors.transparent,
        shadowColor: Colors.transparent,
        foregroundColor: visible
            ? NativeGlassTheme.accentOf(context)
            : const Color(0xFF929292),
      ),
      icon: LineIcon(visible ? LucideIcons.eye : LucideIcons.eyeOff, size: size),
      onPressed: () => _toggleVisible(id),
    ),
  );
}

class _DashedBorder extends CustomPainter {
  const _DashedBorder(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          (Offset.zero & size).deflate(0.5),
          const Radius.circular(GlassMetrics.controlRadius),
        ),
      );
    for (final metric in path.computeMetrics()) {
      for (var start = 0.0; start < metric.length; start += 7) {
        canvas.drawPath(metric.extractPath(start, start + 4), paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedBorder oldDelegate) =>
      oldDelegate.color != color;
}
