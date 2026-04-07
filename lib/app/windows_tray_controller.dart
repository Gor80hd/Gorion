import 'dart:async';

import 'package:gorion_clean/features/runtime/model/runtime_models.dart';
import 'package:tray_manager/tray_manager.dart';

class WindowsTrayController with TrayListener {
  static const _defaultIconPath = 'assets/images/tray_icon.ico';
  static const _connectedIconPath =
      'assets/images/tray_icon_connected.ico';

  WindowsTrayController({
    required Future<void> Function() showWindow,
    required Future<void> Function() hideWindow,
    required Future<void> Function() connect,
    required Future<void> Function() disconnect,
    required Future<void> Function() reconnect,
    required Future<void> Function() quit,
  }) : _showWindow = showWindow,
       _hideWindow = hideWindow,
       _connect = connect,
       _disconnect = disconnect,
       _reconnect = reconnect,
       _quit = quit;

  final Future<void> Function() _showWindow;
  final Future<void> Function() _hideWindow;
  final Future<void> Function() _connect;
  final Future<void> Function() _disconnect;
  final Future<void> Function() _reconnect;
  final Future<void> Function() _quit;

  bool _initialized = false;
  String? _iconPath;
  String? _toolTip;
  String? _menuSignature;
  ConnectionStage _stage = ConnectionStage.disconnected;
  bool _busy = false;
  bool _windowVisible = true;
  String? _activeServerLabel;

  Future<void> initialize() async {
    if (_initialized) {
      return;
    }

    trayManager.addListener(this);
    _initialized = true;
  }

  Future<void> dispose({bool destroyTray = true}) async {
    trayManager.removeListener(this);
    if (_initialized && destroyTray) {
      await trayManager.destroy();
    }
    _initialized = false;
  }

  Future<void> update({
    required ConnectionStage stage,
    required bool busy,
    required bool windowVisible,
    String? activeServerLabel,
  }) async {
    if (!_initialized) {
      return;
    }

    _stage = stage;
    _busy = busy;
    _windowVisible = windowVisible;
    _activeServerLabel = activeServerLabel;

    final nextIconPath = _iconPathFor(stage);
    if (_iconPath != nextIconPath) {
      _iconPath = nextIconPath;
      await trayManager.setIcon(nextIconPath);
    }

    final nextToolTip = _toolTipFor(stage, activeServerLabel);
    if (_toolTip != nextToolTip) {
      _toolTip = nextToolTip;
      await trayManager.setToolTip(nextToolTip);
    }

    final nextMenuSignature = [
      stage.name,
      busy,
      windowVisible,
      activeServerLabel ?? '',
    ].join('|');
    if (_menuSignature != nextMenuSignature) {
      _menuSignature = nextMenuSignature;
      await trayManager.setContextMenu(_buildMenu());
    }
  }

  @override
  void onTrayIconMouseDown() {
    unawaited(_toggleWindowVisibility());
  }

  @override
  void onTrayIconRightMouseDown() {
    unawaited(trayManager.popUpContextMenu());
  }

  Menu _buildMenu() {
    final items = <MenuItem>[
      MenuItem(
        label: 'Статус: ${_statusLabel(_stage)}',
        disabled: true,
      ),
      MenuItem(
        label: _activeServerLabel == null
            ? 'Сервер: не выбран'
            : 'Сервер: $_activeServerLabel',
        disabled: true,
      ),
      MenuItem.separator(),
      MenuItem(
        label: _windowVisible ? 'Скрыть окно' : 'Открыть окно',
        onClick: (_) => unawaited(_toggleWindowVisibility()),
      ),
      MenuItem(
        label: _primaryActionLabel(),
        disabled: _primaryActionDisabled(),
        onClick: (_) => unawaited(_runPrimaryAction()),
      ),
      MenuItem(
        label: 'Переподключить',
        disabled: _busy || _stage != ConnectionStage.connected,
        onClick: (_) => unawaited(_reconnect()),
      ),
      MenuItem.separator(),
      MenuItem(
        label: 'Выход',
        onClick: (_) => unawaited(_quit()),
      ),
    ];

    return Menu(items: items);
  }

  Future<void> _toggleWindowVisibility() async {
    if (_windowVisible) {
      await _hideWindow();
      return;
    }
    await _showWindow();
  }

  bool _primaryActionDisabled() {
    return switch (_stage) {
      ConnectionStage.connected => _busy,
      ConnectionStage.disconnected || ConnectionStage.failed => _busy,
      ConnectionStage.starting || ConnectionStage.stopping => true,
    };
  }

  String _primaryActionLabel() {
    return switch (_stage) {
      ConnectionStage.connected => 'Отключить',
      ConnectionStage.disconnected || ConnectionStage.failed => 'Подключить',
      ConnectionStage.starting => 'Подключение...',
      ConnectionStage.stopping => 'Отключение...',
    };
  }

  Future<void> _runPrimaryAction() async {
    switch (_stage) {
      case ConnectionStage.connected:
        await _disconnect();
        return;
      case ConnectionStage.disconnected:
      case ConnectionStage.failed:
        await _connect();
        return;
      case ConnectionStage.starting:
      case ConnectionStage.stopping:
        return;
    }
  }

  static String iconPathForStage(ConnectionStage stage) {
    return switch (stage) {
      ConnectionStage.connected => _connectedIconPath,
      ConnectionStage.disconnected ||
      ConnectionStage.failed ||
      ConnectionStage.starting ||
      ConnectionStage.stopping => _defaultIconPath,
    };
  }

  String _iconPathFor(ConnectionStage stage) {
    return iconPathForStage(stage);
  }

  String _toolTipFor(ConnectionStage stage, String? activeServerLabel) {
    final status = _statusLabel(stage);
    if (stage == ConnectionStage.connected &&
        activeServerLabel != null &&
        activeServerLabel.isNotEmpty) {
      return 'gorion\n$status: $activeServerLabel';
    }
    return 'gorion\n$status';
  }

  String _statusLabel(ConnectionStage stage) {
    return switch (stage) {
      ConnectionStage.connected => 'Подключено',
      ConnectionStage.disconnected => 'Отключено',
      ConnectionStage.starting => 'Подключение',
      ConnectionStage.stopping => 'Отключение',
      ConnectionStage.failed => 'Ошибка',
    };
  }
}