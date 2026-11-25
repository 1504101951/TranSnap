import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../common/constants/glass_metrics.dart';
import '../common/utils/date_text.dart';
import '../common/widgets/native_glass.dart';
import 'screenshot_history.dart';

class StitchDialog extends StatefulWidget {
  const StitchDialog({super.key, required this.count});

  final int count;

  @override
  State<StitchDialog> createState() => _StitchDialogState();
}

class _StitchDialogState extends State<StitchDialog> {
  bool _vertical = true;

  @override
  Widget build(BuildContext context) => NativeGlassDialog(
    title: Text('拼接 ${widget.count} 张截图'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        NativeGlassSegments<bool>(
          value: _vertical,
          options: const {true: '纵向', false: '横向'},
          onChanged: (value) => setState(() => _vertical = value),
        ),
        const SizedBox(height: 12),
        Text(
          '按截图时间先后排列，不缩放；尺寸不同时居中，空白处透明。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    ),
    actions: [
      NativeGlassSurface(
        material: true,
        child: TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
      ),
      NativeGlassSurface(
        material: true,
        child: FilledButton(
          onPressed: () => Navigator.pop(context, _vertical),
          child: const Text('拼接'),
        ),
      ),
    ],
  );
}

class SplitDialog extends StatefulWidget {
  const SplitDialog({super.key, required this.height});

  final int height;

  @override
  State<SplitDialog> createState() => _SplitDialogState();
}

class _SplitDialogState extends State<SplitDialog> {
  int _parts = 2;

  @override
  Widget build(BuildContext context) {
    final maxParts = math.min(10, widget.height);
    final canSplit = maxParts >= 2;
    final selected = canSplit ? _parts.clamp(2, maxParts) : 2;
    return NativeGlassDialog(
      title: const Text('拆分截图'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!canSplit)
            const NativeGlassBanner(
              message: '截图高度不足 2 像素，无法拆分。',
              isError: true,
            )
          else ...[
            NativeGlassDropdown<int>(
              label: '段数',
              value: selected,
              items: {
                for (var parts = 2; parts <= maxParts; parts++) parts: '$parts 段',
              },
              onChanged: (value) => setState(() => _parts = value),
            ),
            const SizedBox(height: GlassMetrics.space8),
            Text(
              '按高度等分，余数并入最后一段。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ],
      ),
      actions: [
        NativeGlassSurface(
          material: true,
          child: TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
        ),
        NativeGlassSurface(
          material: true,
          child: FilledButton(
            onPressed: canSplit ? () => Navigator.pop(context, selected) : null,
            child: const Text('拆分'),
          ),
        ),
      ],
    );
  }
}

class ScreenshotCompareDialog extends StatefulWidget {
  const ScreenshotCompareDialog({
    super.key,
    required this.first,
    required this.second,
    required this.mask,
    required this.different,
    required this.total,
  });

  final ScreenshotRecord first;
  final ScreenshotRecord second;
  final Uint8List mask;
  final int different;
  final int total;

  static const maxWidth = 960.0;

  static const gap = 12.0;

  @override
  State<ScreenshotCompareDialog> createState() =>
      _ScreenshotCompareDialogState();
}

class _ScreenshotCompareDialogState extends State<ScreenshotCompareDialog> {
  bool _highlight = true;

  Widget _side(String label, ScreenshotRecord record) {
    final width = math.max(1, math.max(widget.first.width, widget.second.width));
    final height = math.max(
      1,
      math.max(widget.first.height, widget.second.height),
    );
    final captured = DateTime.fromMillisecondsSinceEpoch(record.capturedAt);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '$label · ${dateTimeText(captured)} · ${record.width}×${record.height}',
          style: Theme.of(context).textTheme.bodySmall,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: GlassMetrics.space4),
        Flexible(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(GlassMetrics.controlRadius),
            child: InteractiveViewer(
              minScale: 1.0,
              maxScale: 8.0,
              child: FittedBox(
                child: SizedBox(
                  width: width.toDouble(),
                  height: height.toDouble(),
                  child: Stack(
                    children: [
                      if (record.width > 0 && record.height > 0)
                        Positioned(
                          left: 0,
                          top: 0,
                          width: record.width.toDouble(),
                          height: record.height.toDouble(),
                          child: Image.file(
                            File(record.path),
                            fit: BoxFit.fill,
                            errorBuilder: (context, error, stackTrace) =>
                                ColoredBox(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.surfaceContainerHighest,
                                  child: Center(
                                    child: FittedBox(
                                      fit: BoxFit.scaleDown,
                                      child: Padding(
                                        padding: const EdgeInsets.all(
                                          GlassMetrics.space8,
                                        ),
                                        child: Text(
                                          '截图文件不可用',
                                          style: Theme.of(
                                            context,
                                          ).textTheme.bodySmall,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                          ),
                        ),
                      if (_highlight)
                        Positioned.fill(
                          child: Image.memory(
                            widget.mask,
                            fit: BoxFit.fill,
                            filterQuality: FilterQuality.none,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => NativeGlassDialog(
    maxWidth: ScreenshotCompareDialog.maxWidth,
    title: const Text('比较截图'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Flexible(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _side('较早', widget.first)),
              const SizedBox(width: ScreenshotCompareDialog.gap),
              Expanded(child: _side('较晚', widget.second)),
            ],
          ),
        ),
        const SizedBox(height: GlassMetrics.space8),
        NativeGlassSwitchTile(
          title: '高亮差异',
          value: _highlight,
          onChanged: (value) => setState(() => _highlight = value),
        ),
        const SizedBox(height: GlassMetrics.space8),
        Text(
          widget.total <= 0
              ? '无法统计差异像素'
              : widget.different == 0
              ? '两张截图像素完全一致'
              : '差异像素 ${widget.different} / 总像素 ${widget.total}'
                    '（${(widget.different / widget.total * 100).toStringAsFixed(2)}%）',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    ),
    actions: [
      NativeGlassSurface(
        material: true,
        child: FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('完成'),
        ),
      ),
    ],
  );
}
