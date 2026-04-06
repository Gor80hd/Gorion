import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:gorion_clean/app/theme.dart';
import 'package:gorion_clean/core/widget/glass_panel.dart';
import 'package:gorion_clean/features/home/application/dashboard_controller.dart';
import 'package:gorion_clean/features/settings/widget/settings_page.dart';
import 'package:window_manager/window_manager.dart';

const _dockLeftMargin = 10.0;
const _dockVerticalMargin = 15.0;
const _dockWidth = 67.0;
const _dockGap = 12.0;
const _titleBarHeight = 48.0;
const _dockTopGap = 10.0;

class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> with WindowListener {
  _DockPage _currentPage = _DockPage.home;
  AppLifecycleListener? _appLifecycleListener;
  Future<void>? _shutdownFuture;
  bool _windowDestroyInProgress = false;

  bool get _isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  @override
  void initState() {
    super.initState();
    _appLifecycleListener = AppLifecycleListener(
      onExitRequested: _handleAppExitRequest,
    );
    if (_isDesktop) {
      windowManager.addListener(this);
      unawaited(windowManager.setPreventClose(true));
    }
  }

  @override
  void dispose() {
    if (_isDesktop) {
      windowManager.removeListener(this);
    }
    _appLifecycleListener?.dispose();
    super.dispose();
  }

  @override
  void onWindowClose() {
    if (_windowDestroyInProgress) {
      return;
    }
    unawaited(_closeWindowGracefully());
  }

  Future<AppExitResponse> _handleAppExitRequest() async {
    await _shutdownBeforeExit();
    return AppExitResponse.exit;
  }

  Future<void> _closeWindowGracefully() async {
    await _shutdownBeforeExit();
    if (!_isDesktop || _windowDestroyInProgress) {
      return;
    }

    _windowDestroyInProgress = true;
    await windowManager.destroy();
  }

  Future<void> _shutdownBeforeExit() {
    return _shutdownFuture ??= _performShutdown().whenComplete(() {
      _shutdownFuture = null;
    });
  }

