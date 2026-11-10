import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gorion/core/windows/windows_elevation_service.dart';
import 'package:window_manager/window_manager.dart';

final rootNavigatorKeyProvider = Provider<GlobalKey<NavigatorState>>(
  (ref) => GlobalKey<NavigatorState>(debugLabel: 'gorion-root-navigator'),
);

final elevationRelaunchPromptServiceProvider =
    Provider<ElevationRelaunchPromptService>(
      (ref) => DialogElevationRelaunchPromptService(
        navigatorKey: ref.read(rootNavigatorKeyProvider),
      ),
    );

abstract class ElevationRelaunchPromptService {
  Future<bool> confirmRelaunch({required PendingElevatedLaunchAction action});

  /// macOS: installing the privileged helper is a one-time admin action,
  /// separate from the Windows relaunch-as-admin flow.
  Future<bool> confirmPrivilegedHelperInstall();
}

class DialogElevationRelaunchPromptService
    implements ElevationRelaunchPromptService {
  DialogElevationRelaunchPromptService({
    required this.navigatorKey,
    Future<void> Function()? ensureWindowVisible,
  }) : _ensureWindowVisible =
           ensureWindowVisible ?? _defaultEnsureWindowVisible;

  final GlobalKey<NavigatorState> navigatorKey;
  final Future<void> Function() _ensureWindowVisible;

  @override
  Future<bool> confirmRelaunch({
    required PendingElevatedLaunchAction action,
  }) async {
    await _ensureWindowVisible();

    final context = navigatorKey.currentContext;
    if (context == null || !context.mounted) {
      return false;
    }

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        final theme = Theme.of(dialogContext);
        final scheme = theme.colorScheme;
        final muted =
            theme.textTheme.bodyMedium?.color ??
            scheme.onSurface.withValues(alpha: 0.72);

        return AlertDialog(
          backgroundColor: scheme.surface,
          title: Text(
            'Перезапустить с правами администратора?',
            style: TextStyle(color: scheme.onSurface),
          ),
          content: Text(
            _messageForAction(action),
            style: TextStyle(color: muted, height: 1.4),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Перезапустить'),
            ),
          ],
        );
      },
    );

    return result == true;
  }

  @override
  Future<bool> confirmPrivilegedHelperInstall() async {
    await _ensureWindowVisible();

    final context = navigatorKey.currentContext;
    if (context == null || !context.mounted) {
      return false;
    }

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        final theme = Theme.of(dialogContext);
        final scheme = theme.colorScheme;
        final muted =
            theme.textTheme.bodyMedium?.color ??
            scheme.onSurface.withValues(alpha: 0.72);

        return AlertDialog(
          backgroundColor: scheme.surface,
          title: Text(
            'Установить системный компонент?',
            style: TextStyle(color: scheme.onSurface),
          ),
          content: Text(
            'Режим TUN на macOS требует небольшого системного компонента Gorion, который работает от root и управляет VPN-туннелем. '
            'Он устанавливается один раз; macOS попросит пароль администратора. '
            'Без него доступны режимы «Proxy (local)» и «Proxy».',
            style: TextStyle(color: muted, height: 1.4),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Установить'),
            ),
          ],
        );
      },
    );

    return result == true;
  }

  String _messageForAction(PendingElevatedLaunchAction action) {
    return switch (action) {
      PendingElevatedLaunchAction.connectTun =>
        'Для запуска режима TUN нужны права администратора. '
            'После подтверждения UAC приложение Gorion будет перезапущено и автоматически продолжит подключение.',
    };
  }

  static Future<void> _defaultEnsureWindowVisible() async {
    if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      return;
    }

    try {
      if (!await windowManager.isVisible()) {
        await windowManager.show();
      }
      if (await windowManager.isMinimized()) {
        await windowManager.restore();
      }
      await windowManager.focus();
    } on Object {
      // Best-effort only: do not block the confirmation flow.
    }
  }
}

class NoopElevationRelaunchPromptService
    implements ElevationRelaunchPromptService {
  const NoopElevationRelaunchPromptService();

  @override
  Future<bool> confirmRelaunch({
    required PendingElevatedLaunchAction action,
  }) async {
    return true;
  }

  @override
  Future<bool> confirmPrivilegedHelperInstall() async {
    return false;
  }
}
