import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import 'package:gorion_clean/app/app_router.dart';
import 'package:gorion_clean/app/theme.dart';
import 'package:gorion_clean/core/windows/windows_elevation_service.dart';
import 'package:gorion_clean/app/windows_tray_controller.dart';
import 'package:gorion_clean/core/widget/glass_panel.dart';
import 'package:gorion_clean/features/home/application/dashboard_controller.dart';
import 'package:gorion_clean/features/runtime/model/runtime_models.dart';
import 'package:gorion_clean/features/runtime/model/runtime_mode.dart';
import 'package:gorion_clean/features/settings/application/desktop_settings_controller.dart';
import 'package:gorion_clean/features/settings/widget/settings_page.dart';
import 'package:gorion_clean/features/update/application/app_update_controller.dart';
import 'package:gorion_clean/features/update/model/app_update_state.dart';
import 'package:gorion_clean/features/zapret/application/zapret_controller.dart';
import 'package:gorion_clean/features/zapret/model/zapret_models.dart';
import 'package:gorion_clean/features/zapret/widget/zapret_page.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:gorion_clean/utils/server_display_text.dart';
import 'package:window_manager/window_manager.dart';

const _dockLeftMargin = 10.0;
const _dockVerticalMargin = 15.0;
const _dockBottomMargin = 20.0;
const _dockWidth = 67.0;
const _dockGap = 12.0;
const _titleBarHeight = 48.0;
const _dockTopGap = 10.0;
const _backgroundOrbs =
    <({double? left, double? right, double? top, double? bottom, double size})>[
      (left: -180, right: null, top: -140, bottom: null, size: 380),
      (left: null, right: -90, top: 80, bottom: null, size: 240),
      (left: null, right: 120, top: null, bottom: -180, size: 420),
    ];

class AppShell extends ConsumerStatefulWidget {
  const AppShell({
    super.key,
    required this.child,
    this.location = AppRoutePaths.home,
  });