  Future<void> _performShutdown() async {
    try {
      await ref.read(dashboardControllerProvider.notifier).shutdownForAppExit();
    } on Object {
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final viewPadding = MediaQuery.viewPaddingOf(context);
    final topInset = math.max(
      _dockVerticalMargin,
      viewPadding.top + _dockVerticalMargin,
    );
    final rightInset = math.max(
      _dockVerticalMargin,
      viewPadding.right + _dockVerticalMargin,
    );
    final bottomInset = math.max(
      _dockVerticalMargin,
      viewPadding.bottom + _dockVerticalMargin,
    );
    final leftInset = math.max(
      _dockLeftMargin,
      viewPadding.left + _dockLeftMargin,
    );

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: DecoratedBox(
        decoration: const BoxDecoration(gradient: gorionAppBackgroundGradient),
        child: Stack(
          fit: StackFit.expand,
          children: [
            const _BackgroundAtmosphere(),
            Padding(
              padding: EdgeInsets.fromLTRB(
                leftInset + _dockWidth + _dockGap,
                topInset + 8,
                rightInset,
                bottomInset,
              ),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeOutCubic,
                child: KeyedSubtree(
                  key: ValueKey(_currentPage),
                  child: _currentPage == _DockPage.home
                      ? widget.child
                      : const SettingsPage(),
                ),
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: _TitleBar(
                topInset: topInset,
                leftInset: leftInset,
                rightInset: rightInset,
              ),
            ),
            Positioned(
              left: leftInset,
              top: topInset + _titleBarHeight + _dockTopGap,
              bottom: bottomInset,
              child: _Dock(
                current: _currentPage,
                onSelect: (page) {
                  if (_currentPage == page) {
                    return;
                  }
                  setState(() => _currentPage = page);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BackgroundAtmosphere extends StatelessWidget {
  const _BackgroundAtmosphere();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Stack(
        children: [
          const Positioned(
            left: -180,
            top: -140,
            child: _GlowOrb(size: 380, color: Color(0x221EFFAC)),
          ),
          const Positioned(
            right: -90,
            top: 80,
            child: _GlowOrb(size: 240, color: Color(0x160E865E)),
          ),
          const Positioned(
            right: 120,
            bottom: -180,
            child: _GlowOrb(size: 420, color: Color(0x160DA06B)),
          ),
        ],
      ),
    );
  }
}

class _GlowOrb extends StatelessWidget {
  const _GlowOrb({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: color,
            blurRadius: size * 0.42,
            spreadRadius: size * 0.06,
          ),
        ],
      ),
    );
  }
}

class _TitleBar extends StatelessWidget {
  const _TitleBar({
    required this.topInset,
    required this.leftInset,
    required this.rightInset,
  });

  static const double _height = _titleBarHeight;
  static const double _windowControlsWidth = 122;

  final double topInset;
  final double leftInset;
  final double rightInset;

  @override
  Widget build(BuildContext context) {
    final isDesktop =
        Platform.isWindows || Platform.isLinux || Platform.isMacOS;
    return SizedBox(
      height: topInset + _height,
      child: Stack(
        children: [
          if (isDesktop)
            Positioned.fill(
              child: DragToMoveArea(
                child: Padding(
                  padding: EdgeInsets.only(
                    top: topInset,
                    left: leftInset,
                    right: rightInset + _windowControlsWidth,
                  ),
                  child: const Align(
                    alignment: Alignment.topLeft,
                    child: _TitleContent(),
                  ),
                ),
              ),
            )
          else
            Padding(
              padding: EdgeInsets.only(
                top: topInset,
                left: leftInset,
                right: rightInset,
              ),
              child: const Align(
                alignment: Alignment.topLeft,
                child: _TitleContent(),
              ),
            ),
          if (isDesktop)
            Positioned(
              top: topInset,
              right: rightInset,
              child: const _WindowControls(),
            ),
        ],
      ),
    );
  }
}

class _TitleContent extends StatelessWidget {
  const _TitleContent();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 1, right: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SvgPicture.asset(
            'assets/images/logo.svg',
            width: 20,
            height: 20,
            colorFilter: const ColorFilter.mode(gorionAccent, BlendMode.srcIn),
          ),
          const SizedBox(width: 10),
          const Text(
            'gorion',
            style: TextStyle(
              fontFamily: 'IBMPlexSans',
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: gorionOnSurface,
              letterSpacing: 0.4,
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              color: gorionAccent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(999),
            ),
            child: const Text(
              '0.0.4 beta',
              style: TextStyle(
                fontFamily: 'IBMPlexSans',
                fontSize: 10,
                fontWeight: FontWeight.w500,
                color: gorionAccent,
                letterSpacing: 0.2,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _WindowControls extends StatefulWidget {
  const _WindowControls();

  @override
  State<_WindowControls> createState() => _WindowControlsState();
}

class _WindowControlsState extends State<_WindowControls> with WindowListener {
  bool _isMaximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    windowManager.isMaximized().then((v) {
      if (mounted) setState(() => _isMaximized = v);
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() => setState(() => _isMaximized = true);

  @override
  void onWindowUnmaximize() => setState(() => _isMaximized = false);

  @override
  Widget build(BuildContext context) {
    return GlassPanel(
      height: _TitleBar._height,
      borderRadius: 18,
      padding: const EdgeInsets.all(4),
      opacity: 0.22,
      backgroundColor: gorionSurface,
      strokeColor: Colors.white,
      strokeOpacity: 0.1,
      strokeWidth: 1,
      boxShadow: const [
        BoxShadow(
          color: Color(0x26000000),
          blurRadius: 24,
          offset: Offset(0, 10),
        ),
      ],
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _WinBtn(
            onTap: () => windowManager.minimize(),
            child: Container(
              width: 10,
              height: 1.5,
              color: gorionOnSurfaceMuted,
            ),
          ),
          _WinBtn(
            onTap: () async {
              if (await windowManager.isMaximized()) {
                await windowManager.unmaximize();
              } else {
                await windowManager.maximize();
              }
            },
            child: _isMaximized
                ? _RestoreIcon()
                : Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: gorionOnSurfaceMuted,
                        width: 1.2,
                      ),
                    ),
                  ),
          ),
          _WinBtn(
            isClose: true,
            onTap: () => windowManager.close(),
            child: const Icon(
              Icons.close_rounded,
              size: 14,
              color: gorionOnSurface,
            ),
          ),
        ],
      ),
    );
  }
}

class _WinBtn extends StatefulWidget {
  const _WinBtn({
    required this.child,
    required this.onTap,
    this.isClose = false,
  });

  final Widget child;
  final VoidCallback onTap;
  final bool isClose;

  @override
  State<_WinBtn> createState() => _WinBtnState();
}

class _WinBtnState extends State<_WinBtn> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final bgHover = widget.isClose
        ? const Color(0xFFEF4444)
        : gorionAccent.withValues(alpha: 0.12);
    return GestureDetector(
      onTap: widget.onTap,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: _hover ? bgHover : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          alignment: Alignment.center,
          child: widget.child,
        ),
      ),
    );
  }
}

class _RestoreIcon extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 12,
      height: 12,
      child: CustomPaint(painter: _RestorePainter()),
    );
  }
}

