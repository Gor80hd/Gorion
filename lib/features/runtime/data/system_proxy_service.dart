import 'dart:convert';
import 'dart:io';

import 'package:gorion_clean/features/runtime/data/macos_system_proxy.dart';
import 'package:gorion_clean/features/runtime/data/windows_system_proxy.dart';
import 'package:gorion_clean/features/runtime/model/runtime_mode.dart';
import 'package:path/path.dart' as p;

export 'package:gorion_clean/features/runtime/data/macos_system_proxy.dart'
    show
        MacosProxyEndpointState,
        MacosServiceProxyState,
        MacosSystemProxyBackend,
        buildManagedMacosSystemProxyBypassDomains,
        managedMacosSteamProxyBypassEntries,
        managedMacosSystemProxyBypassEntries;
export 'package:gorion_clean/features/runtime/data/windows_system_proxy.dart'
    show
        WindowsProxySettings,
        WindowsSystemProxyBackend,
        buildManagedWindowsSystemProxyOverride,
        buildManagedWindowsSystemProxyServer,
        managedWindowsSteamProxyOverrideEntries,
        managedWindowsSystemProxyOverrideEntries,
        windowsProxyBypassListsMatch,
        windowsProxyServerPointsToManagedEndpoint;

const systemProxyMarkerFileName = 'system-proxy.json';

typedef ProxyLogSink = void Function(String line, {bool isError});

/// Opaque handle for an active system proxy session. The payload is the
/// platform-specific marker map; keeping it opaque lets the facade stay
/// platform-neutral.
class SystemProxyLease {
  const SystemProxyLease._(this.markerJson);

  final Map<String, dynamic> markerJson;
}

/// Facade over the per-platform system proxy backends.
///
/// Guarantees that matter for reliability:
/// - the marker file is written before any system change, so a crash between
///   "enable" and "apply" still leaves enough data to restore;
/// - restore only touches state that is still managed by us, never
///   overwriting user edits made after Gorion connected;
/// - orphaned markers from a previous app session are restored (not just
///   deleted) on the next start.
class SystemProxyService {
  const SystemProxyService({
    WindowsSystemProxyBackend windowsBackend =
        const WindowsSystemProxyBackend(),
    MacosSystemProxyBackend macosBackend = const MacosSystemProxyBackend(),
  }) : _windowsBackend = windowsBackend,
       _macosBackend = macosBackend;

  final WindowsSystemProxyBackend _windowsBackend;
  final MacosSystemProxyBackend _macosBackend;

  Future<SystemProxyLease?> enable({
    required RuntimeMode mode,
    required Directory runtimeDir,
    required int mixedPort,
    bool bypassSteam = false,
    required ProxyLogSink onLog,
  }) async {
    if (!mode.usesSystemProxy) {
      return null;
    }

    if (await _markerFile(runtimeDir).exists()) {
      throw StateError(
        'Previous system proxy recovery is incomplete. Retry disconnect before connecting.',
      );
    }

    if (Platform.isWindows) {
      return _enableWindows(
        runtimeDir: runtimeDir,
        mixedPort: mixedPort,
        bypassSteam: bypassSteam,
        onLog: onLog,
      );
    }
    if (Platform.isMacOS) {
      return _enableMacos(
        runtimeDir: runtimeDir,
        mixedPort: mixedPort,
        bypassSteam: bypassSteam,
        onLog: onLog,
      );
    }

    throw UnsupportedError(
      'System proxy mode is not supported on this platform. '
      'Use TUN or configure apps to use the mixed port directly.',
    );
  }

  Future<void> restore({
    required Directory runtimeDir,
    required SystemProxyLease? lease,
    required ProxyLogSink onLog,
  }) async {
    final markerJson = lease?.markerJson ?? await _readMarkerJson(runtimeDir);
    if (markerJson == null) {
      return;
    }

    final platform = _markerPlatform(markerJson);
    switch (platform) {
      case _MarkerPlatform.windows:
        await _restoreWindows(runtimeDir, markerJson, onLog);
      case _MarkerPlatform.macos:
        await _restoreMacos(runtimeDir, markerJson, onLog);
    }
  }

