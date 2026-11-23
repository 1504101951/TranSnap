import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../common/constants/glass_metrics.dart';
import '../common/utils/date_text.dart';
import '../common/widgets/native_glass.dart';
import 'screenshot_history.dart';

/// 拼接截图前选择方向的弹窗；确定返回 true（纵向）或 false（横向），取消返回 null（#109）。
class StitchDialog extends StatefulWidget {
  /// count 为参与拼接的截图张数，用于标题。
  const StitchDialog({super.key, required this.count});

  final int count;

  /// 无参数；返回持有方向选择的状态。
  @override
  State<StitchDialog> createState() => _StitchDialogState();
}

/// 持有当前选择的拼接方向，默认纵向。
class _StitchDialogState extends State<StitchDialog> {
  bool _vertical = true;

  /// context 为弹窗上下文；返回方向分段与取消/拼接操作。
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

/// 拆分截图前选择段数的弹窗；确定返回段数，高度不足 2 像素时禁用拆分，取消返回 null（#109）。
class SplitDialog extends StatefulWidget {
  /// height 为图片像素高度；段数为 2–10 且不超过该高度。
  const SplitDialog({super.key, required this.height});

  final int height;

  /// 无参数；返回持有段数选择的状态。
  @override
  State<SplitDialog> createState() => _SplitDialogState();
}

/// 持有当前选择的段数，默认 2 段。
class _SplitDialogState extends State<SplitDialog> {
  int _parts = 2;

  /// context 为弹窗上下文；返回段数下拉（或过矮图片错误提示）与取消/拆分操作。
  @override
  Widget build(BuildContext context) {
    final maxParts = math.min(10, widget.height);
    final canSplit = maxParts >= 2;
    // 组件参数可能在弹窗存活期间变更，始终把已选段数钳位到合法范围，防止 Dropdown 断言失败。
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

/// 并排比较两张截图的弹窗；两图左上角对齐到同一画布，可开关差异高亮（#109）。
class ScreenshotCompareDialog extends StatefulWidget {
  /// first/second 为较早与较晚的截图，mask 为原生生成的画布大小差异蒙版 PNG，
  /// different/total 为不同像素数与画布总像素数。
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

  /// 弹窗最大宽度（点），受窗口宽度限制。
  static const maxWidth = 960.0;

  /// 两图之间的间距（点）。
  static const gap = 12.0;

  /// 无参数；返回持有高亮开关的状态。
  @override
  State<ScreenshotCompareDialog> createState() =>
      _ScreenshotCompareDialogState();
}

/// 持有「高亮差异」开关，默认开启。
class _ScreenshotCompareDialogState extends State<ScreenshotCompareDialog> {
  bool _highlight = true;

  /// label 为时间端标签，record 为一侧截图；返回带时间分辨率标识、可缩放且缺失文件可降级的比较画面。
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
            // 允许缩放比较图并裁切到圆角边框内，防止放大时溢出相邻列。
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

  /// context 为弹窗上下文；返回并排的两图、高亮开关、差异摘要与完成操作。
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
          // 原生未产出有效画布像素时不计算百分比，避免除零显示 NaN/Infinity。
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
