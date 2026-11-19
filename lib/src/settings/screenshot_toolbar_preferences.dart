import '../common/constants/preference_keys.dart';
import '../common/constants/screenshot_actions.dart';
import '../common/constants/toolbar_grid.dart';

/// 截图工具栏网格的一列（#141）：modifiers 为该列的修饰键位掩码（ToolbarModifiers），
/// slots 为自上而下 6 个格位，第 i 格（从 0 起）的快捷键为「modifiers + 数字 i+1」；空格为 null。
class ToolbarColumn {
  /// modifiers 为修饰键位掩码；slots 为恰好 ToolbarGrid.slots 个格位，空格为 null。
  ToolbarColumn(this.modifiers, List<String?> slots)
    : slots = List.unmodifiable(slots);

  final int modifiers;
  final List<String?> slots;

  /// map 为存储字典 {modifiers, slots}；空格存为空字符串（属性列表不能存 null），读出时还原为 null。
  factory ToolbarColumn.fromMap(Map<Object?, Object?> map) =>
      ToolbarColumn(map['modifiers'] as int, [
        for (final slot in (map['slots'] as List).cast<String>())
          slot.isEmpty ? null : slot,
      ]);

  /// 无参数；返回可经 UserDefaults 保存的字典，空格写为空字符串。
  Map<String, Object> toMap() => {
    'modifiers': modifiers,
    'slots': [for (final slot in slots) slot ?? ''],
  };

  /// index 为格位（从 0 起），id 为放入的功能或 null；返回替换该格后的新列。
  ToolbarColumn withSlot(int index, String? id) =>
      ToolbarColumn(modifiers, [...slots]..[index] = id);
}

/// 工具栏网格与局部快捷键的不可变快照，修改不会污染正在保存的事务（#141）。
///
/// 一级功能放在 columns 的格位中，格位决定快捷键；children 是父级到子级列表，子级没有快捷键。
/// 每个可拼接功能在格位与子级中恰好出现一次；只有“工具”类功能可以作为父级。
class ScreenshotToolbarPreferences {
  /// columns 为网格列，children 为父子结构，hidden 为隐藏的功能；缺省时采用默认网格。
  ScreenshotToolbarPreferences({
    List<ToolbarColumn>? columns,
    Map<String, List<String>>? children,
    Set<String>? hidden,
  }) : columns = List.unmodifiable(columns ?? _defaultColumns),
       children = Map.unmodifiable({
         for (final entry
             in (children ?? ScreenshotActions.defaultChildren).entries)
           if (entry.value.isNotEmpty)
             entry.key: List<String>.unmodifiable(entry.value),
       }),
       hidden = Set.unmodifiable(hidden ?? const {});

  /// 默认网格：注册表顺序去掉默认子级后，按 ToolbarGrid.defaultModifiers 的列依次每列填 6 格。
  static List<ToolbarColumn> get _defaultColumns {
    final nested = {
      for (final list in ScreenshotActions.defaultChildren.values) ...list,
    };
    final topLevel = [
      for (final id in ScreenshotActions.composable.keys)
        if (!nested.contains(id)) id,
    ];
    return [
      for (final (index, modifiers) in ToolbarGrid.defaultModifiers.indexed)
        ToolbarColumn(modifiers, [
          for (var slot = 0; slot < ToolbarGrid.slots; slot++)
            topLevel.elementAtOrNull(index * ToolbarGrid.slots + slot),
        ]),
    ];
  }

  final List<ToolbarColumn> columns;

  /// 父级ID到按顺序排列的子级ID；没有子级的功能不出现在这里。
  final Map<String, List<String>> children;

  /// 只控制按钮可见性，格位与快捷键保持，隐藏的功能仍可通过快捷键调用。
  final Set<String> hidden;

  /// 无参数；返回按列、列内自上而下排列的一级功能。
  List<String> get topLevel => [
    for (final column in columns) ...column.slots.whereType<String>(),
  ];

  /// id 为功能ID；返回它的父级，一级功能返回 null。
  String? parentOf(String id) {
    for (final entry in children.entries) {
      if (entry.value.contains(id)) return entry.key;
    }
    return null;
  }

  /// id 为功能ID；返回其格位推导出的快捷键文字（如「⌘2」），子级返回 null。
  String? shortcutLabel(String id) {
    for (final column in columns) {
      final index = column.slots.indexOf(id);
      if (index >= 0) {
        return '${ToolbarModifiers.label(column.modifiers)}${index + 1}';
      }
    }
    return null;
  }

  /// modifiers 为按下的修饰键位掩码，digit 为数字键 1–6；返回该格位的功能，空格或无此列为 null。
  String? actionAt(int modifiers, int digit) {
    final column = columns.where((c) => c.modifiers == modifiers).firstOrNull;
    return column?.slots[digit - 1];
  }

