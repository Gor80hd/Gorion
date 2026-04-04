import 'dart:async';

import 'package:flutter/material.dart';

class PageReveal extends StatefulWidget {
  const PageReveal({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.duration = const Duration(milliseconds: 260),
    this.curve = Curves.easeOutCubic,
    this.offset = const Offset(0, 0.04),
  });

  final Widget child;
  final Duration delay;
  final Duration duration;
  final Curve curve;
  final Offset offset;

  @override
  State<PageReveal> createState() => _PageRevealState();
}

class _PageRevealState extends State<PageReveal> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(duration: widget.duration, vsync: this);
  Timer? _delayTimer;
  bool? _lastTickerModeEnabled;

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _delayTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant PageReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.duration != widget.duration) {
      _controller.duration = widget.duration;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final tickerModeEnabled = TickerMode.valuesOf(context).enabled;

    if (_lastTickerModeEnabled == tickerModeEnabled) return;
    _lastTickerModeEnabled = tickerModeEnabled;

    if (tickerModeEnabled) {
      _restartAnimation();
    } else {
      _delayTimer?.cancel();
      _controller.reset();
    }
  }

  @override
  Widget build(BuildContext context) {
    final animation = CurvedAnimation(parent: _controller, curve: widget.curve);

    return FadeTransition(
      opacity: animation,
      child: SlideTransition(
        position: Tween<Offset>(begin: widget.offset, end: Offset.zero).animate(animation),
        child: widget.child,
      ),
    );
  }

  void _restartAnimation() {
    _delayTimer?.cancel();
    _controller.reset();

    if (widget.delay == Duration.zero) {
      _controller.forward();
      return;
    }

    _delayTimer = Timer(widget.delay, () {
      if (mounted) {
        _controller.forward();
      }
    });
  }
}
