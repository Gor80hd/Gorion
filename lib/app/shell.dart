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
import 'package:gorion_clean/app/windows_tray_controller.dart';
import 'package:gorion_clean/core/widget/glass_panel.dart';
import 'package:gorion_clean/core/windows/windows_elevation_service.dart';
import 'package:gorion_clean/features/home/application/dashboard_controller.dart';
import 'package:gorion_clean/features/home/application/dashboard_state.dart';
import 'package:gorion_clean/features/runtime/model/runtime_mode.dart';
import 'package:gorion_clean/features/runtime/model/runtime_models.dart';
import 'package:gorion_clean/features/settings/application/desktop_settings_controller.dart';
import 'package:gorion_clean/features/settings/widget/settings_page.dart';
import 'package:gorion_clean/features/update/application/app_update_controller.dart';
import 'package:gorion_clean/features/update/model/app_update_state.dart';
import 'package:gorion_clean/utils/server_display_text.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:window_manager/window_manager.dart';

part 'shell_update_popup.dart';
part 'shell_chrome.dart';

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
  Future<void>? _shutdownFuture;
  WindowsTrayController? _trayController;
  bool _startupAutoConnectHandled = false;
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
    final pageChild = switch (currentPage) {
      _DockPage.home => widget.child,
      _DockPage.settings =>
        hasRouter ? widget.child : const SettingsPage(animateOnMount: false),
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
            Padding(
              padding: EdgeInsets.fromLTRB(
                leftInset + _dockWidth + _dockGap,
                contentTopInset,
                rightInset,
                bottomInset,
              ),
              child: KeyedSubtree(key: ValueKey(currentPage), child: pageChild),
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