  /// Repairs proxy state left behind by a previous app session (crash,
  /// kill -9, power loss). Safe to call on every app start.
  Future<void> cleanupOrphanedState({
    required Directory runtimeDir,
    required ProxyLogSink onLog,
  }) async {
    final markerJson = await _readMarkerJson(runtimeDir);
    if (markerJson == null) {
      return;
    }

    try {
      await restore(runtimeDir: runtimeDir, lease: null, onLog: onLog);
    } on Object catch (error) {
      onLog(
        'Failed to clean up stale system proxy settings: $error',
        isError: true,
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Windows
  // ---------------------------------------------------------------------------

  Future<SystemProxyLease> _enableWindows({
    required Directory runtimeDir,
    required int mixedPort,
    required bool bypassSteam,
    required ProxyLogSink onLog,
  }) async {
    final previous = await _windowsBackend.readSettings();
    final managed = previous.copyWith(
      proxyEnable: 1,
      proxyServer: buildManagedWindowsSystemProxyServer(mixedPort),
      proxyOverride: buildManagedWindowsSystemProxyOverride(
        bypassSteam: bypassSteam,
      ),
      clearAutoConfigUrl: true,
    );
    final marker = <String, dynamic>{
      'previousSettings': previous.toJson(),
      'managedSettings': managed.toJson(),
    };
    await _writeMarkerJson(runtimeDir, marker);

    try {
      await _windowsBackend.applySettings(managed);
    } on Object {
      try {
        await _windowsBackend.applySettings(previous);
      } on Object {
        // Keep the marker if rollback fails so the next startup or the
        // watchdog still has the data needed to attempt a restore.
        rethrow;
      }
      await _deleteMarker(runtimeDir);
      rethrow;
    }
    onLog('Windows system proxy enabled through 127.0.0.1:$mixedPort.');
    return SystemProxyLease._(marker);
  }

  Future<void> _restoreWindows(
    Directory runtimeDir,
    Map<String, dynamic> markerJson,
    ProxyLogSink onLog,
  ) async {
    final previous = WindowsProxySettings.fromJson(
      _asMap(markerJson['previousSettings']),
    );
    final managed = WindowsProxySettings.fromJson(
      _asMap(markerJson['managedSettings']),
    );

    var shouldDeleteMarker = false;
    try {
      final current = await _windowsBackend.readSettings();
      if (!current.isManagedBy(managed)) {
        shouldDeleteMarker = true;
        onLog(
          'Windows system proxy settings changed outside Gorion; skipping restore to avoid overwriting newer values.',
        );
        return;
      }

      await _windowsBackend.applySettings(previous);
      shouldDeleteMarker = true;
      onLog('Windows system proxy restored to its previous state.');
    } finally {
      if (shouldDeleteMarker) {
        await _deleteMarker(runtimeDir);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // macOS
  // ---------------------------------------------------------------------------

  Future<SystemProxyLease> _enableMacos({
    required Directory runtimeDir,
    required int mixedPort,
    required bool bypassSteam,
    required ProxyLogSink onLog,
  }) async {
    final services = await _macosBackend.listActiveServices();
    if (services.isEmpty) {
      throw StateError(
        'No active macOS network services found; cannot enable the system proxy.',
      );
    }

    // Snapshot every service first, then write the marker, then apply. This
    // ordering keeps a crash between "apply" steps recoverable.
    final savedStates = <MacosServiceProxyState>[];
    for (final service in services) {
      final state = await _macosBackend.readService(service);
      if ([
        state.web,
        state.secureWeb,
        state.socks,
      ].any((endpoint) => endpoint.authenticated)) {
        throw UnsupportedError(
          'The network service "$service" has an authenticated proxy. '
          'Use local proxy mode to preserve its credentials.',
        );
      }
      savedStates.add(state);
    }
    final marker = <String, dynamic>{
      'platform': 'macos',
      'managedPort': mixedPort,
      'bypassSteam': bypassSteam,
      'services': savedStates.map((state) => state.toJson()).toList(),
    };
    await _writeMarkerJson(runtimeDir, marker);

    final applied = <String>[];
    Object? firstError;
    for (final saved in savedStates) {
      try {
        await _macosBackend.applyManaged(
          saved.service,
          mixedPort: mixedPort,
          bypassSteam: bypassSteam,
          existingBypassDomains: saved.bypassDomains,
        );
        applied.add(saved.service);
      } on Object catch (error) {
        firstError ??= error;
        onLog(
          'Failed to set the system proxy for "${saved.service}": $error',
          isError: true,
        );
      }
    }

    if (firstError != null) {
      // A service can fail after changing only one endpoint. Restore all
      // owned endpoints, keeping the journal if any rollback fails.
      await _restoreMacos(runtimeDir, marker, onLog);
      throw StateError('Failed to enable the macOS system proxy: $firstError');
    }

    onLog(
      'macOS system proxy enabled through 127.0.0.1:$mixedPort '
      'for ${applied.length} service(s): ${applied.join(', ')}.',
    );
    return SystemProxyLease._(marker);
  }

  Future<void> _restoreMacos(
    Directory runtimeDir,
    Map<String, dynamic> markerJson,
    ProxyLogSink onLog,
  ) async {
    final managedPort = (markerJson['managedPort'] as num?)?.toInt() ?? 0;
    final savedStates = [
      for (final entry in (markerJson['services'] as List? ?? const []))
        MacosServiceProxyState.fromJson(_asMap(entry)),
    ];
    if (managedPort <= 0 || savedStates.isEmpty) {
      throw StateError(
        'Invalid proxy recovery journal; refusing to discard it.',
      );
    }

    var sawFailure = false;
    for (final saved in savedStates) {
      try {
        final current = await _macosBackend.readService(saved.service);
        await _macosBackend.restoreService(
          saved,
          current: current,
          managedPort: managedPort,
          managedBypassDomains: buildManagedMacosSystemProxyBypassDomains(
            existing: saved.bypassDomains,
            bypassSteam: markerJson['bypassSteam'] == true,
          ),
        );
      } on Object catch (error) {
        sawFailure = true;
        onLog(
          'Failed to restore the macOS proxy for "${saved.service}": $error',
          isError: true,
        );
      }
    }

    if (sawFailure) {
      // Keep the marker so the next app start can retry the restore.
      throw StateError(
        'Some macOS proxy settings could not be restored; recovery journal retained.',
      );
    }
    await _deleteMarker(runtimeDir);
    onLog('macOS system proxy restored to its previous state.');
  }

  // ---------------------------------------------------------------------------
  // Marker IO
  // ---------------------------------------------------------------------------

  _MarkerPlatform _markerPlatform(Map<String, dynamic> markerJson) {
    if (markerJson['platform'] == 'macos' || markerJson['services'] != null) {
      return _MarkerPlatform.macos;
    }
    return _MarkerPlatform.windows;
  }

  Map<String, dynamic> _asMap(Object? value) {
    if (value is Map<String, dynamic>) {
      return value;
    }
    if (value is Map) {
      return Map<String, dynamic>.from(value.cast<String, dynamic>());
    }
    return const <String, dynamic>{};
  }

  Future<Map<String, dynamic>?> _readMarkerJson(Directory runtimeDir) async {
    final file = _markerFile(runtimeDir);
    if (!await file.exists()) {
      return null;
    }

    try {
      final decoded = jsonDecode(await file.readAsString());
      return _asMap(decoded);
    } on Object {
      throw StateError('Cannot read proxy recovery journal: ${file.path}');
    }
  }

  Future<void> _writeMarkerJson(
    Directory runtimeDir,
    Map<String, dynamic> marker,
  ) async {
    final file = _markerFile(runtimeDir);
    final pending = File('${file.path}.tmp');
    await pending.writeAsString(jsonEncode(marker), flush: true);
    await pending.rename(file.path);
  }

  Future<void> _deleteMarker(Directory runtimeDir) async {
    final file = _markerFile(runtimeDir);
    if (!await file.exists()) {
      return;
    }

    await file.delete();
  }

  File _markerFile(Directory runtimeDir) {
    return File(p.join(runtimeDir.path, systemProxyMarkerFileName));
  }
}

enum _MarkerPlatform { windows, macos }
