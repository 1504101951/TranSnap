import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../common/constants/glass_metrics.dart';
import '../common/constants/screenshot_actions.dart';
import '../common/constants/toolbar_grid.dart';
import '../common/widgets/native_glass.dart';
import 'screenshot_toolbar_preferences.dart';

/// 截图工具栏网格编辑器（#141，#67「截图工具栏网格」）：每列一种修饰键组合、6 个格位，格位即快捷键；
/// 拖动工具到格位获得键位，同格交换；选中可承载子级的工具后在网格下方编辑其子级；仅修改偏好，不注册全局热键。
class ScreenshotToolbarEditor extends StatefulWidget {
  const ScreenshotToolbarEditor({
    super.key,
    required this.value,
    required this.onChanged,
  });
  final ScreenshotToolbarPreferences value;
  final ValueChanged<ScreenshotToolbarPreferences> onChanged;

  /// 格子宽高、圆角与间距（#67）。
  static const cellWidth = 120.0;
  static const cellHeight = 56.0;
  static const cellGap = 4.0;
  static const columnGap = 8.0;

  /// 子级列表的行最小高度（#67）。
  static const childRowHeight = 40.0;

  /// 被拖动格子的不透明度；目标格边框宽度。
  static const draggingOpacity = 0.6;
  static const targetBorder = 2.0;

  /// 无参数；创建局部选中与错误状态，提交沿用父页自动保存。
  @override
  State<ScreenshotToolbarEditor> createState() =>
      _ScreenshotToolbarEditorState();
}

/// 格位坐标：column 为列下标，slot 为格下标（0–5）。
typedef _Slot = ({int column, int slot});

class _ScreenshotToolbarEditorState extends State<ScreenshotToolbarEditor> {
  late ScreenshotToolbarPreferences _value = widget.value;
  String? _error;

  /// 选中的可承载子级的一级工具；非 null 时网格下方显示其子级列表。
  String? _selected;

  /// 各功能拖拽手柄的焦点；按功能保存，键盘移动后格子换了位置焦点仍跟随该功能。
  final Map<String, FocusNode> _handles = {};

  /// 无参数；释放手柄焦点。
  @override
  void dispose() {
    for (final node in _handles.values) {
      node.dispose();
    }
    super.dispose();
  }