class _RestorePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = gorionOnSurfaceMuted
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    canvas.drawRect(
      Rect.fromLTWH(2, 0, size.width - 2, size.height - 2),
      paint,
    );
    canvas.drawRect(
      Rect.fromLTWH(0, 2, size.width - 2, size.height - 2),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

enum _DockPage { home, settings }

class _Dock extends StatelessWidget {
  const _Dock({required this.current, required this.onSelect});

  final _DockPage current;
  final ValueChanged<_DockPage> onSelect;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _dockWidth,
      child: GlassPanel(
        borderRadius: 24,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
        opacity: 0.05,
        backgroundColor: Colors.white,
        strokeColor: Colors.white,
        strokeOpacity: 0.0,
        strokeWidth: 1,
        showGlow: false,
        glowBlur: 10,
        boxShadow: const [
          BoxShadow(
            color: Color(0x22000000),
            blurRadius: 20,
            offset: Offset(0, 14),
          ),
        ],
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _DockBtn(
              icon: Icons.language_rounded,
              label: 'Главная',
              selected: current == _DockPage.home,
              onTap: () => onSelect(_DockPage.home),
            ),
            const SizedBox(height: 12),
            Container(
              width: 18,
              height: 1,
              color: Colors.white.withValues(alpha: 0.1),
            ),
            const Spacer(),
            _DockBtn(
              icon: Icons.settings_outlined,
              label: 'Настройки',
              selected: current == _DockPage.settings,
              onTap: () => onSelect(_DockPage.settings),
            ),
            const SizedBox(height: 2),
          ],
        ),
      ),
    );
  }
}

class _DockBtn extends StatefulWidget {
  const _DockBtn({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_DockBtn> createState() => _DockBtnState();
}

class _DockBtnState extends State<_DockBtn> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final color = widget.selected
        ? gorionAccent
        : _hover
        ? gorionOnSurface
        : gorionOnSurfaceMuted;
    final borderColor = widget.selected
        ? gorionAccent.withValues(alpha: 0.28)
        : Colors.white.withValues(alpha: _hover ? 0.12 : 0.06);

    return Tooltip(
      message: widget.label,
      preferBelow: false,
      waitDuration: const Duration(milliseconds: 600),
      child: GestureDetector(
        onTap: widget.onTap,
        child: MouseRegion(
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: widget.selected
                  ? null
                  : _hover
                  ? Colors.white.withValues(alpha: 0.06)
                  : Colors.transparent,
              gradient: widget.selected
                  ? LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        gorionAccent.withValues(alpha: 0.2),
                        gorionAccent.withValues(alpha: 0.08),
                      ],
                    )
                  : null,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: borderColor),
              boxShadow: widget.selected
                  ? [
                      BoxShadow(
                        color: gorionAccent.withValues(alpha: 0.18),
                        blurRadius: 20,
                        spreadRadius: -6,
                      ),
                    ]
                  : null,
            ),
            alignment: Alignment.center,
            child: Icon(widget.icon, size: 20, color: color),
          ),
        ),
      ),
    );
  }
}
