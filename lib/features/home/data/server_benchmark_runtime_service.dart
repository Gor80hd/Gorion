import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:gorion_clean/core/http_client/http_client_provider.dart';
import 'package:gorion_clean/features/home/utils/auto_select_probe_utils.dart'
    as probe_utils;
import 'package:gorion_clean/features/profiles/model/profile_entity.dart';
import 'package:gorion_clean/features/proxy/model/outbound_models.dart';
import 'package:gorion_clean/features/runtime/data/singbox_runtime_support.dart';
import 'package:gorion_clean/utils/link_parsers.dart';
import 'package:path/path.dart' as p;

const throughputBenchmarkUrl =
    'https://speed.cloudflare.com/__down?bytes=2097152';
const throughputBenchmarkBytes = 2 * 1024 * 1024;
const pingBenchmarkUrl = 'https://www.gstatic.com/generate_204';
const batchSpeedMaxConcurrentServers = 5;
const batchSpeedTimeout = Duration(seconds: 20);

const _groupTypes = {'selector', 'urltest', 'url-test'};
const _proxySchemes = {
  'http',
  'hysteria',
  'hysteria2',
  'hy',
  'hy2',
  'mieru',
  'naive',
  'shadowtls',
  'shadowsocks',
  'shadowsocksr',
  'socks',
  'ss',
  'ssh',
  'trojan',
  'tuic',
  'vless',
  'vmess',
  'warp',
  'wg',
  'wireguard',
};

String buildServerBenchmarkKey(String profileId, String serverTag) =>
    '$profileId::$serverTag';

Map<String, dynamic>? extractOutboundDefinition(String generatedConfig, String tag) {
  try {
    final config = jsonDecode(generatedConfig) as Map<String, dynamic>;
    final outbounds = config['outbounds'];
    if (outbounds is! List) return null;
    for (final outbound in outbounds) {
      if (outbound is Map<String, dynamic> && outbound['tag'] == tag) {
        return outbound;
      }
    }
  } catch (_) {}
  return null;
}

bool isBenchmarkLeafServer(OutboundInfo item) {
  final type = item.type.trim().toLowerCase();
  return item.isVisible && !item.isGroup && _proxySchemes.contains(type);
}

List<OutboundInfo> visibleBenchmarkServers(OutboundGroup group) =>
    group.items.where(isBenchmarkLeafServer).toList();

class ServerBenchmarkTarget {
  const ServerBenchmarkTarget({
    required this.profile,
    required this.server,
    required this.generatedConfig,
  });

  final ProfileEntity profile;
  final OutboundInfo server;
  final String generatedConfig;

  String get key => buildServerBenchmarkKey(profile.id, server.tag);
}

class _ParsedOfflineGroup {
  const _ParsedOfflineGroup({
    required this.tag,
    required this.selectedTag,
    required this.items,
  });

  final String tag;
  final String? selectedTag;
  final List<OutboundInfo> items;
}

class _BenchmarkRuntimePort {
  const _BenchmarkRuntimePort({
    required this.target,
    required this.outbound,
    required this.port,
    required this.inboundTag,
  });

  final ServerBenchmarkTarget target;
  final Map<String, dynamic> outbound;
  final int port;
  final String inboundTag;

  String get outboundTag => outbound['tag']?.toString() ?? target.server.tag;
}

class BenchmarkDetachedRuntime {
  const BenchmarkDetachedRuntime({
    required this.runtimeDir,
    required this.process,
  });

  final Directory runtimeDir;
  final Process process;
}

typedef BenchmarkRuntimeStarter =
    Future<BenchmarkDetachedRuntime> Function(
      String configJson, {
      required String scope,
    });
typedef BenchmarkLogger =
    void Function(
      String message, {
      String level,
      String source,
    });

