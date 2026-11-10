import 'dart:io';

import 'package:gorion/core/process/process_runner.dart';

const managedMacosSystemProxyBypassEntries = <String>[
  'localhost',
  '127.0.0.1',
  '::1',
  '*.local',
  '169.254/16',
  '10.0.0.0/8',
  '172.16.0.0/12',
  '192.168.0.0/16',
];

const managedMacosSteamProxyBypassEntries = <String>[
  'steampowered.com',
  'steamcommunity.com',
  'steamstatic.com',
  'steamcontent.com',
  'steamserver.net',
  'steamgames.com',
  'steamusercontent.com',
  'valvesoftware.com',
];

List<String> buildManagedMacosSystemProxyBypassDomains({
  bool bypassSteam = false,
  List<String> existing = const [],
}) {
  return <String>{
    ...existing,
    ...managedMacosSystemProxyBypassEntries,
    if (bypassSteam) ...managedMacosSteamProxyBypassEntries,
  }.toList(growable: false);
}

/// Snapshot of the proxy state of a single macOS network service.
class MacosServiceProxyState {
  const MacosServiceProxyState({
    required this.service,
    required this.web,
    required this.secureWeb,
    required this.socks,
    required this.bypassDomains,
    this.autoConfigEnabled = false,
    this.autoConfigUrl,
    this.autoDiscoveryEnabled = false,
  });

  final String service;
  final MacosProxyEndpointState web;
  final MacosProxyEndpointState secureWeb;
  final MacosProxyEndpointState socks;
  final List<String> bypassDomains;
  final bool autoConfigEnabled;
  final String? autoConfigUrl;
  final bool autoDiscoveryEnabled;

  Map<String, dynamic> toJson() {
    return {
      'service': service,
      'web': web.toJson(),
      'secureWeb': secureWeb.toJson(),
      'socks': socks.toJson(),
      'bypassDomains': bypassDomains,
      'autoConfigEnabled': autoConfigEnabled,
      'autoConfigUrl': autoConfigUrl,
      'autoDiscoveryEnabled': autoDiscoveryEnabled,
    };
  }

  factory MacosServiceProxyState.fromJson(Map<String, dynamic> json) {
    return MacosServiceProxyState(
      service: json['service']?.toString() ?? '',
      autoConfigEnabled: json['autoConfigEnabled'] == true,
      autoConfigUrl: json['autoConfigUrl']?.toString(),
      autoDiscoveryEnabled: json['autoDiscoveryEnabled'] == true,
      web: MacosProxyEndpointState.fromJson(_asMap(json['web'])),
      secureWeb: MacosProxyEndpointState.fromJson(_asMap(json['secureWeb'])),
      socks: MacosProxyEndpointState.fromJson(_asMap(json['socks'])),
      bypassDomains: [
        for (final entry in (json['bypassDomains'] as List? ?? const []))
          entry.toString(),
      ],
    );
  }

  static Map<String, dynamic> _asMap(Object? value) {
    if (value is Map<String, dynamic>) {
      return value;
    }
    if (value is Map) {
      return Map<String, dynamic>.from(value.cast<String, dynamic>());
    }
    return const <String, dynamic>{};
  }
}

class MacosProxyEndpointState {
  const MacosProxyEndpointState({
    required this.enabled,
    this.server,
    this.port,
    this.authenticated = false,
  });

  final bool enabled;
  final String? server;
  final int? port;
  final bool authenticated;

  bool get isLoopbackManaged {
    final normalized = server?.trim().toLowerCase();
    return port != null &&
        port! > 0 &&
        (normalized == '127.0.0.1' || normalized == 'localhost');
  }

  bool pointsTo(int managedPort) {
    return isLoopbackManaged && port == managedPort;
  }

  Map<String, dynamic> toJson() {
    return {
      'enabled': enabled,
      'server': server,
      'port': port,
      'authenticated': authenticated,
    };
  }

  factory MacosProxyEndpointState.fromJson(Map<String, dynamic> json) {
    return MacosProxyEndpointState(
      enabled: json['enabled'] == true,
      authenticated: json['authenticated'] == true,
      server: json['server']?.toString(),
      port: (json['port'] as num?)?.toInt(),
    );
  }
}

