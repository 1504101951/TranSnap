import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../common/widgets/line_icon.dart';
import '../common/constants/glass_metrics.dart';
import '../common/constants/screenshot_enums.dart';
import '../common/widgets/app_motion.dart';
import '../common/widgets/glass_icon_button.dart';
import '../common/widgets/native_glass.dart';
import 'markdown_view.dart';

typedef RecognizedCode = ({String symbology, String payload});

bool isOpenableLink(String payload) {
  final uri = Uri.tryParse(payload);
  return uri != null &&
      ScreenshotDefaults.openableLinkSchemes.contains(
        uri.scheme.toLowerCase(),
      ) &&
      uri.host.isNotEmpty;
}

class RecognizedTextPanel extends StatefulWidget {
  const RecognizedTextPanel({
    super.key,
    required this.text,
    this.codes = const [],
    required this.onCopyAll,
    required this.onCopyCode,
    required this.onOpenLink,
    required this.onClose,
    required this.onDrag,
  });

  static const size = Size(720, 420);
  final String text;
  final List<RecognizedCode> codes;
  final VoidCallback onCopyAll;
  final ValueChanged<String> onCopyCode;
  final ValueChanged<String> onOpenLink;
  final VoidCallback onClose;
  final ValueChanged<Offset> onDrag;

  @override
  State<RecognizedTextPanel> createState() => _RecognizedTextPanelState();
}

class _RecognizedTextPanelState extends State<RecognizedTextPanel> {
  int _copyAllTrigger = 0;
  final Map<int, int> _codeCopyTriggers = <int, int>{};

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return BouncyPresence(
      fromScale: 0.94,
      child: OpticalPrismOverlay(
        radius: GlassMetrics.panelRadius,
        child: NativeGlassSurface(
          child: Padding(
            padding: const EdgeInsets.all(GlassMetrics.pagePadding),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  height: 44,
                  child: Row(
                    children: [
                      Expanded(
                        child: MouseRegion(
                          cursor: SystemMouseCursors.move,
                          child: GestureDetector(
                            key: const ValueKey('recognized-text-drag-area'),
                            behavior: HitTestBehavior.opaque,
                            onPanUpdate: (details) =>
                                widget.onDrag(details.delta),
                            child: Row(
                              children: [
                                LineIcon(
                                  LucideIcons.gripVertical,
                                  size: GlassMetrics.icon,
                                  color: colors.onSurfaceVariant,
                                ),
                                const SizedBox(width: 8),
                                const Text(
                                  '识别结果',
                                  style: TextStyle(fontWeight: FontWeight.w600),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      if (widget.text.trim().isNotEmpty) ...[
                        GlassIconButton(
                          tooltip: '复制全部',
                          onPressed: () {
                            setState(() => _copyAllTrigger++);
                            widget.onCopyAll();
                          },
                          icon: CopyConfirmIcon(
                            trigger: _copyAllTrigger,
                            size: GlassMetrics.icon,
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                      GlassIconButton(
                        tooltip: '关闭',
                        onPressed: widget.onClose,
                        icon: const LineIcon(
                          LucideIcons.x,
                          size: GlassMetrics.icon,
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(
                  height: GlassMetrics.groupDividerThickness,
                  thickness: GlassMetrics.groupDividerThickness,
                ),
                Expanded(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: colors.surface.withValues(alpha: 0.92),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: SizedBox.expand(
                      child: SingleChildScrollView(
                        primary: false,
                        padding: const EdgeInsets.all(8),
                        child: SelectionArea(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (var i = 0; i < widget.codes.length; i++)
                                _CodeRow(
                                  code: widget.codes[i],
                                  copyTrigger: _codeCopyTriggers[i] ?? 0,
                                  onCopy: () {
                                    setState(
                                      () => _codeCopyTriggers[i] =
                                          (_codeCopyTriggers[i] ?? 0) + 1,
                                    );
                                    widget.onCopyCode(widget.codes[i].payload);
                                  },
                                  onOpen:
                                      isOpenableLink(widget.codes[i].payload)
                                      ? () => widget.onOpenLink(
                                          widget.codes[i].payload,
                                        )
                                      : null,
                                ),
                              if (widget.text.trim().isNotEmpty)
                                MarkdownView(source: widget.text),
                            ],
                          ),
                        ),
                      ),
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

class _CodeRow extends StatelessWidget {
  const _CodeRow({
    required this.code,
    this.copyTrigger = 0,
    required this.onCopy,
    this.onOpen,
  });

  final RecognizedCode code;
  final int copyTrigger;
  final VoidCallback onCopy;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final kind = code.symbology == 'qr'
        ? '二维码'
        : '条码 · ${code.symbology.toUpperCase()}';
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  kind,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: colors.onSurfaceVariant,
                  ),
                ),
                Text(
                  code.payload,
                  style: const TextStyle(fontSize: GlassMetrics.bodyFont),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          GlassIconButton(
            tooltip: '复制内容',
            onPressed: onCopy,
            icon: CopyConfirmIcon(
              trigger: copyTrigger,
              size: GlassMetrics.icon,
            ),
          ),
          if (onOpen != null) ...[
            const SizedBox(width: 8),
            GlassIconButton(
              tooltip: '打开链接',
              onPressed: onOpen,
              icon: const LineIcon(
                LucideIcons.externalLink,
                size: GlassMetrics.icon,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