  /// 只替换给出的部分，返回新的快照。
  ScreenshotToolbarPreferences copyWith({
    List<ToolbarColumn>? columns,
    Map<String, List<String>>? children,
    Set<String>? hidden,
  }) => ScreenshotToolbarPreferences(
    columns: columns ?? this.columns,
    children: children ?? this.children,
    hidden: hidden ?? this.hidden,
  );

  /// map 为完整应用偏好；返回已校验快照。
  /// 没有网格（旧结构或首次使用）时整体采用默认网格，不迁移旧的顺序与快捷键（#141）。
  /// 已保存网格里没有的功能：默认父级是一级时放回它下面，否则放入第一个空格，无空格时新增一列。
  factory ScreenshotToolbarPreferences.fromMap(Map<Object?, Object?> map) {
    final stored = map[PreferenceKeys.screenshotToolbarColumns] as List?;
    if (stored == null) return ScreenshotToolbarPreferences()..validate();
    final columns = [
      for (final item in stored)
        ToolbarColumn.fromMap(Map<Object?, Object?>.from(item as Map)),
    ];
    final children = {
      for (final entry
          in ((map[PreferenceKeys.screenshotToolbarChildren] as Map?) ?? {})
              .entries)
        entry.key as String: (entry.value as List).cast<String>().toList(),
    };
    final placed = {
      for (final column in columns) ...column.slots.whereType<String>(),
      for (final list in children.values) ...list,
    };
    for (final id in ScreenshotActions.composable.keys) {
      if (placed.contains(id)) continue;
      final parent = ScreenshotActions.defaultChildren.entries
          .where((entry) => entry.value.contains(id))
          .map((entry) => entry.key)
          .firstOrNull;
      final topLevel = {
        for (final column in columns) ...column.slots.whereType<String>(),
      };
      if (parent != null && topLevel.contains(parent)) {
        (children[parent] ??= []).add(id);
      } else {
        _placeInFirstEmpty(columns, id);
      }
      placed.add(id);
    }
    final result = ScreenshotToolbarPreferences(
      columns: columns,
      children: children,
      hidden: (map[PreferenceKeys.screenshotToolbarHidden] as List?)
          ?.cast<String>()
          .toSet(),
    );
    result.validate();
    return result;
  }

  /// columns 为可变网格，id 为待放入的功能；放入第一个空格，没有空格时用第一个未使用的组合新增一列。
  static void _placeInFirstEmpty(List<ToolbarColumn> columns, String id) {
    for (final (index, column) in columns.indexed) {
      final empty = column.slots.indexOf(null);
      if (empty >= 0) {
        columns[index] = column.withSlot(empty, id);
        return;
      }
    }
    final used = {for (final column in columns) column.modifiers};
    final modifiers = ToolbarModifiers.allowed.firstWhere(
      (value) => !used.contains(value),
    );
    columns.add(
      ToolbarColumn(modifiers, [
        id,
        ...List<String?>.filled(ToolbarGrid.slots - 1, null),
      ]),
    );
  }

  /// 无参数；返回完整网格、结构与隐藏集合，调用方合并到同一偏好事务。
  Map<String, Object> toMap() => {
    PreferenceKeys.screenshotToolbarHidden: hidden.toList(),
    PreferenceKeys.screenshotToolbarColumns: [
      for (final column in columns) column.toMap(),
    ],
    PreferenceKeys.screenshotToolbarChildren: children,
  };

  /// 无参数；拒绝不合法的列组合、格位数、缺项/重复/未知功能与父子关系，保留调用方原配置。
  void validate() {
    if (columns.isEmpty || columns.length > ToolbarGrid.maxColumns) {
      throw const FormatException('工具栏需要 1 到 8 列。');
    }
    final modifiers = [for (final column in columns) column.modifiers];
    if (modifiers.any((value) => !ToolbarModifiers.allowed.contains(value))) {
      throw const FormatException('列的组合键只能是 ⌘、⌥、⌃ 的组合或无修饰，不能含 ⇧。');
    }
    if (modifiers.toSet().length != modifiers.length) {
      throw const FormatException('每一列的组合键不能重复。');
    }
    if (columns.any((column) => column.slots.length != ToolbarGrid.slots)) {
      throw const FormatException('每一列必须正好有 6 格。');
    }
    final topLevel = this.topLevel;
    final all = [...topLevel, for (final list in children.values) ...list];
    if (all.length != ScreenshotActions.composable.length ||
        all.toSet().length != all.length ||
        all.any((id) => !ScreenshotActions.composable.containsKey(id))) {
      throw const FormatException('工具栏必须包含每个功能且不能重复。');
    }
    for (final parent in children.keys) {
      // 父级必须是一级功能，并且是点击后停留的“工具”。
      if (!topLevel.contains(parent) ||
          !ScreenshotActions.composable[parent]!.hostsChildren) {
        throw const FormatException('只有一级的工具可以包含子级。');
      }
    }
    if (hidden.any((id) => !ScreenshotActions.composable.containsKey(id))) {
      throw const FormatException('只能隐藏可拼接的截图功能。');
    }
  }
}