  /// oldWidget 为父级旧快照；外部重新加载时采用父级配置。
  @override
  void didUpdateWidget(covariant ScreenshotToolbarEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != oldWidget.value) _value = widget.value;
  }

  /// next 为完整配置；校验成功才提交，错误保留原值并给出原因。
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

  /// id 为功能；返回它所在的格位，子级或不存在时为 null。
  _Slot? _slotOf(String id) {
    for (final (column, value) in _value.columns.indexed) {
      final slot = value.slots.indexOf(id);
      if (slot >= 0) return (column: column, slot: slot);
    }
    return null;
  }

  /// 无参数；返回可修改的父子结构副本。
  Map<String, List<String>> _childrenCopy() => {
    for (final entry in _value.children.entries) entry.key: [...entry.value],
  };

  /// id 为功能；返回它能否成为子级：自己没有子级。
  bool _canBeChild(String id) => (_value.children[id] ?? const []).isEmpty;

  /// id 为被放下的功能，target 为目标格位；返回放下后的配置，不允许时为 null。
  /// 目标格有工具时与 id 原位置交换：id 原在格位则两者互换；id 原为子级时，
  /// 被换出的工具只有能成为子级（自己没有子级，且不是该父级本身）才交换。
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

  /// id 为被放下的功能，parent 为子级列表所属父级，index 为插入位置；返回放下后的配置，不允许时为 null。
  /// id 不能是父级本身，且自己不能带子级；原在格位时留下空格。
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
      // 同一列表内向后移动时，移除后目标下标前移一位。
      if (_value.parentOf(id) == parent && old < position) position -= 1;
      if (siblings.isEmpty) children.remove(_value.parentOf(id));
    }
    final list = children[parent] ??= [];
    list.insert(position.clamp(0, list.length), id);
    return _value.copyWith(columns: columns, children: children);
  }

  /// id 为格位中的功能，dx/dy 为方向键位移；与相邻格交换（列内上下、跨列左右），越界不动。
  void _moveByKey(String id, int dx, int dy) {
    final from = _slotOf(id)!;
    final column = from.column + dx;
    final slot = from.slot + dy;
    if (column < 0 ||
        column >= _value.columns.length ||
        slot < 0 ||
        slot >= ToolbarGrid.slots) {
      return;
    }
    final next = _placeInSlot(id, (column: column, slot: slot));
    if (next == null) return;
    _submit(next);
    // 格子换位后重建，把焦点交回该功能的手柄，便于连续用方向键移动。
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _handles[id]?.requestFocus(),
    );
  }

  /// id 为子级，delta 为 -1 或 1；在同一父级的子级之间移动一位，到头不动。
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

  /// 无参数；用第一个未使用的组合新增一列空列，已有 8 列时不出现入口。
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

  /// column 为列下标；删除空列，后续列前移。
  void _removeColumn(int column) {
    _submit(_value.copyWith(columns: [..._value.columns]..removeAt(column)));
  }

  /// column 为列下标，modifiers 为新组合；改变该列的组合，格位与工具不变。
  void _setModifiers(int column, int modifiers) {
    final columns = [..._value.columns];
    columns[column] = ToolbarColumn(modifiers, columns[column].slots);
    _submit(_value.copyWith(columns: columns));
  }

  /// id 为功能；切换显示或隐藏，格位与键位保持。
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

  /// context 为页面主题；网格超出宽度时在页内横向滚动，子级列表随设置正文滚动。
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
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        SingleChildScrollView(
          key: const ValueKey('toolbar-grid'),
          scrollDirection: Axis.horizontal,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: ScreenshotToolbarEditor.columnGap,
            children: [
              for (final (index, column) in _value.columns.indexed)
                _column(context, index, column),
              if (_value.columns.length < ToolbarGrid.maxColumns)
                NativeGlassSurface(
                  material: true,
                  child: TextButton(
                    key: const ValueKey('toolbar-add-column'),
                    onPressed: _addColumn,
                    child: const Text('添加列'),
                  ),
                ),
            ],
          ),
        ),
        if (selected != null) ...[
          const SizedBox(height: GlassMetrics.actionGap),
          _childrenList(context, selected),
        ],
      ],
    );
  }

  /// index 为列下标，column 为该列；返回列头（组合下拉、空列的删除入口）与 6 个格子。
  Widget _column(BuildContext context, int index, ToolbarColumn column) {
    final used = {
      for (final other in _value.columns)
        if (other != column) other.modifiers,
    };
    final empty = column.slots.every((slot) => slot == null);
    return SizedBox(
      key: ValueKey('toolbar-column-$index'),
      width: ScreenshotToolbarEditor.cellWidth,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        spacing: ScreenshotToolbarEditor.cellGap,
        children: [
          SizedBox(
            height: GlassMetrics.buttonHeight,
            child: Row(
              children: [
                Expanded(
                  child: NativeGlassMenuButton<int>(
                    key: ValueKey('toolbar-modifiers-$index'),
                    value: column.modifiers,
                    // 其他列已用的组合不可选，保证各列组合不重复。
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
                if (empty)
                  IconButton(
                    key: ValueKey('toolbar-remove-column-$index'),
                    tooltip: '删除列',
                    icon: const Icon(Icons.close, size: GlassMetrics.icon),
                    onPressed: () => _removeColumn(index),
                  ),
              ],
            ),
          ),
          for (final (slot, id) in column.slots.indexed)
            _cell(context, (column: index, slot: slot), column.modifiers, id),
        ],
      ),
    );
  }

  /// at 为格位，modifiers 为所在列组合，id 为格中功能（空格为 null）；返回可放下的格子。
  Widget _cell(BuildContext context, _Slot at, int modifiers, String? id) {
    final key = '${ToolbarModifiers.label(modifiers)}${at.slot + 1}';
    return DragTarget<String>(
      key: ValueKey('toolbar-slot-${at.column}-${at.slot}'),
      onWillAcceptWithDetails: (details) =>
          _placeInSlot(details.data, at) != null,
      onAcceptWithDetails: (details) {
        final next = _placeInSlot(details.data, at);
        if (next != null) _submit(next);
      },
      builder: (context, candidates, rejected) {
        final colors = Theme.of(context).colorScheme;
        final shape = RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(GlassMetrics.controlRadius),
          side: candidates.isNotEmpty
              ? const BorderSide(
                  color: NativeGlassTheme.selectionBlue,
                  width: ScreenshotToolbarEditor.targetBorder,
                )
              : id == _selected
              ? BorderSide(color: colors.primary)
              : BorderSide.none,
        );
        final content = id == null
            ? CustomPaint(
                painter: _DashedBorder(colors.outlineVariant),
                child: Center(
                  child: Text(
                    key,
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: colors.onSurfaceVariant),
                  ),
                ),
              )
            : _toolCell(context, id, key);
        return Container(
          width: ScreenshotToolbarEditor.cellWidth,
          height: ScreenshotToolbarEditor.cellHeight,
          decoration: ShapeDecoration(shape: shape),
          child: content,
        );
      },
    );
  }

  /// id 为格中功能，key 为格位键位文字；返回拖拽手柄、图标、名称与键位、眼睛按钮。
  /// 点按可承载子级的工具时选中它，网格下方显示其子级。
  Widget _toolCell(BuildContext context, String id, String key) {
    final label = ScreenshotActions.labels[id]!;
    final visible = !_value.hidden.contains(id);
    final colors = Theme.of(context).colorScheme;
    return GestureDetector(
      key: ValueKey('toolbar-cell-$id'),
      behavior: HitTestBehavior.opaque,
      onTap: ScreenshotActions.composable[id]!.hostsChildren
          ? () => setState(() => _selected = _selected == id ? null : id)
          : null,
      child: Row(
        children: [
          _handle(
            context,
            id,
            label,
            onKey: (logical) => switch (logical) {
              LogicalKeyboardKey.arrowUp => () => _moveByKey(id, 0, -1),
              LogicalKeyboardKey.arrowDown => () => _moveByKey(id, 0, 1),
              LogicalKeyboardKey.arrowLeft => () => _moveByKey(id, -1, 0),
              LogicalKeyboardKey.arrowRight => () => _moveByKey(id, 1, 0),
              _ => null,
            },
          ),
          Icon(ScreenshotActions.icons[id], size: GlassMetrics.icon),
          const SizedBox(width: GlassMetrics.actionGap),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: visible ? null : colors.onSurfaceVariant,
                  ),
                ),
                Text(
                  key,
                  key: ValueKey('toolbar-key-$id'),
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: colors.onSurfaceVariant),
                ),
              ],
            ),
          ),
          _eye(id, label, visible),
        ],
      ),
    );
  }

  /// parent 为选中的父级；返回「〈名称〉的子级」列表，可拖入拖出网格与排序。
  Widget _childrenList(BuildContext context, String parent) {
    final children = _value.children[parent] ?? const <String>[];
    final title = '${ScreenshotActions.labels[parent]}的子级';
    return Column(
      key: ValueKey('toolbar-children-$parent'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        for (final (index, id) in children.indexed)
          _childRow(context, parent, index, id),
        // 末尾落点：拖到这里排到子级末尾；没有子级时同样作为第一个子级的落点。
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
                : const BoxDecoration(
                    border: Border(
                      top: BorderSide(
                        color: NativeGlassTheme.selectionBlue,
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

  /// parent 为父级，index 为子级下标，id 为子级；返回可拖动、可在其前方放下的一行。
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
                : const BorderSide(
                    color: NativeGlassTheme.selectionBlue,
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
            Icon(ScreenshotActions.icons[id], size: GlassMetrics.icon),
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
            _eye(id, label, visible),
          ],
        ),
      ),
    );
  }

  /// id/label 为功能与名称，onKey 把方向键映射为移动动作（不处理时返回 null）；
  /// 返回 32×32 拖拽手柄：鼠标拖动放到格位或子级列表，聚焦后方向键移动，提供可访问性调整动作。
  Widget _handle(
    BuildContext context,
    String id,
    String label, {
    required VoidCallback? Function(LogicalKeyboardKey key) onKey,
  }) {
    final handle = Builder(
      builder: (context) {
        final focused = Focus.of(context).hasFocus;
        return Container(
          width: GlassMetrics.hitSize,
          height: GlassMetrics.hitSize,
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
          child: const Icon(Icons.drag_handle, size: GlassMetrics.icon),
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
                      child: Icon(ScreenshotActions.icons[id], size: 24),
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

  /// id/label 为功能与名称，visible 为当前可见性；返回切换显示的眼睛按钮（#67）。
  Widget _eye(String id, String label, bool visible) => Semantics(
    toggled: visible,
    child: IconButton(
      key: ValueKey('visibility-$id'),
      tooltip: '${visible ? '隐藏' : '显示'} $label',
      style: IconButton.styleFrom(
        backgroundColor: Colors.transparent,
        shadowColor: Colors.transparent,
        foregroundColor: visible
            ? NativeGlassTheme.selectionBlue
            : const Color(0xFF929292),
      ),
      icon: Icon(visible ? Icons.visibility : Icons.visibility_off, size: 18),
      onPressed: () => _toggleVisible(id),
    ),
  );
}

/// 空格的 1pt 虚线边框（#67）：沿圆角矩形绘制 4pt 线段、3pt 间隔。
class _DashedBorder extends CustomPainter {
  const _DashedBorder(this.color);
  final Color color;

  /// canvas/size 为绘制目标；沿 r8 圆角矩形路径按段描线。
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

  /// oldDelegate 为上一画笔；颜色变化时重画。
  @override
  bool shouldRepaint(covariant _DashedBorder oldDelegate) =>
      oldDelegate.color != color;
}
