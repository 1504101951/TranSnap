import '../common/constants/preference_keys.dart';
import '../common/constants/screenshot_actions.dart';
import '../common/constants/toolbar_grid.dart';

class ToolbarColumn {
  ToolbarColumn(this.modifiers, List<String?> slots)
    : slots = List.unmodifiable(slots);

  final int modifiers;
  final List<String?> slots;

  factory ToolbarColumn.fromMap(Map<Object?, Object?> map) =>
      ToolbarColumn(map['modifiers'] as int, [
        for (final slot in (map['slots'] as List).cast<String>())
          slot.isEmpty ? null : slot,
      ]);

  Map<String, Object> toMap() => {
    'modifiers': modifiers,
    'slots': [for (final slot in slots) slot ?? ''],
  };

  ToolbarColumn withSlot(int index, String? id) =>
      ToolbarColumn(modifiers, [...slots]..[index] = id);
}

class ScreenshotToolbarPreferences {
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

  final Map<String, List<String>> children;

  final Set<String> hidden;

  List<String> get topLevel => [
    for (final column in columns) ...column.slots.whereType<String>(),
  ];

  String? parentOf(String id) {
    for (final entry in children.entries) {
      if (entry.value.contains(id)) return entry.key;
    }
    return null;
  }

  String? shortcutLabel(String id) {
    for (final column in columns) {
      final index = column.slots.indexOf(id);
      if (index >= 0) {
        return '${ToolbarModifiers.label(column.modifiers)}${index + 1}';
      }
    }
    return null;
  }

  String? actionAt(int modifiers, int digit) {
    final column = columns.where((c) => c.modifiers == modifiers).firstOrNull;
    return column?.slots[digit - 1];
  }

  ScreenshotToolbarPreferences copyWith({
    List<ToolbarColumn>? columns,
    Map<String, List<String>>? children,
    Set<String>? hidden,
  }) => ScreenshotToolbarPreferences(
    columns: columns ?? this.columns,
    children: children ?? this.children,
    hidden: hidden ?? this.hidden,
  );

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

  Map<String, Object> toMap() => {
    PreferenceKeys.screenshotToolbarHidden: hidden.toList(),
    PreferenceKeys.screenshotToolbarColumns: [
      for (final column in columns) column.toMap(),
    ],
    PreferenceKeys.screenshotToolbarChildren: children,
  };

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
