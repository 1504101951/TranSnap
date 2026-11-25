import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../common/widgets/line_icon.dart';
import '../common/constants/drawing_metrics.dart';
import '../common/constants/emoji_catalog.dart';
import '../common/constants/glass_metrics.dart';
import '../common/widgets/native_glass.dart';
import 'stickers.dart';

sealed class StickerChoice {
  const StickerChoice();
}

final class PickedEmoji extends StickerChoice {
  const PickedEmoji(this.emoji);
  final String emoji;
}

final class PickedSticker extends StickerChoice {
  const PickedSticker(this.entry);
  final StickerEntry entry;
}

final class ManageStickers extends StickerChoice {
  const ManageStickers();
}

enum _StickerTab { emoji, mine }

class StickerPanel extends StatefulWidget {
  const StickerPanel({
    super.key,
    required this.stickers,
    required this.directory,
  });
  final List<StickerEntry> stickers;
  final String directory;

  @override
  State<StickerPanel> createState() => _StickerPanelState();
}

class _StickerPanelState extends State<StickerPanel> {
  _StickerTab _tab = _StickerTab.emoji;

  static const _gridDelegate = SliverGridDelegateWithFixedCrossAxisCount(
    crossAxisCount: StickerMetrics.panelColumns,
    mainAxisSpacing: StickerMetrics.panelGap,
    crossAxisSpacing: StickerMetrics.panelGap,
  );

  Widget _buildEmoji(BuildContext context) {
    final secondary = Theme.of(context).colorScheme.onSurfaceVariant;
    return CustomScrollView(
      slivers: [
        for (final group in EmojiCatalog.groups) ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(
                vertical: StickerMetrics.categoryPadding,
              ),
              child: Text(
                group.title,
                style: TextStyle(
                  fontSize: StickerMetrics.categoryFontSize,
                  fontWeight: FontWeight.w600,
                  color: secondary,
                ),
              ),
            ),
          ),
          SliverGrid(
            gridDelegate: _gridDelegate,
            delegate: SliverChildBuilderDelegate((context, index) {
              final emoji = group.emoji[index];
              return InkWell(
                key: ValueKey('emoji-cell-$emoji'),
                borderRadius: BorderRadius.circular(StickerMetrics.cellRadius),
                onTap: () => Navigator.pop(context, PickedEmoji(emoji)),
                child: Center(
                  child: Text(
                    emoji,
                    style: const TextStyle(
                      fontSize: StickerMetrics.emojiFontSize,
                    ),
                  ),
                ),
              );
            }, childCount: group.emoji.length),
          ),
        ],
      ],
    );
  }

  Widget _buildMine(BuildContext context) {
    if (widget.stickers.isEmpty) {
      return Center(
        child: Text('还没有贴纸', style: Theme.of(context).textTheme.bodySmall),
      );
    }
    return GridView.builder(
      gridDelegate: _gridDelegate,
      itemCount: widget.stickers.length,
      itemBuilder: (context, index) {
        final sticker = widget.stickers[index];
        return Tooltip(
          message: '贴纸',
          child: InkWell(
            key: ValueKey('sticker-cell-${sticker.id}'),
            borderRadius: BorderRadius.circular(StickerMetrics.cellRadius),
            onTap: () => Navigator.pop(context, PickedSticker(sticker)),
            child: Image.file(
              File('${widget.directory}/${sticker.id}.png'),
              fit: BoxFit.contain,
              errorBuilder: (context, error, stackTrace) => LineIcon(
                LucideIcons.imageOff,
                size: GlassMetrics.icon,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                semanticLabel: '贴纸加载失败',
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final mine = _tab == _StickerTab.mine;
    return Material(
      type: MaterialType.transparency,
      child: NativeGlassSurface(
        material: true,
        radius: GlassMetrics.menuRadius,
        child: SizedBox(
          width: StickerMetrics.panelWidth,
          child: Padding(
            padding: const EdgeInsets.all(DrawingMetrics.padding),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: NativeGlassSegments<_StickerTab>(
                    value: _tab,
                    options: const {
                      _StickerTab.emoji: 'Emoji',
                      _StickerTab.mine: '贴纸',
                    },
                    onChanged: (tab) => setState(() => _tab = tab),
                  ),
                ),
                const SizedBox(height: StickerMetrics.actionGap),
                SizedBox(
                  height: StickerMetrics.gridHeight,
                  child: mine ? _buildMine(context) : _buildEmoji(context),
                ),
                const SizedBox(height: StickerMetrics.actionGap),
                SizedBox(
                  height: GlassMetrics.hitSize,
                  child: NativeGlassSurface(
                    material: true,
                    child: TextButton(
                      key: const ValueKey('sticker-manage'),
                      onPressed: () =>
                          Navigator.pop(context, const ManageStickers()),
                      child: const Text('管理贴纸…'),
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
}

class StickerPanelLayout extends SingleChildLayoutDelegate {
  const StickerPanelLayout(this.anchor);
  final Rect? anchor;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    const gap = StickerMetrics.anchorGap;
    final maxLeft = math.max(gap, size.width - childSize.width - gap);
    final maxTop = math.max(gap, size.height - childSize.height - gap);
    final anchor = this.anchor;
    if (anchor == null) {
      return Offset(
        ((size.width - childSize.width) / 2).clamp(0.0, maxLeft).toDouble(),
        ((size.height - childSize.height) / 2).clamp(0.0, maxTop).toDouble(),
      );
    }
    final left = anchor.left.clamp(gap, maxLeft).toDouble();
    final below = anchor.bottom + gap;
    final fitsBelow = below + childSize.height <= size.height - gap;
    final rawTop = fitsBelow ? below : anchor.top - gap - childSize.height;
    return Offset(left, rawTop.clamp(gap, maxTop).toDouble());
  }

  @override
  bool shouldRelayout(StickerPanelLayout oldDelegate) =>
      oldDelegate.anchor != anchor;
}
