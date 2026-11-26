import 'dart:ui' as ui;
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

import '../common/constants/drawing_metrics.dart';
import '../common/constants/glass_metrics.dart';
import '../common/constants/screenshot_enums.dart';
import '../common/utils/geometry.dart';
import '../common/widgets/app_motion.dart';
import '../common/widgets/native_glass.dart';
import '../common/widgets/result_window.dart';
import '../common/widgets/native_resize_cursor.dart';
import 'beautify.dart';
import 'edit_document.dart';
import 'measure_layer.dart';
import 'box_transform.dart';
import 'screenshot_editor_layout.dart';
import '../common/constants/toolbar_grid.dart';

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

class EditorSurface extends StatefulWidget {
  const EditorSurface({
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
  final List<OcrOverlay> ocrOverlays;

  @override
  State<EditorSurface> createState() => _EditorSurfaceState();
}

class _EditorSurfaceState extends State<EditorSurface> {
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
            shiftedToolbar.left
                .clamp(safeBounds.left, maxToolbarLeft)
                .toDouble(),
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
                            width: math.max(constraints.maxWidth, paddedWidth),
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
                            fitted.width /
                            (imageSize.width / widget.pixelRatio),
                        showHandles: widget.cropSelected,
                        windows: widget.recordingWindows
                            ?.map(
                              (rect) =>
                                  mapRectToFitted(rect, imageSize, fitted),
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

class OcrOverlay {
  const OcrOverlay({required this.text, required this.rect});

  factory OcrOverlay.fromMap(Map<Object?, Object?> map, Offset origin) =>
      OcrOverlay(
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