class ServerBenchmarkRuntimeService {
  ServerBenchmarkRuntimeService({
    DioHttpClient Function(String userAgent)? httpClientFactory,
    BenchmarkRuntimeStarter? runtimeStarter,
    Future<({ServerSocket socket, int port})> Function()? portAllocator,
    Future<bool> Function(int port, {bool Function()? isCancelled})?
    waitForPortReady,
    BenchmarkLogger? logger,
  }) : _httpClientFactory =
           httpClientFactory ?? _defaultHttpClientFactory,
       _runtimeStarter = runtimeStarter ?? _defaultRuntimeStarter,
       _portAllocator = portAllocator ?? probe_utils.allocateFreePort,
       _waitForPortReady = waitForPortReady ?? _defaultWaitForPortReady,
       _logger = logger ?? _defaultLogger;

  final DioHttpClient Function(String userAgent) _httpClientFactory;
  final BenchmarkRuntimeStarter _runtimeStarter;
  final Future<({ServerSocket socket, int port})> Function() _portAllocator;
  final Future<bool> Function(int port, {bool Function()? isCancelled})
  _waitForPortReady;
  final BenchmarkLogger _logger;

  Future<List<ServerBenchmarkTarget>> loadTargets({
    required List<ProfileEntity> profiles,
    required Future<String> Function(ProfileEntity profile) loadGeneratedConfig,
  }) async {
    final targets = <ServerBenchmarkTarget>[];

    for (final profile in profiles) {
      final generatedConfig = await loadGeneratedConfig(profile);
      if (generatedConfig.isEmpty) {
        continue;
      }

      final parsed = _parseOfflineBenchmarkGroup(
        generatedConfig,
        fallbackGroupName: profile.name,
      );
      final sectionGroup = _toBenchmarkOutboundGroup(parsed);
      if (sectionGroup == null) {
        continue;
      }

      for (final server in visibleBenchmarkServers(sectionGroup)) {
        targets.add(
          ServerBenchmarkTarget(
            profile: profile,
            server: server,
            generatedConfig: generatedConfig,
          ),
        );
      }
    }

    return targets;
  }

  Future<void> runBatch({
    required List<ServerBenchmarkTarget> targets,
    required String userAgent,
    required bool Function() isCancelled,
    required void Function(String status) onStatus,
    required void Function(int completed, int total) onProgress,
    required void Function(String key) onTargetStarted,
    required void Function(String key, int speed) onSpeedProgress,
    required void Function(String key, int ping, int speed) onTargetFinished,
  }) async {
    final reservedPorts = <({ServerSocket socket, int port})>[];
    Directory? runtimeDir;
    Process? process;

    try {
      var completedCount = 0;
      final runtimePorts = <_BenchmarkRuntimePort>[];

      for (var index = 0; index < targets.length; index += 1) {
        final target = targets[index];
        final outbound = extractOutboundDefinition(
          target.generatedConfig,
          target.server.tag,
        );
        if (outbound == null) {
          completedCount += 1;
          onTargetFinished(target.key, -1, 0);
          onProgress(completedCount, targets.length);
          continue;
        }

        final reservedPort = await _portAllocator();
        reservedPorts.add(reservedPort);
        runtimePorts.add(
          _BenchmarkRuntimePort(
            target: target,
            outbound: Map<String, dynamic>.from(outbound),
            port: reservedPort.port,
            inboundTag: 'bench-${index + 1}',
          ),
        );
      }

      if (runtimePorts.isEmpty) {
        onStatus(isCancelled() ? 'Остановлено' : 'Готово');
        return;
      }

      _logger(
        'start active-profile batch on ${runtimePorts.length} ports',
      );
      for (final reservedPort in reservedPorts) {
        await reservedPort.socket.close();
      }
      reservedPorts.clear();

      final runtime = await _runtimeStarter(
        _buildBatchSpeedtestSingboxConfig(runtimePorts),
        scope: 'batch',
      );
      runtimeDir = runtime.runtimeDir;
      process = runtime.process;

      final readiness = await Future.wait(
        runtimePorts.map(
          (runtimePort) => _waitForPortReady(
            runtimePort.port,
            isCancelled: isCancelled,
          ),
        ),
      );
      if (isCancelled() || readiness.any((isReady) => !isReady)) {
        onStatus(isCancelled() ? 'Остановлено' : 'Не удалось запустить тест');
        return;
      }

      final semaphore = _Semaphore(batchSpeedMaxConcurrentServers);
      final tasks = runtimePorts.map((runtimePort) async {
        if (isCancelled()) {
          return;
        }
        await semaphore.acquire();
        final key = runtimePort.target.key;
        try {
          if (isCancelled()) {
            return;
          }
          onTargetStarted(key);
          final result = await _runProxyBenchmark(
            runtimePort.port,
            userAgent: userAgent,
            isCancelled: isCancelled,
            onProgress: (value) => onSpeedProgress(key, value),
          );
          onTargetFinished(key, result.ping, result.speed);
        } finally {
          completedCount += 1;
          onProgress(completedCount, targets.length);
          onStatus('Параллельный тест $completedCount/${targets.length}');
          semaphore.release();
        }
      }).toList();

      await Future.wait(tasks);
      onStatus(isCancelled() ? 'Остановлено' : 'Готово');
    } finally {
      for (final reservedPort in reservedPorts) {
        try {
          await reservedPort.socket.close();
        } catch (_) {}
      }
      try {
        process?.kill();
      } catch (_) {}
      if (runtimeDir != null) {
        try {
          await runtimeDir.delete(recursive: true);
        } catch (_) {}
      }
    }
  }

