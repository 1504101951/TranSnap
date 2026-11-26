import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../common/constants/font_sets.dart';
import '../common/constants/glass_metrics.dart';
import '../common/widgets/glass_icon_button.dart';
import '../common/widgets/line_icon.dart';
import '../common/widgets/native_glass.dart';
import '../fonts/font_state.dart';

class FontSetPicker extends StatefulWidget {
  const FontSetPicker({
    super.key,
    required this.value,
    required this.state,
    required this.onSelect,
    required this.onDownload,
    required this.onCancel,
    required this.onUninstall,
  });

  final FontSet value;
  final FontState state;
  final ValueChanged<FontSet> onSelect;
  final ValueChanged<FontSet> onDownload;
  final VoidCallback onCancel;
  final ValueChanged<FontSet> onUninstall;

  static const triggerWidth = 240.0;
  static const triggerHeight = 28.0;
  static const menuWidth = 320.0;
  static const itemHeight = 38.0;
  static const checkColumn = 28.0;
  static const smallIcon = 14.0;
  static const progressHeight = 4.0;

  static String megabytes(int bytes) =>
      '${(bytes / 1000000).toStringAsFixed(1)} MB';

  @override
  State<FontSetPicker> createState() => _FontSetPickerState();
}

class _FontSetPickerState extends State<FontSetPicker> {
  final _buttonFocus = FocusNode();
  final _selectedFocus = FocusNode();

  @override
  void dispose() {
    _buttonFocus.dispose();
    _selectedFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final download = widget.state.download;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        NativeGlassSettingRow(
          title: '字体',
          leading: const NativeGlassRowIcon(icon: LucideIcons.type),
          child: MenuAnchor(
            childFocusNode: _buttonFocus,
            style: NativeGlassMenuPanel.anchorStyle,
            onOpen: () => WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && _selectedFocus.context != null) {
                _selectedFocus.requestFocus();
              }
            }),
            menuChildren: [
              NativeGlassMenuPanel(
                children: [
                  for (final set in FontSet.values)
                    SizedBox(
                      width: FontSetPicker.menuWidth - 8,
                      child: _item(context, set),
                    ),
                ],
              ),
            ],
            builder: (context, controller, _) => SizedBox(
              width: FontSetPicker.triggerWidth,
              height: FontSetPicker.triggerHeight,
              child: NativeGlassSurface(
                material: true,
                child: TextButton(
                  key: const ValueKey('font-set-trigger'),
                  focusNode: _buttonFocus,
                  onPressed: () => controller.isOpen
                      ? controller.close()
                      : controller.open(),
                  style: TextButton.styleFrom(
                    minimumSize: Size.zero,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          widget.value.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 6),
                      const LineIcon(
                        LucideIcons.chevronDown,
                        size: FontSetPicker.smallIcon,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        if (download != null) _progress(context, download),
      ],
    );
  }

  Widget _item(BuildContext context, FontSet set) {
    final theme = Theme.of(context);
    final secondary = theme.colorScheme.onSurfaceVariant;
    final accent = NativeGlassTheme.accentOf(context);
    final state = widget.state;
    final available = state.isAvailable(set);
    final status = set.isBundled
        ? '内置'
        : available
        ? '已下载'
        : '未下载 · ${FontSetPicker.megabytes(state.missingBytes(set))}';
    return NativeGlassButtonFeedback(
      radius: GlassMetrics.menuItemRadius,
      enabled: true,
      pressScale: 0.98,
      child: MenuItemButton(
        key: ValueKey('font-set-${set.name}'),
        focusNode: set == widget.value ? _selectedFocus : null,
        onPressed: () =>
            available ? widget.onSelect(set) : widget.onDownload(set),
        style: ButtonStyle(
          overlayColor: const WidgetStatePropertyAll(Colors.transparent),
          minimumSize: const WidgetStatePropertyAll(
            Size(0, FontSetPicker.itemHeight),
          ),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.only(right: GlassMetrics.space8),
          ),
          shape: WidgetStatePropertyAll(
            RoundedSuperellipseBorder(
              borderRadius: BorderRadius.circular(GlassMetrics.menuItemRadius),
            ),
          ),
        ),
        child: Row(
          children: [
            SizedBox(
              width: FontSetPicker.checkColumn,
              child: set == widget.value
                  ? LineIcon(
                      LucideIcons.check,
                      size: FontSetPicker.smallIcon,
                      color: accent,
                    )
                  : null,
            ),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    set.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: set.nameFamily,
                      fontFamilyFallback: [set.nameTitleFamily],
                      fontSize: 13,
                      height: 18 / 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  Text(
                    set.composition,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: set.nameFamily,
                      fontFamilyFallback: [set.nameTextFamily],
                      fontSize: GlassMetrics.statusFont,
                      height: 14 / GlassMetrics.statusFont,
                      color: secondary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: GlassMetrics.space8),
            Text(
              status,
              style: theme.textTheme.bodySmall!.copyWith(
                fontSize: GlassMetrics.statusFont,
                color: set.isBundled ? accent : secondary,
              ),
            ),
            if (available && !set.isBundled)
              GlassIconButton(
                buttonKey: ValueKey('font-set-uninstall-${set.name}'),
                tooltip: '卸载',
                icon: const LineIcon(
                  LucideIcons.trash2,
                  size: FontSetPicker.smallIcon,
                ),
                iconSize: FontSetPicker.smallIcon,
                material: false,
                onPressed: () => widget.onUninstall(set),
              ),
          ],
        ),
      ),
    );
  }

  Widget _progress(BuildContext context, FontDownload download) {
    final secondary = Theme.of(context).colorScheme.onSurfaceVariant;
    final fraction = download.total == 0
        ? 1.0
        : download.received / download.total;
    return Padding(
      padding: const EdgeInsets.only(
        left: GlassMetrics.rowIconSize + GlassMetrics.rowIconGap,
        bottom: GlassMetrics.space8,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '正在下载 ${download.set.label} · ${(fraction * 100).floor()}%'
                  '（${FontSetPicker.megabytes(download.received)} / '
                  '${FontSetPicker.megabytes(download.total)}）',
                  style: Theme.of(context).textTheme.bodySmall!
                      .copyWith(color: secondary),
                ),
                const SizedBox(height: GlassMetrics.space4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(
                    FontSetPicker.progressHeight / 2,
                  ),
                  child: LinearProgressIndicator(
                    key: const ValueKey('font-download-progress'),
                    value: fraction,
                    minHeight: FontSetPicker.progressHeight,
                    color: NativeGlassTheme.accentOf(context),
                    backgroundColor: secondary.withValues(alpha: 0.2),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: GlassMetrics.space12),
          NativeGlassSurface(
            material: true,
            child: TextButton(
              key: const ValueKey('font-download-cancel'),
              onPressed: widget.onCancel,
              child: const Text('取消'),
            ),
          ),
        ],
      ),
    );
  }
}