  final Widget child;
  final String location;

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> with WindowListener {
  AppLifecycleListener? _appLifecycleListener;
  ProviderSubscription<DashboardState>? _dashboardSubscription;
  ProviderSubscription<ZapretState>? _zapretSubscription;
  Future<void>? _shutdownFuture;
  WindowsTrayController? _trayController;
  bool _startupAutoConnectHandled = false;
  bool _startupZapretHandled = false;
  bool _windowDestroyInProgress = false;
  String _appVersionLabel = '...';
  late _DockPage _manualCurrentPage;

  bool get _isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  bool get _usesWindowsTray => Platform.isWindows;

  @override
  void initState() {
    super.initState();
    _manualCurrentPage = _dockPageForLocation(widget.location);
    _appLifecycleListener = AppLifecycleListener(
      onExitRequested: _handleAppExitRequest,
    );
    _dashboardSubscription = ref.listenManual<DashboardState>(
      dashboardControllerProvider,
      (previous, next) {
        unawaited(_handleDashboardStateChanged(next));
      },
      fireImmediately: true,
    );
    _zapretSubscription = ref.listenManual<ZapretState>(
      zapretControllerProvider,
      (previous, next) {
        unawaited(_handleZapretStateChanged(next));
      },
      fireImmediately: true,
    );
    if (_isDesktop) {
      windowManager.addListener(this);
      unawaited(windowManager.setPreventClose(true));
    }
    if (_usesWindowsTray) {
      unawaited(_initializeWindowsTray());
    }
    unawaited(_loadAppVersionLabel());
    _scheduleUpdateCheckAfterFirstFrame();
  }

  void _scheduleUpdateCheckAfterFirstFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      unawaited(
        ref.read(appUpdateControllerProvider.notifier).checkForUpdates(),
      );
    });
  }

  @override
  void dispose() {
    _dashboardSubscription?.close();
    _zapretSubscription?.close();
    if (_isDesktop) {
      windowManager.removeListener(this);
    }
    final trayController = _trayController;
    _trayController = null;
    if (trayController != null) {
      unawaited(trayController.dispose());
    }
    _appLifecycleListener?.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant AppShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.location != oldWidget.location) {
      _manualCurrentPage = _dockPageForLocation(widget.location);
    }
  }

  @override
  void onWindowClose() {
    if (_windowDestroyInProgress) {
      return;
    }
    if (_shouldKeepRunningInTrayOnClose) {
      unawaited(_hideWindowToTray());
      return;
    }
    unawaited(_closeWindowGracefully());
  }

  @override
  void onWindowMinimize() {
    unawaited(_syncTrayState());
  }

  @override
  void onWindowRestore() {
    unawaited(_syncTrayState());
  }

  Future<AppExitResponse> _handleAppExitRequest() async {
    if (_shouldKeepRunningInTrayOnClose && !_windowDestroyInProgress) {
      await _hideWindowToTray();
      return AppExitResponse.cancel;
    }

    await _shutdownBeforeExit();
    return AppExitResponse.exit;
  }

  Future<void> _closeWindowGracefully() async {
    if (!_isDesktop || _windowDestroyInProgress) {
      return;
    }

    await _quitApplication();
  }

  Future<void> _initializeWindowsTray() async {
    final trayController = WindowsTrayController(
      showWindow: _showWindowFromTray,
      hideWindow: _hideWindowToTray,
      connect: () => ref.read(dashboardControllerProvider.notifier).connect(),
      disconnect: () =>
          ref.read(dashboardControllerProvider.notifier).disconnect(),
      reconnect: () =>
          ref.read(dashboardControllerProvider.notifier).reconnect(),
      quit: _quitApplication,
    );

    try {
      await trayController.initialize();
      if (!mounted) {
        await trayController.dispose();
        return;
      }
      _trayController = trayController;
      await _syncTrayState();
    } on MissingPluginException {
      await trayController.dispose(destroyTray: false);
    } on Object {
      await trayController.dispose(destroyTray: false);
    }
  }

  Future<void> _loadAppVersionLabel() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final version = packageInfo.version.trim();
      final buildNumber = packageInfo.buildNumber.trim();
      final nextLabel = switch ((version.isEmpty, buildNumber.isEmpty)) {
        (true, _) => null,
        (false, true) => version,
        (false, false) => '$version+$buildNumber',
      };
      if (!mounted || nextLabel == null || nextLabel == _appVersionLabel) {
        return;
      }
      setState(() => _appVersionLabel = nextLabel);
    } on Object {
      // Keep the title bar resilient if package metadata is unavailable.
    }
  }

  Future<void> _handleDashboardStateChanged(DashboardState state) async {
    await _syncTrayState(state: state);
    await _maybeAutoConnectOnStartup(state);
    await _syncZapretTunConflict(ref.read(dashboardControllerProvider));
    await _maybeAutoStartZapretOnStartup();
  }

  Future<void> _handleZapretStateChanged(ZapretState _) async {
    if (!mounted) {
      return;
    }
    await _syncZapretTunConflict(ref.read(dashboardControllerProvider));
    await _maybeAutoStartZapretOnStartup();
  }

  Future<void> _maybeAutoConnectOnStartup(DashboardState state) async {
    if (_startupAutoConnectHandled || state.bootstrapping) {
      return;
    }

    final launchRequest = ref.read(appLaunchRequestProvider);
    if (launchRequest.pendingElevatedAction ==
        PendingElevatedLaunchAction.connectTun) {
      if (state.activeProfile == null) {
        if (!state.busy) {
          _startupAutoConnectHandled = true;
        }
        return;
      }
      if (state.busy || state.connectionStage != ConnectionStage.disconnected) {
        return;
      }

      _startupAutoConnectHandled = true;
      final controller = ref.read(dashboardControllerProvider.notifier);
      if (state.runtimeMode != RuntimeMode.tun) {
        await controller.setRuntimeMode(RuntimeMode.tun);
      }
      await controller.connect();
      return;
    }

    final desktopSettingsState = ref.read(desktopSettingsControllerProvider);
    if (!desktopSettingsState.settings.autoConnectOnLaunch) {
      _startupAutoConnectHandled = true;
      return;
    }
    if (state.activeProfile == null) {
      if (!state.busy) {
        _startupAutoConnectHandled = true;
      }
      return;
    }
    if (state.busy || state.connectionStage != ConnectionStage.disconnected) {
      return;
    }

    _startupAutoConnectHandled = true;
    await ref.read(dashboardControllerProvider.notifier).connect();
  }

  Future<void> _maybeAutoStartZapretOnStartup() async {
    if (_startupZapretHandled) {
      return;
    }

    final launchRequest = ref.read(appLaunchRequestProvider);
    final pendingZapretStart =
        launchRequest.pendingElevatedAction ==
        PendingElevatedLaunchAction.startZapret;
    final pendingZapretTest =
        launchRequest.pendingElevatedAction ==
        PendingElevatedLaunchAction.testZapretConfigs;
    final dashboardState = ref.read(dashboardControllerProvider);
    final zapretState = ref.read(zapretControllerProvider);
    if (dashboardState.bootstrapping || zapretState.bootstrapping) {
      return;
    }

    if (!Platform.isWindows ||
        (!pendingZapretStart &&
            !pendingZapretTest &&
            !zapretState.settings.startOnAppLaunch)) {
      _startupZapretHandled = true;
      return;
    }

    if (!pendingZapretStart &&
        !pendingZapretTest &&
        !zapretState.settings.hasInstallDirectory) {
      _startupZapretHandled = true;
      return;
    }

    if (_isTunActive(dashboardState) || zapretState.tunConflictActive) {
      _startupZapretHandled = true;
      return;
    }

    if (dashboardState.connectionStage == ConnectionStage.starting) {
      return;
    }

    if (zapretState.stage == ZapretStage.running || zapretState.busy) {
      _startupZapretHandled = true;
      return;
    }

    final controller = ref.read(zapretControllerProvider.notifier);
    if (pendingZapretTest) {
      _startupZapretHandled = true;
      await controller.runHttpConfigTests();
      return;
    }

    _startupZapretHandled = true;
    if (launchRequest.launchedAtStartup &&
        !await _prepareZapretAutoStartAfterWindowsLaunch(controller)) {
      _startupZapretHandled = false;
      return;
    }

    await controller.start();
  }

  Future<bool> _prepareZapretAutoStartAfterWindowsLaunch(
    ZapretController controller,
  ) async {
    // A blind delay used to paper over a cold-start bug where Boost launched
    // before its runtime layout and selected profile had fully settled. A
    // second bootstrap pass reproduces the part of a manual app restart that
    // actually fixed the issue, without delaying startup itself.
    await controller.reload();
    if (!mounted) {
      return false;
    }

    final dashboardState = ref.read(dashboardControllerProvider);
    final zapretState = ref.read(zapretControllerProvider);
    if (dashboardState.bootstrapping ||
        zapretState.bootstrapping ||
        _isTunActive(dashboardState) ||
        zapretState.tunConflictActive ||
        dashboardState.connectionStage == ConnectionStage.starting ||
        zapretState.stage == ZapretStage.running ||
        zapretState.busy) {
      return false;
    }

    return true;
  }

  Future<void> _syncZapretTunConflict(DashboardState state) {
    return ref
        .read(zapretControllerProvider.notifier)
        .syncTunConflict(active: _isTunActive(state));
  }

  bool _isTunActive(DashboardState state) {
    if (state.runtimeSession?.mode.usesTun ?? false) {
      return true;
    }
    return state.connectionStage == ConnectionStage.starting &&
        state.runtimeMode.usesTun;
  }

  Future<void> _syncTrayState({DashboardState? state}) async {
    final trayController = _trayController;
    if (trayController == null) {
      return;
    }

    final DashboardState dashboardState =
        state ?? ref.read(dashboardControllerProvider);
    final windowVisible = await _isWindowPresented();
    await trayController.update(
      stage: dashboardState.connectionStage,
      busy: dashboardState.busy,
      windowVisible: windowVisible,
      activeServerLabel: _resolveActiveServerLabel(dashboardState),
    );
  }

  Future<bool> _isWindowPresented() async {
    if (!_isDesktop) {
      return true;
    }

    try {
      final visible = await windowManager.isVisible();
      if (!visible) {
        return false;
      }
      return !(await windowManager.isMinimized());
    } on Object {
      return true;
    }
  }

  String? _resolveActiveServerLabel(DashboardState state) {
    final profile = state.activeProfile;
    final activeServerTag = state.activeServerTag;
    if (profile == null || activeServerTag == null) {
      return null;
    }

    for (final server in profile.servers) {
      if (server.tag != activeServerTag) {
        continue;
      }

      final normalized = normalizeServerDisplayText(
        server.displayName,
        replaceUnderscores: true,
      );
      return normalized.isEmpty ? server.tag : normalized;
    }

    return activeServerTag;
  }

  Future<void> _showWindowFromTray() async {
    if (!_isDesktop) {
      return;
    }

    await windowManager.show();
    await windowManager.focus();
    await _syncTrayState();
  }

  Future<void> _hideWindowToTray() async {
    if (!_isDesktop) {
      return;
    }

    await windowManager.hide();
    await _syncTrayState();
  }

  bool get _shouldKeepRunningInTrayOnClose {
    if (!_usesWindowsTray || _trayController == null) {
      return false;
    }
    final desktopSettingsState = ref.read(desktopSettingsControllerProvider);
    return desktopSettingsState.settings.keepRunningInTrayOnClose;
  }

  Future<void> _quitApplication() async {
    if (!_isDesktop || _windowDestroyInProgress) {
      return;
    }

    await _shutdownBeforeExit();

    _windowDestroyInProgress = true;
    final trayController = _trayController;
    _trayController = null;
    try {
      if (trayController != null) {
        await trayController.dispose();
      }
      await windowManager.destroy();
    } on Object {
      _windowDestroyInProgress = false;
      rethrow;
    }
  }

  Future<void> _shutdownBeforeExit() {
    return _shutdownFuture ??= _performShutdown().whenComplete(() {
      _shutdownFuture = null;
    });
  }

  Future<void> _performShutdown() async {
    try {
      await ref.read(zapretControllerProvider.notifier).shutdownForAppExit();
    } on Object {
      // Keep app exit best-effort: do not block the main runtime shutdown.
    }

    try {
      await ref.read(dashboardControllerProvider.notifier).shutdownForAppExit();
    } on Object {
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.gorionTokens;
    final appUpdateState = ref.watch(appUpdateControllerProvider);
    final availableUpdate = appUpdateState.availableUpdate;
    final routedLocation = _maybeRouterLocation(context);
    final hasRouter = routedLocation != null;
    final currentPage = hasRouter
        ? _dockPageForLocation(widget.location)
        : _manualCurrentPage;
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
    final dockBottomInset = math.max(
      _dockBottomMargin,
      viewPadding.bottom + _dockBottomMargin,
    );
    final leftInset = math.max(
      _dockLeftMargin,
      viewPadding.left + _dockLeftMargin,
    );
    final contentTopInset = currentPage == _DockPage.home
        ? topInset + 8
        : topInset + _titleBarHeight + _dockTopGap;
    final isZapretPage = currentPage == _DockPage.zapret;
    final pageChild = switch (currentPage) {
      _DockPage.home => widget.child,
      _DockPage.settings =>
        hasRouter ? widget.child : const SettingsPage(animateOnMount: false),
      _DockPage.zapret => const SizedBox.shrink(),
    };

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: tokens.backgroundGradientFor(theme.brightness),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            _BackgroundAtmosphere(),
            if (isZapretPage)
              KeyedSubtree(
                key: const ValueKey(_DockPage.zapret),
                child: ZapretPage(
                  animateOnMount: false,
                  contentPadding: EdgeInsets.fromLTRB(
                    leftInset + _dockWidth + _dockGap,
                    contentTopInset,
                    viewPadding.right,
                    bottomInset,
                  ),
                ),
              )
            else
              Padding(
                padding: EdgeInsets.fromLTRB(
                  leftInset + _dockWidth + _dockGap,
                  contentTopInset,
                  rightInset,
                  bottomInset,
                ),
                child: KeyedSubtree(
                  key: ValueKey(currentPage),
                  child: pageChild,
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
                versionLabel: _appVersionLabel,
              ),
            ),
            Positioned(
              left: leftInset,
              top: topInset + _titleBarHeight + _dockTopGap,
              bottom: dockBottomInset,
              child: _Dock(
                current: currentPage,
                updateAvailable: availableUpdate != null,
                onSelect: (page) => _handleDockNavigation(context, page),
              ),
            ),
            if (availableUpdate != null && !appUpdateState.bannerDismissed)
              Positioned(
                left: leftInset + _dockWidth + _dockGap,
                right: rightInset,
                bottom: viewPadding.bottom + 18,
                child: _UpdateAvailablePopup(
                  update: availableUpdate,
                  onDismiss: () => ref
                      .read(appUpdateControllerProvider.notifier)
                      .dismissBanner(),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _handleDockNavigation(BuildContext context, _DockPage page) {
    final target = switch (page) {
      _DockPage.home => AppRoutePaths.home,
      _DockPage.zapret => AppRoutePaths.zapret,
      _DockPage.settings => AppRoutePaths.settings,
    };
    final currentLocation = _maybeRouterLocation(context);
    if (currentLocation != null) {
      if (currentLocation == target) {
        return;
      }
      context.go(target);
      return;
    }

    if (_manualCurrentPage == page) {
      return;
    }
    setState(() {
      _manualCurrentPage = page;
    });
  }

  String? _maybeRouterLocation(BuildContext context) {
    try {
      return GoRouterState.of(context).uri.path;
    } on Object {
      return null;
    }
  }
}

class _UpdateAvailablePopup extends StatelessWidget {
  const _UpdateAvailablePopup({required this.update, required this.onDismiss});

  final AppUpdateInfo update;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.gorionTokens.onSurfaceMuted;
    final accent = theme.brandAccent;
    final releaseName = update.releaseName?.trim();
    final releaseNameLabel =
        releaseName != null &&
            releaseName.isNotEmpty &&
            releaseName != update.latestVersion &&
            releaseName != update.tagName
        ? releaseName
        : null;

    return Align(
      alignment: Alignment.bottomCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 660),
        child: GlassPanel(
          borderRadius: 24,
          padding: const EdgeInsets.fromLTRB(16, 14, 10, 14),
          opacity: 0.14,
          backgroundColor: scheme.surface,
          strokeColor: accent,
          strokeOpacity: 0.26,
          strokeWidth: 1,
          showGlow: true,
          glowBlur: 16,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.28),
              blurRadius: 30,
              offset: const Offset(0, 16),
            ),
          ],
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(Icons.system_update_alt_rounded, color: accent),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Доступна новая версия ${update.latestVersion}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: scheme.onSurface,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Сейчас установлена ${update.currentVersion}. Релиз уже опубликован на GitHub.',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: muted,
                        height: 1.35,
                      ),
                    ),
                    if (releaseNameLabel != null) ...[
                      const SizedBox(height: 5),
                      Text(
                        releaseNameLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: accent,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                    if (update.releaseUrl != null) ...[
                      const SizedBox(height: 10),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: () => unawaited(_openReleasePage(context)),
                          icon: const Icon(Icons.open_in_new_rounded, size: 16),
                          label: const Text('Открыть страницу релиза'),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Скрыть',
                onPressed: onDismiss,
                icon: Icon(Icons.close_rounded, color: muted),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openReleasePage(BuildContext context) async {
    final releaseUrl = update.releaseUrl;
    if (releaseUrl == null) {
      return;
    }

    final opened = await _openExternalUrl(releaseUrl);
    if (!context.mounted) {
      return;
    }

    if (!opened) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Не удалось открыть страницу релиза.')),
      );
    }
  }

  Future<bool> _openExternalUrl(String url) async {
    try {
      if (Platform.isWindows) {
        await Process.start('rundll32', ['url.dll,FileProtocolHandler', url]);
        return true;
      }
      if (Platform.isMacOS) {
        await Process.start('open', [url]);
        return true;
      }
      if (Platform.isLinux) {
        await Process.start('xdg-open', [url]);
        return true;
      }
    } on Object {
      return false;
    }
    return false;
  }
}

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

  final double topInset;
  final double leftInset;
  final double rightInset;
  final String versionLabel;

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
          if (isDesktop)
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
            onTap: () => windowManager.minimize(),
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
            onTap: () => windowManager.close(),
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