  Future<({int ping, int speed})> _runProxyBenchmark(
    int proxyPort, {
    required String userAgent,
    required bool Function() isCancelled,
    void Function(int value)? onProgress,
  }) async {
    final testClient = _httpClientFactory(userAgent);
    testClient.setProxyPort(proxyPort);

    final pingSamples = <int>[];
    for (var attempt = 0; attempt < 2; attempt += 1) {
      if (isCancelled()) {
        break;
      }
      final ping = await testClient.pingTest(
        pingBenchmarkUrl,
        requestMode: NetworkRequestMode.proxy,
        timeout: const Duration(seconds: 10),
      );
      if (ping > 0) {
        pingSamples.add(ping);
      }
      if (attempt == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }

    final ping = pingSamples.isEmpty ? -1 : (pingSamples..sort()).first;
    if (ping <= 0 || isCancelled()) {
      return (ping: ping, speed: 0);
    }

    final speed = await testClient
        .benchmarkDownload(
          throughputBenchmarkUrl,
          requestMode: NetworkRequestMode.proxy,
          maxBytes: throughputBenchmarkBytes,
          maxDuration: const Duration(seconds: 10),
          onProgress: onProgress,
        )
        .timeout(batchSpeedTimeout, onTimeout: () => 0);

    return (ping: ping, speed: speed);
  }
}

String formatBenchmarkDebugTimestamp([DateTime? now]) {
  final ts = now ?? DateTime.now();
  final micros = ts.millisecond * 1000 + ts.microsecond;
  String two(int value) => value.toString().padLeft(2, '0');
  return '${ts.year}/${two(ts.month)}/${two(ts.day)} '
      '${two(ts.hour)}:${two(ts.minute)}:${two(ts.second)}.'
      '${micros.toString().padLeft(6, '0')}';
}

_ParsedOfflineGroup? _parseOfflineBenchmarkGroup(
  String rawConfig, {
  required String fallbackGroupName,
}) {
  final decoded = safeDecodeBase64(rawConfig).trim();
  if (decoded.isEmpty) {
    return null;
  }

  return _parseJsonOfflineGroup(
        decoded,
        fallbackGroupName: fallbackGroupName,
      ) ??
      _parseLinkOfflineGroup(decoded, fallbackGroupName: fallbackGroupName);
}

OutboundGroup? _toBenchmarkOutboundGroup(_ParsedOfflineGroup? group) {
  if (group == null || group.items.isEmpty) {
    return null;
  }

  return OutboundGroup(
    tag: group.tag,
    type: 'selector',
    selected: group.selectedTag ?? '',
    items: [
      for (final item in group.items)
        item.clone()
          ..isSelected =
              group.selectedTag != null && item.tag == group.selectedTag
          ..isVisible = true
          ..isGroup = false,
    ],
  );
}

_ParsedOfflineGroup? _parseJsonOfflineGroup(
  String content, {
  required String fallbackGroupName,
}) {
  final jsonText = _extractJsonPayload(content);
  if (jsonText == null) {
    return null;
  }

  try {
    final decoded = jsonDecode(jsonText);
    final groups =
        <
          ({String tag, String type, String? selected, List<String> outbounds})
        >[];
    final proxies = <String, OutboundInfo>{};

    void visit(dynamic node) {
      if (node is List) {
        for (final item in node) {
          visit(item);
        }
        return;
      }
      if (node is! Map) {
        return;
      }

      final map = Map<String, dynamic>.from(node.cast<String, dynamic>());
      final tag = map['tag']?.toString().trim();
      final type = (map['type'] ?? map['protocol'])
          ?.toString()
          .trim()
          .toLowerCase();
      final outbounds = map['outbounds'];

      if (tag != null && tag.isNotEmpty && type != null && type.isNotEmpty) {
        if (_groupTypes.contains(type) && outbounds is List) {
          final tags = outbounds
              .map((entry) => entry?.toString().trim())
              .whereType<String>()
              .where((entry) => entry.isNotEmpty)
              .toList();
          if (tags.isNotEmpty) {
            groups.add((
              tag: tag,
              type: type,
              selected: map['selected']?.toString(),
              outbounds: tags,
            ));
          }
        } else if (_proxySchemes.contains(type)) {
          final serverHost = map['server']?.toString().trim() ?? '';
          final serverPort =
              int.tryParse(map['server_port']?.toString() ?? '') ?? 0;
          proxies[tag] = OutboundInfo(
            tag: tag,
            tagDisplay: tag,
            type: _normalizeType(type),
            isVisible: true,
            isGroup: false,
            host: serverHost,
            port: serverPort,
          );
        }
      }

      for (final value in map.values) {
        visit(value);
      }
    }

    visit(decoded);

    for (final group in groups) {
      final items = group.outbounds
          .map((tag) => proxies[tag])
          .whereType<OutboundInfo>()
          .toList();
      if (items.isNotEmpty) {
        return _ParsedOfflineGroup(
          tag: group.tag,
          selectedTag: group.selected,
          items: items,
        );
      }
    }

    if (proxies.isEmpty) {
      return null;
    }

    return _ParsedOfflineGroup(
      tag: fallbackGroupName,
      selectedTag: null,
      items: proxies.values.toList(),
    );
  } catch (_) {
    return null;
  }
}

_ParsedOfflineGroup? _parseLinkOfflineGroup(
  String content, {
  required String fallbackGroupName,
}) {
  final lines = safeDecodeBase64(content)
      .split(RegExp(r'\r?\n'))
      .map((line) => line.trim())
      .where(
        (line) =>
            line.isNotEmpty && !line.startsWith('#') && !line.startsWith('//'),
      );

  final items = <OutboundInfo>[];
  for (final line in lines) {
    final uri = Uri.tryParse(line);
    if (uri == null || !_proxySchemes.contains(uri.scheme.toLowerCase())) {
      continue;
    }

    final name = uri.hasFragment
        ? Uri.decodeComponent(uri.fragment.split(' -> ').first).trim()
        : '';
    final displayName = name.isNotEmpty ? name : uri.scheme.toUpperCase();
    items.add(
      OutboundInfo(
        tag: displayName,
        tagDisplay: displayName,
        type: _normalizeType(uri.scheme),
        isVisible: true,
        isGroup: false,
        host: uri.host,
        port: uri.port,
      ),
    );
  }

  if (items.isEmpty) {
    return null;
  }

  return _ParsedOfflineGroup(
    tag: fallbackGroupName,
    selectedTag: null,
    items: items,
  );
}

String? _extractJsonPayload(String content) {
  final startIndex = content.indexOf('{');
  if (startIndex == -1) {
    return null;
  }

  final endIndex = content.lastIndexOf('}');
  if (endIndex <= startIndex) {
    return null;
  }

  return content.substring(startIndex, endIndex + 1);
}

String _normalizeType(String type) {
  return switch (type.toLowerCase()) {
    'hy' => 'hysteria',
    'hy2' => 'hysteria2',
    'ss' => 'shadowsocks',
    'wg' => 'wireguard',
    _ => type.toLowerCase(),
  };
}

String _buildBatchSpeedtestSingboxConfig(List<_BenchmarkRuntimePort> runtimePorts) {
  return jsonEncode({
    'log': {'level': 'info'},
    'inbounds': [
      for (final runtimePort in runtimePorts)
        {
          'type': 'mixed',
          'listen': '127.0.0.1',
          'listen_port': runtimePort.port,
          'tag': runtimePort.inboundTag,
        },
    ],
    'outbounds': [
      for (final runtimePort in runtimePorts) runtimePort.outbound,
      {'type': 'direct', 'tag': 'direct'},
    ],
    'route': {
      'rules': [
        for (final runtimePort in runtimePorts)
          {
            'inbound': [runtimePort.inboundTag],
            'outbound': runtimePort.outboundTag,
          },
      ],
      'final': 'direct',
    },
  });
}

DioHttpClient _defaultHttpClientFactory(String userAgent) => DioHttpClient(
  timeout: const Duration(seconds: 15),
  userAgent: userAgent,
  debug: false,
);

Future<BenchmarkDetachedRuntime> _defaultRuntimeStarter(
  String configJson, {
  required String scope,
}) async {
  final runtimeDir = await ensureGorionRuntimeDirectory(
    subdirectory: p.join(
      'benchmark',
      scope,
      DateTime.now().microsecondsSinceEpoch.toString(),
    ),
  );

  try {
    final binaryFile = await prepareSingboxBinary(runtimeDir);
    final configFile = File(p.join(runtimeDir.path, 'config.json'));
    await configFile.writeAsString(configJson);

    final process = await Process.start(
      binaryFile.path,
      ['run', '-c', configFile.path],
      workingDirectory: runtimeDir.path,
      mode: ProcessStartMode.normal,
    );
    unawaited(process.stdout.drain<void>());
    unawaited(process.stderr.drain<void>());

    return BenchmarkDetachedRuntime(runtimeDir: runtimeDir, process: process);
  } catch (_) {
    try {
      await runtimeDir.delete(recursive: true);
    } catch (_) {}
    rethrow;
  }
}

Future<bool> _defaultWaitForPortReady(
  int port, {
  bool Function()? isCancelled,
}) => probe_utils.waitForLocalPortReady(port, isCancelled: isCancelled);

void _defaultLogger(
  String message, {
  String level = 'Info',
  String source = 'batch-speed',
}) {
  debugPrint(
    '${formatBenchmarkDebugTimestamp()} [$level] $source: $message',
  );
}

class _Semaphore {
  _Semaphore(int count) : _count = count;

  int _count;
  final Queue<Completer<void>> _waiters = Queue<Completer<void>>();

  Future<void> acquire() async {
    if (_count > 0) {
      _count -= 1;
      return;
    }

    final completer = Completer<void>();
    _waiters.addLast(completer);
    await completer.future;
  }

  void release() {
    if (_waiters.isEmpty) {
      _count += 1;
      return;
    }

    _waiters.removeFirst().complete();
  }
}
