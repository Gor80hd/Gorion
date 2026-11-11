part of 'shell.dart';

class _BackgroundAtmosphere extends StatelessWidget {
  const _BackgroundAtmosphere();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (isDark) {
      return const SizedBox.shrink();
    }

    final tokens = context.gorionTokens;

    return IgnorePointer(
      child: Stack(
        children: [
          for (var index = 0; index < _backgroundOrbs.length; index += 1)
            Positioned(
              left: _backgroundOrbs[index].left,
              right: _backgroundOrbs[index].right,
              top: _backgroundOrbs[index].top,
              bottom: _backgroundOrbs[index].bottom,
              child: _GlowOrb(
                size: _backgroundOrbs[index].size,
                color: switch (index) {
                  0 => tokens.atmospherePrimary,
                  1 => tokens.atmosphereSecondary,
                  _ => tokens.atmosphereTertiary,
                },
              ),
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
        boxShadow: [BoxShadow(color: color, blurRadius: size * 0.20)],
      ),
    );
  }
}

class _TitleBar extends StatelessWidget {
  const _TitleBar({
    required this.topInset,
    required this.leftInset,
    required this.rightInset,
    required this.versionLabel,
  });

  static const double _height = _titleBarHeight;
  static const double _windowControlsWidth = 122;

  /// Width reserved for the native macOS traffic-light buttons.
  static const double _macTrafficLightsWidth = 70;

  final double topInset;
  final double leftInset;
  final double rightInset;
  final String versionLabel;

  @override
  Widget build(BuildContext context) {
    final isDesktop =
        Platform.isWindows || Platform.isLinux || Platform.isMacOS;
    // macOS keeps its native traffic lights (top left); only Windows and
    // Linux draw their own window buttons.
    final usesNativeControls = Platform.isMacOS;
    final customControlsWidth = usesNativeControls ? 0.0 : _windowControlsWidth;
    final titleLeft =
        leftInset + (usesNativeControls ? _macTrafficLightsWidth : 0.0);
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
                    left: titleLeft,
                    right: rightInset + customControlsWidth,
                  ),
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: _TitleContent(versionLabel: versionLabel),
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
              child: Align(
                alignment: Alignment.topLeft,
                child: _TitleContent(versionLabel: versionLabel),
              ),
            ),
          if (isDesktop && !usesNativeControls)
            Positioned(
              top: topInset,
              right: rightInset,
              child: _WindowControls(),
            ),
        ],
      ),
    );
  }
}

class _TitleContent extends StatelessWidget {
  const _TitleContent({required this.versionLabel});

  final String versionLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final brandAccent = theme.brandAccent;
    final versionInk = theme.brightness == Brightness.dark
        ? Colors.white
        : Colors.black;

    return Padding(
      padding: const EdgeInsets.only(left: 1, right: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SvgPicture.asset(
            'assets/images/logo.svg',
            width: 20,
            height: 20,
            colorFilter: ColorFilter.mode(brandAccent, BlendMode.srcIn),
          ),
          const SizedBox(width: 10),
          Text(
            'gorion',
            style: TextStyle(
              fontFamily: 'IBMPlexSans',
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: scheme.onSurface,
              letterSpacing: 0.4,
            ),
          ),
          const SizedBox(width: 8),
          GlassPanel(
            borderRadius: 999,
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            backgroundColor: brandAccent,
            opacity: theme.brightness == Brightness.dark ? 0.18 : 0.22,
            strokeColor: brandAccent,
            strokeOpacity: theme.brightness == Brightness.dark ? 0.34 : 0.26,
            strokeWidth: 0.9,
            child: Text(
              versionLabel,
              style: TextStyle(
                fontFamily: 'IBMPlexSans',
                fontSize: 10,
                fontWeight: FontWeight.w500,
                color: versionInk,
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
    unawaited(
      windowManager.isMaximized().then((v) {
        if (mounted) setState(() => _isMaximized = v);
      }),
    );
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
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final iconColor = theme.brightness == Brightness.dark
        ? Colors.white
        : Colors.black;

    return GlassPanel(
      height: _TitleBar._height,
      borderRadius: 18,
      padding: const EdgeInsets.all(4),
      opacity: 0.22,
      backgroundColor: scheme.surface,
      strokeColor: scheme.onSurface,
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
            onTap: windowManager.minimize,
            child: Container(width: 10, height: 1.5, color: iconColor),
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
                ? _RestoreIcon(color: iconColor)
                : Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      border: Border.all(color: iconColor, width: 1.2),
                    ),
                  ),
          ),
          _WinBtn(
            isClose: true,
            onTap: windowManager.close,
            child: Icon(Icons.close_rounded, size: 14, color: iconColor),
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
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final bgHover = widget.isClose
        ? scheme.error
        : theme.brandAccent.withValues(alpha: 0.12);
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
  const _RestoreIcon({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 12,
      height: 12,
      child: CustomPaint(painter: _RestorePainter(color)),
    );
  }
}

class _RestorePainter extends CustomPainter {
  const _RestorePainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
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
  const _Dock({
    required this.current,
    required this.updateAvailable,
    required this.onSelect,
  });

  final _DockPage current;
  final bool updateAvailable;
  final ValueChanged<_DockPage> onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return SizedBox(
      width: _dockWidth,
      child: GlassPanel(
        borderRadius: 24,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
        opacity: 0.05,
        backgroundColor: scheme.onSurface,
        strokeColor: scheme.onSurface,
        strokeOpacity: 0.08,
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
            const Spacer(),
            _DockBtn(
              icon: Icons.settings_outlined,
              label: 'Настройки',
              selected: current == _DockPage.settings,
              showBadge: updateAvailable,
              onTap: () => onSelect(_DockPage.settings),
            ),
            const SizedBox(height: 2),
          ],
        ),
      ),
    );
  }
}

_DockPage _dockPageForLocation(String location) {
  if (location.startsWith(AppRoutePaths.settings)) {
    return _DockPage.settings;
  }
  return _DockPage.home;
}

class _DockBtn extends StatefulWidget {
  const _DockBtn({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.showBadge = false,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool showBadge;

  @override
  State<_DockBtn> createState() => _DockBtnState();
}

class _DockBtnState extends State<_DockBtn> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.gorionTokens.onSurfaceMuted;
    final accent = theme.brandAccent;
    final color = widget.selected
        ? accent
        : _hover
        ? scheme.onSurface
        : muted;

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
                  ? accent.withValues(
                      alpha: theme.brightness == Brightness.dark ? 0.14 : 0.10,
                    )
                  : _hover
                  ? scheme.onSurface.withValues(alpha: 0.06)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: widget.selected
                    ? accent.withValues(alpha: 0.30)
                    : Colors.transparent,
              ),
            ),
            alignment: Alignment.center,
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                Icon(widget.icon, size: 20, color: color),
                if (widget.showBadge)
                  Positioned(
                    top: -5,
                    right: -6,
                    child: Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFC857),
                        shape: BoxShape.circle,
                        border: Border.all(color: scheme.surface, width: 1.5),
                        boxShadow: const [
                          BoxShadow(color: Color(0x66FFC857), blurRadius: 10),
                        ],
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