/// Applies and restores the macOS system proxy through `networksetup`.
///
/// `networksetup` proxy commands work for admin users without elevation and
/// write to the SystemConfiguration store shared with System Settings, which
/// keeps us consistent with what the user sees in the UI.
class MacosSystemProxyBackend {
  const MacosSystemProxyBackend({
    Future<ProcessResult> Function(
          String executable,
          List<String> arguments, {
          Duration timeout,
        })
        processRunner =
        _defaultProcessRunner,
  }) : _processRunner = processRunner;

  final Future<ProcessResult> Function(
    String executable,
    List<String> arguments, {
    Duration timeout,
  })
  _processRunner;

  static const _commandTimeout = Duration(seconds: 10);

  static Future<ProcessResult> _defaultProcessRunner(
    String executable,
    List<String> arguments, {
    Duration timeout = _commandTimeout,
  }) {
    return runProcessWithTimeout(executable, arguments, timeout: timeout);
  }

  /// Enabled network services in the order macOS reports them. Disabled
  /// services (prefixed with `*`) and the header note are excluded.
  Future<List<String>> listActiveServices() async {
    final output = await _run(['-listallnetworkservices']);
    final services = <String>[];
    for (final rawLine in output.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('*') || line.contains('asterisk')) {
        continue;
      }
      services.add(line);
    }
    return services;
  }

  Future<MacosServiceProxyState> readService(String service) async {
    final web = _parseEndpoint(await _run(['-getwebproxy', service]));
    final secureWeb = _parseEndpoint(
      await _run(['-getsecurewebproxy', service]),
    );
    final socks = _parseEndpoint(
      await _run(['-getsocksfirewallproxy', service]),
    );
    final bypassRaw = await _run(['-getproxybypassdomains', service]);
    final bypassDomains = bypassRaw
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty && !line.contains("aren't any"))
        .toList(growable: false);

    final autoConfig = await _run(['-getautoproxyurl', service]);
    final autoDiscovery = await _run(['-getproxyautodiscovery', service]);
    final autoUrl = RegExp(
      r'^URL: (.*)$',
      multiLine: true,
    ).firstMatch(autoConfig)?.group(1)?.trim();
    return MacosServiceProxyState(
      autoConfigEnabled: RegExp(
        r'^Enabled: Yes$',
        multiLine: true,
      ).hasMatch(autoConfig),
      autoConfigUrl: autoUrl == '(null)' ? null : autoUrl,
      autoDiscoveryEnabled: autoDiscovery.trim().endsWith('On'),
      service: service,
      web: web,
      secureWeb: secureWeb,
      socks: socks,
      bypassDomains: bypassDomains,
    );
  }

  Future<void> applyManaged(
    String service, {
    required int mixedPort,
    required bool bypassSteam,
    required List<String> existingBypassDomains,
  }) async {
    final bypassDomains = buildManagedMacosSystemProxyBypassDomains(
      bypassSteam: bypassSteam,
      existing: existingBypassDomains,
    );
    await _run(['-setwebproxy', service, '127.0.0.1', '$mixedPort']);
    await _run(['-setsecurewebproxy', service, '127.0.0.1', '$mixedPort']);
    await _run(['-setsocksfirewallproxy', service, '127.0.0.1', '$mixedPort']);
    await _run(['-setproxybypassdomains', service, ...bypassDomains]);
    await _run(['-setautoproxystate', service, 'off']);
    await _run(['-setproxyautodiscovery', service, 'off']);
  }

  /// Brings the service back to [saved]. Called only when the current state
  /// is still managed by us (checked by the caller), so user edits made
  /// after our enable are never overwritten.
  Future<void> restoreService(
    MacosServiceProxyState saved, {
    MacosServiceProxyState? current,
    int? managedPort,
    List<String>? managedBypassDomains,
  }) async {
    Object? firstError;
    Future<void> attempt(Future<void> Function() action) async {
      try {
        await action();
      } on Object catch (error) {
        firstError ??= error;
      }
    }

    final endpoints = [
      ('-setwebproxy', saved.web, current?.web),
      ('-setsecurewebproxy', saved.secureWeb, current?.secureWeb),
      ('-setsocksfirewallproxy', saved.socks, current?.socks),
    ];
    for (final (command, previous, now) in endpoints) {
      if (current == null || now!.pointsTo(managedPort!)) {
        await attempt(() => _restoreEndpoint(saved.service, command, previous));
      }
    }
    final ownsBypass =
        current == null ||
        (managedBypassDomains != null &&
            current.bypassDomains
                .toSet()
                .difference(managedBypassDomains.toSet())
                .isEmpty &&
            managedBypassDomains
                .toSet()
                .difference(current.bypassDomains.toSet())
                .isEmpty);
    if (ownsBypass) {
      await attempt(() async {
        await _run([
          '-setproxybypassdomains',
          saved.service,
          if (saved.bypassDomains.isEmpty) 'Empty' else ...saved.bypassDomains,
        ]);
      });
    }
    if (saved.autoConfigEnabled &&
        (current == null ||
            (!current.autoConfigEnabled &&
                current.autoConfigUrl == saved.autoConfigUrl))) {
      await attempt(() async {
        await _run(['-setautoproxystate', saved.service, 'on']);
      });
    }
    if (saved.autoDiscoveryEnabled &&
        (current == null || !current.autoDiscoveryEnabled)) {
      await attempt(() async {
        await _run(['-setproxyautodiscovery', saved.service, 'on']);
      });
    }
    if (firstError != null) throw firstError!;
  }

  Future<void> _restoreEndpoint(
    String service,
    String setCommand,
    MacosProxyEndpointState saved,
  ) async {
    // Always rewrite the stored server/port first: leaving Gorion's managed
    // endpoint stored under a disabled toggle would hand the user a dead
    // proxy if they ever flip that toggle on manually. `-set*proxy` enables
    // the endpoint as a side effect, so a previously disabled endpoint is
    // turned back off right after.
    var restored = false;
    try {
      await _run([
        setCommand,
        service,
        saved.server?.trim() ?? '',
        '${saved.port ?? 0}',
      ]);
      restored = true;
    } finally {
      // Even a failed endpoint rewrite must attempt to remove the dead
      // managed proxy. Its saved values remain in the recovery journal.
      if (!saved.enabled || !restored) {
        await _run(['${setCommand}state', service, 'off']);
      }
    }
  }

  /// True when the service still points at our managed loopback endpoint, so
  /// restoring it is safe. Any manual change flips this to false.
  bool isServiceManaged(
    MacosServiceProxyState current, {
    required int managedPort,
  }) {
    return current.web.pointsTo(managedPort) ||
        current.secureWeb.pointsTo(managedPort) ||
        current.socks.pointsTo(managedPort);
  }

  MacosProxyEndpointState _parseEndpoint(String output) {
    var enabled = false;
    var authenticated = false;
    String? server;
    int? port;
    for (final rawLine in output.split('\n')) {
      final separatorIndex = rawLine.indexOf(':');
      if (separatorIndex <= 0) {
        continue;
      }
      final key = rawLine.substring(0, separatorIndex).trim().toLowerCase();
      final value = rawLine.substring(separatorIndex + 1).trim();
      switch (key) {
        case 'enabled':
          enabled = value.toLowerCase() == 'yes';
        case 'authenticated proxy enabled':
          authenticated = value == '1' || value.toLowerCase() == 'yes';
        case 'server':
          server = value.isEmpty ? null : value;
        case 'port':
          port = int.tryParse(value);
      }
    }
    return MacosProxyEndpointState(
      enabled: enabled,
      authenticated: authenticated,
      server: server,
      port: port,
    );
  }

  Future<String> _run(List<String> arguments) async {
    final result = await _processRunner(
      '/usr/sbin/networksetup',
      arguments,
      timeout: _commandTimeout,
    );
    if (result.exitCode != 0 || '${result.stdout}'.contains('** Error:')) {
      throw ProcessException(
        'networksetup',
        arguments,
        '${result.stderr}'.trim().isEmpty
            ? '${result.stdout}'.trim()
            : '${result.stderr}'.trim(),
        result.exitCode,
      );
    }
    return '${result.stdout}';
  }
}