enum _DockPage { home, zapret, settings }

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
            const SizedBox(height: 12),
            const _DockDivider(),
            const SizedBox(height: 12),
            _DockBtn(
              icon: Icons.rocket_launch_outlined,
              label: 'Gorion Boost',
              selected: current == _DockPage.zapret,
              onTap: () => onSelect(_DockPage.zapret),
            ),
            const SizedBox(height: 12),
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
  if (location.startsWith(AppRoutePaths.zapret)) {
    return _DockPage.zapret;
  }
  if (location.startsWith(AppRoutePaths.settings)) {
    return _DockPage.settings;
  }
  return _DockPage.home;
}

class _DockDivider extends StatelessWidget {
  const _DockDivider();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 18,
      height: 1,
      color: scheme.onSurface.withValues(alpha: 0.1),
    );
  }
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
    final brandAccent = theme.brandAccent;
    final color = theme.isMonochromeLightGorion
        ? scheme.onSurface
        : widget.selected
        ? brandAccent
        : _hover
        ? scheme.onSurface
        : muted;
    final borderColor = widget.selected
        ? brandAccent.withValues(alpha: 0.28)
        : theme.isMonochromeLightGorion
        ? brandAccent.withValues(alpha: _hover ? 0.14 : 0.08)
        : scheme.onSurface.withValues(alpha: _hover ? 0.12 : 0.06);

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
                  ? theme.isMonochromeLightGorion
                        ? brandAccent.withValues(alpha: 0.08)
                        : scheme.onSurface.withValues(alpha: 0.06)
                  : Colors.transparent,
              gradient: widget.selected
                  ? LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        brandAccent.withValues(alpha: 0.2),
                        brandAccent.withValues(alpha: 0.08),
                      ],
                    )
                  : null,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: borderColor),
              boxShadow: widget.selected
                  ? [
                      BoxShadow(
                        color: brandAccent.withValues(alpha: 0.18),
                        blurRadius: 20,
                        spreadRadius: -6,
                      ),
                    ]
                  : null,
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
