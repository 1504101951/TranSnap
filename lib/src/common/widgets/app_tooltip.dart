import 'dart:async';

import 'package:flutter/material.dart';

class AppTooltipScope extends InheritedWidget {
  const AppTooltipScope({
    super.key,
    required this.onShow,
    required this.onHide,
    required super.child,
  });

  final void Function(String message, Rect anchor, bool preferAbove) onShow;
  final VoidCallback onHide;

  static AppTooltipScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppTooltipScope>();

  @override
  bool updateShouldNotify(AppTooltipScope oldWidget) =>
      onShow != oldWidget.onShow || onHide != oldWidget.onHide;
}

class AppTooltip extends StatefulWidget {
  const AppTooltip({
    super.key,
    required this.message,
    required this.child,
    this.preferAbove = true,
    this.waitDuration = const Duration(milliseconds: 200),
  });

  final String message;
  final Widget child;
  final bool preferAbove;
  final Duration waitDuration;

  @override
  State<AppTooltip> createState() => _AppTooltipState();
}

class _AppTooltipState extends State<AppTooltip> {
  Timer? _timer;
  bool _hovered = false;
  bool _shown = false;
  AppTooltipScope? _scope;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scope = AppTooltipScope.maybeOf(context);
  }

  @override
  void didUpdateWidget(AppTooltip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_shown &&
        (oldWidget.message != widget.message ||
            oldWidget.preferAbove != widget.preferAbove)) {
      _dispatchShow();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    if (_shown) {
      _scope?.onHide();
    }
    super.dispose();
  }

  void _scheduleShow() {
    _hovered = true;
    _timer?.cancel();
    _timer = Timer(widget.waitDuration, () {
      if (!mounted || !_hovered) return;
      _dispatchShow();
    });
  }

  void _dispatchShow() {
    final scope = _scope;
    if (scope == null) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize || !box.attached) return;
    final origin = box.localToGlobal(Offset.zero);
    _shown = true;
    scope.onShow(widget.message, origin & box.size, widget.preferAbove);
  }

  void _hide() {
    _hovered = false;
    _timer?.cancel();
    if (!_shown) return;
    _shown = false;
    _scope?.onHide();
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppTooltipScope.maybeOf(context);
    if (scope == null) {
      return Tooltip(
        message: widget.message,
        preferBelow: !widget.preferAbove,
        waitDuration: widget.waitDuration,
        child: widget.child,
      );
    }
    return Semantics(
      tooltip: widget.message,
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => _hide(),
        child: MouseRegion(
          onEnter: (_) => _scheduleShow(),
          onExit: (_) => _hide(),
          child: widget.child,
        ),
      ),
    );
  }
}
