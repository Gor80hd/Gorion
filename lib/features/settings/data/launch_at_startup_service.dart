import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:launch_at_startup/launch_at_startup.dart';

abstract interface class LaunchAtStartupService {
  Future<bool> isEnabled();

  Future<bool> setEnabled(bool enabled);
}

class DesktopLaunchAtStartupService implements LaunchAtStartupService {
  DesktopLaunchAtStartupService._(this._launchAtStartup);

  factory DesktopLaunchAtStartupService.configure({
    required String appName,
    required String appPath,
    String? packageName,
    List<String> args = const [],
  }) {
    launchAtStartup.setup(
      appName: appName,
      appPath: _quoteExecutablePath(appPath),
      packageName: packageName,
      args: args,
    );
    return DesktopLaunchAtStartupService._(launchAtStartup);
  }

  final LaunchAtStartup _launchAtStartup;

  @override
  Future<bool> isEnabled() {
    return _launchAtStartup.isEnabled();
  }

  @override
  Future<bool> setEnabled(bool enabled) {
    return enabled ? _launchAtStartup.enable() : _launchAtStartup.disable();
  }
}

class NoopLaunchAtStartupService implements LaunchAtStartupService {
  const NoopLaunchAtStartupService();

  @override
  Future<bool> isEnabled() async {
    return false;
  }

  @override
  Future<bool> setEnabled(bool enabled) async {
    return enabled == false;
  }
}

LaunchAtStartupService buildLaunchAtStartupService({
  String appName = 'gorion',
  String? appPath,
  String? packageName,
  List<String> args = const [],
}) {
  if (kIsWeb || !Platform.isWindows) {
    return const NoopLaunchAtStartupService();
  }

  return DesktopLaunchAtStartupService.configure(
    appName: appName,
    appPath: appPath ?? Platform.resolvedExecutable,
    packageName: packageName,
    args: args,
  );
}

String _quoteExecutablePath(String value) {
  final trimmed = value.trim();
  if (trimmed.startsWith('"') && trimmed.endsWith('"')) {
    return trimmed;
  }
  return '"$trimmed"';
}