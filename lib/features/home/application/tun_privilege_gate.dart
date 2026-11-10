import 'dart:io';

import 'package:gorion/core/privileged_helper/macos_helper_installer.dart';
import 'package:gorion/core/windows/elevation_relaunch_prompt_service.dart';
import 'package:gorion/core/windows/windows_elevation_service.dart';
import 'package:gorion/features/runtime/data/runtime_engine.dart';
import 'package:gorion/features/runtime/model/runtime_mode.dart';

/// What the connect flow should do after the privilege check.
class TunPrivilegeOutcome {
  const TunPrivilegeOutcome.proceed({this.statusMessage})
    : proceed = true,
      errorMessage = null;
  const TunPrivilegeOutcome.stopWithStatus(String this.statusMessage)
    : proceed = false,
      errorMessage = null;
  const TunPrivilegeOutcome.stopWithError(String this.errorMessage)
    : proceed = false,
      statusMessage = null;

  /// False when the connect attempt must end here: the user declined, the
  /// install failed, or the app is relaunching elevated.
  final bool proceed;
  final String? statusMessage;
  final String? errorMessage;
}

/// Makes sure TUN can start with the rights it needs before a connect.
///
/// macOS installs the root launchd helper once. Windows relaunches the app
/// elevated when no helper is reachable. Other modes and platforms pass
/// straight through.
class TunPrivilegeGate {
  const TunPrivilegeGate({
    required RuntimeEngine engine,
    required WindowsElevationService elevationService,
    required ElevationRelaunchPromptService promptService,
    required MacosPrivilegedHelperInstaller macosHelperInstaller,
  }) : _engine = engine,
       _elevationService = elevationService,
       _promptService = promptService,
       _macosHelperInstaller = macosHelperInstaller;

  final RuntimeEngine _engine;
  final WindowsElevationService _elevationService;
  final ElevationRelaunchPromptService _promptService;
  final MacosPrivilegedHelperInstaller _macosHelperInstaller;

  Future<TunPrivilegeOutcome> ensure(RuntimeMode mode) async {
    if (mode != RuntimeMode.tun) {
      return const TunPrivilegeOutcome.proceed();
    }
    if (await _engine.canLaunchWithEmbeddedPrivilegeBroker(mode: mode)) {
      return const TunPrivilegeOutcome.proceed();
    }
    if (Platform.isMacOS) {
      return _installMacosHelper();
    }
    if (Platform.isWindows) {
      return _relaunchElevatedOnWindows();
    }
    return const TunPrivilegeOutcome.proceed();
  }

  Future<TunPrivilegeOutcome> _installMacosHelper() async {
    if (!await _promptService.confirmPrivilegedHelperInstall()) {
      return const TunPrivilegeOutcome.stopWithStatus('Запуск TUN отменён.');
    }

    try {
      await _macosHelperInstaller.install();
    } on HelperInstallCancelledException {
      return const TunPrivilegeOutcome.stopWithStatus(
        'Установка системного компонента отменена. TUN не запущен.',
      );
    } on Object catch (error) {
      return TunPrivilegeOutcome.stopWithError(
        'Не удалось установить системный компонент для TUN: $error',
      );
    }

    return const TunPrivilegeOutcome.proceed(
      statusMessage: 'Системный компонент установлен. Подключаемся…',
    );
  }

  Future<TunPrivilegeOutcome> _relaunchElevatedOnWindows() async {
    try {
      if (await _elevationService.isElevated()) {
        return const TunPrivilegeOutcome.proceed();
      }
    } on Object {
      return const TunPrivilegeOutcome.proceed();
    }

    final confirmed = await _promptService.confirmRelaunch(
      action: PendingElevatedLaunchAction.connectTun,
    );
    if (!confirmed) {
      return const TunPrivilegeOutcome.stopWithStatus('Запуск TUN отменён.');
    }

    try {
      await _elevationService.relaunchAsAdministrator(
        action: PendingElevatedLaunchAction.connectTun,
      );
      return const TunPrivilegeOutcome.stopWithStatus(
        'Запрошены права администратора. После подтверждения UAC Gorion '
        'перезапустится и продолжит запуск TUN.',
      );
    } on ElevationRequestCancelledException {
      return const TunPrivilegeOutcome.stopWithError(
        'Запрос прав администратора был отменён. TUN не запущен.',
      );
    } on Object catch (error) {
      return TunPrivilegeOutcome.stopWithError(
        'Не удалось запросить права администратора для TUN: $error',
      );
    }
  }
}
