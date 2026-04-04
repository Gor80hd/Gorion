import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:gap/gap.dart';
import 'package:gorion_clean/core/http_client/http_client_provider.dart';
import 'package:gorion_clean/core/preferences/general_preferences.dart';
import 'package:gorion_clean/core/router/bottom_sheets/bottom_sheets_notifier.dart';
import 'package:gorion_clean/core/router/dialog/dialog_notifier.dart';
import 'package:gorion_clean/core/widget/emoji_flag_text.dart';
import 'package:gorion_clean/core/widget/glass_panel.dart';
import 'package:gorion_clean/core/widget/page_reveal.dart';
import 'package:gorion_clean/features/home/notifier/auto_server_selection_progress.dart';
import 'package:gorion_clean/features/home/utils/auto_select_probe_utils.dart'
    as probe_utils;
import 'package:gorion_clean/features/auto_select/utils/auto_select_server_exclusion.dart';
import 'package:gorion_clean/features/home/widget/selected_server_preview_provider.dart';
import 'package:gorion_clean/features/profiles/data/profile_data_providers.dart';
import 'package:gorion_clean/features/profiles/model/profile_connection_mode.dart';
import 'package:gorion_clean/features/profiles/model/profile_entity.dart';
import 'package:gorion_clean/features/profiles/model/profile_sort_enum.dart';
import 'package:gorion_clean/features/profiles/notifier/active_profile_notifier.dart';
import 'package:gorion_clean/features/profiles/notifier/profiles_update_notifier.dart';
import 'package:gorion_clean/features/profiles/utils/profile_display_order.dart';
import 'package:gorion_clean/features/proxy/data/proxy_data_providers.dart';
import 'package:gorion_clean/features/proxy/model/outbound_models.dart';
import 'package:gorion_clean/features/runtime/notifier/core_restart_signal.dart';
import 'package:gorion_clean/utils/link_parsers.dart';
import 'package:gorion_clean/utils/server_display_text.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:path/path.dart' as p;

// Convert ISO 3166-1 alpha-2 country code to flag emoji

bool _isLeafServer(OutboundInfo item) {
  final type = item.type.trim().toLowerCase();
  return item.isVisible && !item.isGroup && _proxySchemes.contains(type);
}

List<OutboundInfo> _visibleServers(OutboundGroup group) =>
    group.items.where(_isLeafServer).toList();

// ---------------------------------------------------------------------------
// Parallel speed-test helpers (v2rayN-style: temp srun per server)
// ---------------------------------------------------------------------------

/// Extracts a single outbound definition by [tag] from a generated sing-box
/// JSON config string. Returns null when the tag is not found.
Map<String, dynamic>? _extractOutbound(String generatedConfig, String tag) {
  try {
    final config = jsonDecode(generatedConfig) as Map<String, dynamic>;
    final outbounds = config['outbounds'];
    if (outbounds is! List) return null;
    for (final ob in outbounds) {
      if (ob is Map<String, dynamic> && ob['tag'] == tag) {
        return ob;
      }
    }
  } catch (_) {}
  return null;
}

/// Builds a minimal sing-box config suitable for `HiddifyCli srun` that
/// routes all traffic through [outbound] via a mixed inbound on [port].
String _buildSpeedtestSingboxConfig(Map<String, dynamic> outbound, int port) {
  final inboundTag = 'socks$port';
  return jsonEncode({
    // Keep temp core logs visible so the VS Code debug console shows
    // per-port connection activity during the batch speed test.
    'log': {'level': 'info'},
    'inbounds': [
      {
        'type': 'mixed',
        'listen': '127.0.0.1',
        'listen_port': port,
        'tag': inboundTag,
      },
    ],
    'outbounds': [
      outbound,
      {'type': 'direct', 'tag': 'direct'},
    ],
    'route': {'final': outbound['tag']},
  });
}

String _formatDevConsoleTimestamp([DateTime? now]) {
  final ts = now ?? DateTime.now();
  final micros = ts.millisecond * 1000 + (ts.microsecond % 1000);
  String two(int value) => value.toString().padLeft(2, '0');
  return '${ts.year}/${two(ts.month)}/${two(ts.day)} '
      '${two(ts.hour)}:${two(ts.minute)}:${two(ts.second)}.'
      '${micros.toString().padLeft(6, '0')}';
}

void _devConsoleLog(
  String message, {
  String level = 'Info',
  String source = 'batch-speed',
}) {
  debugPrint('${_formatDevConsoleTimestamp()} [$level] $source: $message');
}

Future<bool> _waitForLocalPortReady(int port) =>
    probe_utils.waitForLocalPortReady(port);

// Simple counting semaphore for concurrency control.
class _Semaphore {
  _Semaphore(int count) : _count = count;
  int _count;
  final _waiters = <Completer<void>>[];

  Future<void> acquire() async {
    if (_count > 0) {
      _count--;
      return;
    }
    final c = Completer<void>();
    _waiters.add(c);
    await c.future;
  }

  void release() {
    if (_waiters.isEmpty) {
      _count++;
    } else {
      _waiters.removeAt(0).complete();
    }
  }
}

String _flagEmoji(String code) {
  if (code.length != 2) return '';
  const base = 0x1F1E6 - 0x41;
  final upper = code.toUpperCase();
  return String.fromCharCodes(upper.codeUnits.map((c) => base + c));
}

// Extract country code from tag like "[DE] Germany", "[de] City", or "🇩🇪 Germany"
String? _extractCountryCode(String tag) {
  // Try bracket format first: [DE] or [de]
  final bracketMatch = RegExp(r'^\[([A-Za-z]{2})\]').firstMatch(tag);
  if (bracketMatch != null) {
    return bracketMatch.group(1)!.toUpperCase();
  }

  // Try flag emoji format: 🇩🇪 (regional indicator symbol pairs U+1F1E6..U+1F1FF)
  final runes = tag.runes.toList(growable: false);
  for (var i = 0; i < runes.length - 1; i++) {
    final first = runes[i];
    final second = runes[i + 1];
    if (first >= 0x1F1E6 &&
        first <= 0x1F1FF &&
        second >= 0x1F1E6 &&
        second <= 0x1F1FF) {
      return String.fromCharCodes([
        0x41 + first - 0x1F1E6,
        0x41 + second - 0x1F1E6,
      ]);
    }
  }

  return null;
}

// Strip country prefix (bracket or flag emoji) from a display name
String _stripCountryPrefix(String name) {
  // Strip [XX] or [xx] bracket prefix
  final stripped = name.replaceFirst(RegExp(r'^\[[A-Za-z]{2}\]\s*'), '');
  if (stripped != name) return stripped;

  // Strip leading flag emoji pair
  final runes = name.runes.toList(growable: false);
  if (runes.length >= 2 &&
      runes[0] >= 0x1F1E6 &&
      runes[0] <= 0x1F1FF &&
      runes[1] >= 0x1F1E6 &&
      runes[1] <= 0x1F1FF) {
    // Skip the two regional indicator code points and any trailing space
    var skip = 2;
    while (skip < runes.length && runes[skip] == 0x20) {
      skip++;
    }
    return String.fromCharCodes(runes.skip(skip));
  }

  return name;
}

// Sanitize tag display: strip §markers
String _displayName(OutboundInfo info) {
  final raw = info.tagDisplay.isNotEmpty ? info.tagDisplay : info.tag;
  return normalizeServerDisplayText(raw);
}

Color _typeColor(String type) {
  return switch (type.toLowerCase()) {
    'auto' => const Color(0xFF1EFFAC),
    'vless' => const Color(0xFF1EFFAC),
    'vmess' => const Color(0xFF6366F1),
    'trojan' => const Color(0xFFF59E0B),
    'shadowsocks' || 'ss' => const Color(0xFF3B82F6),
    'hysteria' || 'hysteria2' => const Color(0xFFEC4899),
    'tuic' => const Color(0xFF8B5CF6),
    _ => const Color(0xFF6B7280),
  };
}

Color _pingColor(int ms) {
  if (ms <= 0) return const Color(0xFF6B7280);
  if (ms < 100) return const Color(0xFF22C55E);
  if (ms < 300) return const Color(0xFFF59E0B);
  return const Color(0xFFEF4444);
}

String _formatBytesCompact(int bytes) {
  if (bytes <= 0) return '0 B';

  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var size = bytes.toDouble();
  var unitIndex = 0;

  while (size >= 1024 && unitIndex < units.length - 1) {
    size /= 1024;
    unitIndex++;
  }

  final decimals = switch (unitIndex) {
    0 => 0,
    1 => 0,
    2 => 1,
    _ => 2,
  };
  return '${size.toStringAsFixed(decimals)} ${units[unitIndex]}';
}

String _formatRate(int bytesPerSecond) =>
    '${_formatBytesCompact(bytesPerSecond)}/s';

String _formatElapsed(Duration value) {
  String two(int n) => n.toString().padLeft(2, '0');
  final hours = value.inHours;
  final minutes = value.inMinutes.remainder(60);
  final seconds = value.inSeconds.remainder(60);
  if (hours > 0) {
    return '${two(hours)}:${two(minutes)}:${two(seconds)}';
  }
  return '${two(minutes)}:${two(seconds)}';
}

enum _ServerSortMode { none, ping, alpha }

const _throughputBenchmarkUrl =
    'https://speed.cloudflare.com/__down?bytes=2097152';
const _throughputBenchmarkBytes = 2 * 1024 * 1024;
const _pingBenchmarkUrl = 'https://www.gstatic.com/generate_204';
const _batchSpeedMaxConcurrentServers = 5;
const _batchSpeedTimeout = Duration(seconds: 20);

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

class _BenchmarkTarget {
  const _BenchmarkTarget({
    required this.profile,
    required this.server,
    required this.generatedConfig,
  });

  final ProfileEntity profile;
  final OutboundInfo server;
  final String generatedConfig;
}

String _benchmarkKey(String profileId, String serverTag) =>
    '$profileId::$serverTag';

class ServersPanelWidget extends HookConsumerWidget {
  const ServersPanelWidget({super.key});

  static const panelWidth = 348.0;
  static const topOffset = 50.0;
  static const searchFieldHeight = 48.0;
  static const searchFieldRadius = 20.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final searchCtrl = useTextEditingController();
    final searchQuery = useState('');
    final sortMode = useState(_ServerSortMode.none);
    final isTesting = useState(false);
    final pingResults = useState<Map<String, int>>({});
    final speedResults = useState<Map<String, int>>({});
    final pingCompleted = useState(0);
    final pingTotal = useState(0);
    final pingStatus = useState<String?>(null);
    final benchmarkStartedAt = useState<DateTime?>(null);
    final benchmarkElapsed = useState(Duration.zero);
    final benchmarkingTags = useState<Set<String>>({});
    final expandedSubscriptionIds = useState<Set<String>>({});
    final stopRequested = useState(false);
    final cancelRef = useRef<CancelToken?>(null);

    final selectedPreview = ref.watch(selectedServerPreviewProvider);
    final pendingSelection = ref.watch(pendingServerSelectionProvider);
    final activeProfile = ref.watch(activeProfileProvider).asData?.value;
    final profileRepo = ref.watch(profileRepoFacadeProvider).valueOrNull;
    final profileDataSource = ref.watch(profileDataSourceProvider);
    final storedProfileOrder = ref.watch(Preferences.profileDisplayOrder);
    final connectionMode = ref.watch(Preferences.profileConnectionMode);
    final profilesStream = useMemoized(
      () => profileDataSource
          .watchAll(sort: ProfilesSort.lastUpdate, sortMode: SortMode.ascending)
          .map((entries) => entries.map((entry) => entry.toEntity()).toList()),
      [profileDataSource],
    );
    final profilesAsync = useStream(profilesStream);

    useEffect(() {
      var disposed = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (disposed || !context.mounted) return;
        if (pendingSelection != null) return;
        ref.read(selectedServerPreviewProvider.notifier).state = null;
      });
      return () => disposed = true;
    }, [activeProfile?.id]);

    final allProfiles = sortProfilesForDisplay(
      profilesAsync.data ?? const <ProfileEntity>[],
      storedProfileOrder,
    );

    useEffect(() {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        ref.read(bottomSheetsNotifierProvider.notifier).attachContext(context);
        ref.read(dialogNotifierProvider.notifier).attachContext(context);
      });
      return null;
    }, const []);

    useEffect(() {
      void listener() => searchQuery.value = searchCtrl.text;
      searchCtrl.addListener(listener);
      return () => searchCtrl.removeListener(listener);
    }, [searchCtrl]);

    useEffect(() {
      final startedAt = benchmarkStartedAt.value;
      final shouldTick =
          startedAt != null && (isTesting.value || pingStatus.value != null);
      if (!shouldTick) {
        if (startedAt == null) {
          benchmarkElapsed.value = Duration.zero;
        }
        return null;
      }

      void updateElapsed() {
        benchmarkElapsed.value = DateTime.now().difference(startedAt);
      }

      updateElapsed();
      final timer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => updateElapsed(),
      );
      return timer.cancel;
    }, [benchmarkStartedAt.value, isTesting.value, pingStatus.value]);

    useEffect(() {
      if (!isTesting.value &&
          pingStatus.value == null &&
          benchmarkStartedAt.value != null) {
        benchmarkStartedAt.value = null;
        benchmarkElapsed.value = Duration.zero;
      }
      return null;
    }, [isTesting.value, pingStatus.value, benchmarkStartedAt.value]);

    final proxyRepo = ref.watch(proxyRepositoryProvider);
    final coreRestartSignal = ref.watch(coreRestartSignalProvider);
    final autoServerSelectionEnabled = ref.watch(Preferences.autoSelectServer);
    final autoServerSelectionExcluded = ref
        .watch(Preferences.autoSelectServerExcluded)
        .toSet();
    final autoServerSelectionStatus = ref.watch(
      autoServerSelectionStatusProvider,
    );
    final autoServerSelectionProgress = ref.watch(
      autoServerSelectionProgressProvider,
    );
    final groupAsync = useStream(
      useMemoized(() => proxyRepo.watchProxies(), [
        proxyRepo,
        coreRestartSignal,
      ]),
    );

    final onlineGroup = groupAsync.data?.fold((_) => null, (g) => g);
    final currentOnlineServer = onlineGroup == null
        ? null
        : _visibleServers(onlineGroup).cast<OutboundInfo?>().firstWhere(
            (server) => server?.tag == onlineGroup.selected,
            orElse: () => null,
          );
    final autoCardPing = autoServerSelectionProgress == null
        ? currentOnlineServer?.urlTestDelay
        : 0;
    final autoCardServer = OutboundInfo(
      tag: 'Автоматически',
      tagDisplay: 'Автоматически',
      type: 'auto',
      isVisible: true,
      isGroup: false,
      urlTestDelay: autoCardPing ?? 0,
    );
    final autoCardDescription = autoServerSelectionEnabled
        ? (autoServerSelectionStatus ?? 'Автовыбор включён')
        : 'Выберет лучший доступный сервер, кроме исключённых';
    const autoCardDetailLines = <String>[];
    final activeProfileLabel = activeProfile?.name ?? 'Нет активной подписки';
    final updateState = ref
        .watch(foregroundProfilesUpdateNotifierProvider)
        .valueOrNull;
    final visibleProfiles = allProfiles
        .where((profile) => profile.userOverride?.showOnHome ?? true)
        .toList();
    final visibleProfilesKey = visibleProfiles
        .map(
          (profile) =>
              '${profile.id}:${profile.lastUpdate.millisecondsSinceEpoch}',
        )
        .join('|');
    final subscriptionsSubtitle = allProfiles.isEmpty
        ? 'Добавьте первую подписку из буфера обмена, ссылки или QR-кода'
        : connectionMode == ProfileConnectionMode.mergedProfiles
        ? '${visibleProfiles.length} из ${allProfiles.length} отображаются · Режим: общий пул'
        : '${visibleProfiles.length} из ${allProfiles.length} отображаются · Текущая: $activeProfileLabel';
    final parsedSubscriptionGroupsAsync = useFuture(
      useMemoized(() async {
        if (profileRepo == null) return <String, OutboundGroup?>{};

        final groups = <String, OutboundGroup?>{};
        for (final profile in visibleProfiles) {
          final rawConfig = await profileRepo
              .getRawConfig(profile.id)
              .getOrElse((_) => '')
              .run();
          if (rawConfig.isEmpty) {
            groups[profile.id] = null;
            continue;
          }
          final parsed = _parseOfflineGroup(
            rawConfig,
            fallbackGroupName: profile.name,
          );
          groups[profile.id] = parsed == null ? null : _toOutboundGroup(parsed);
        }
        return groups;
      }, [profileRepo, visibleProfilesKey, coreRestartSignal]),
    );

    useEffect(() {
      final visibleIds = visibleProfiles.map((profile) => profile.id).toSet();
      final retained = expandedSubscriptionIds.value
          .where(visibleIds.contains)
          .toSet();
      final missing = visibleIds.difference(retained);
      expandedSubscriptionIds.value = {...retained, ...missing};
      return null;
    }, [visibleProfilesKey]);

    final parsedSubscriptionGroups =
        parsedSubscriptionGroupsAsync.data ?? const <String, OutboundGroup?>{};
    OutboundGroup? subscriptionGroup(ProfileEntity profile) {
      if (profile.id == activeProfile?.id && onlineGroup != null) {
        return onlineGroup;
      }
      return parsedSubscriptionGroups[profile.id];
    }

    int effectivePing(String profileId, OutboundInfo server) =>
        pingResults.value[_benchmarkKey(profileId, server.tag)] ??
        server.urlTestDelay;

    String autoSelectExclusionKey(String profileId, OutboundInfo server) {
      return buildAutoSelectServerExclusionKey(
        profileId: profileId,
        serverTag: server.tag,
      );
    }

    bool isAutoSelectExcluded(String profileId, OutboundInfo server) {
      return autoServerSelectionExcluded.contains(
        autoSelectExclusionKey(profileId, server),
      );
    }

    Future<void> toggleAutoSelectExclusion(
      ProfileEntity profile,
      OutboundInfo server,
    ) async {
      final next = {...autoServerSelectionExcluded};
      final key = autoSelectExclusionKey(profile.id, server);
      if (!next.add(key)) {
        next.remove(key);
      }

      await ref
          .read(Preferences.autoSelectServerExcluded.notifier)
          .update(next.toList()..sort());
    }

    List<OutboundInfo> visibleSubscriptionServers(ProfileEntity profile) {
      final sectionGroup = subscriptionGroup(profile);
      if (sectionGroup == null) return const <OutboundInfo>[];

      var sectionServers = _visibleServers(sectionGroup);

      if (searchQuery.value.isNotEmpty) {
        final q = searchQuery.value.toLowerCase();
        sectionServers = sectionServers
            .where((s) => _displayName(s).toLowerCase().contains(q))
            .toList();
      }

      switch (sortMode.value) {
        case _ServerSortMode.ping:
          sectionServers = [...sectionServers]
            ..sort((a, b) {
              final da = effectivePing(profile.id, a);
              final db = effectivePing(profile.id, b);
              if (da == 0 && db == 0) return 0;
              if (da == 0) return 1;
              if (db == 0) return -1;
              return da.compareTo(db);
            });
        case _ServerSortMode.alpha:
          sectionServers = [...sectionServers]
            ..sort(
              (a, b) => _displayName(
                a,
              ).toLowerCase().compareTo(_displayName(b).toLowerCase()),
            );
        case _ServerSortMode.none:
          break;
      }

      return sectionServers;
    }

    Duration serverCardRevealDelay(int index, {int baseMilliseconds = 0}) {
      final staggerIndex = index > 8 ? 8 : index;
      return Duration(milliseconds: baseMilliseconds + (staggerIndex * 36));
    }

    final isRemoteProfile = activeProfile is RemoteProfileEntity;

    Future<void> showServerSettings(
      ProfileEntity profile,
      OutboundInfo server,
    ) async {
      Map<String, dynamic>? outbound;
      if (profileRepo != null) {
        final generatedConfig = await profileRepo
            .generateConfig(profile.id)
            .getOrElse((_) => '')
            .run();
        if (generatedConfig.isNotEmpty) {
          outbound = _extractOutbound(generatedConfig, server.tag);
        }
      }

      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) =>
            _ServerSettingsDialog(server: server, outbound: outbound),
      );
    }

    Future<void> setActiveSubscription(ProfileEntity profile) async {
      final repo = await ref.read(profileRepoFacadeProvider.future);
      final result = await repo.setAsActive(profile.id).run();
      result.match(
        (err) => ref
            .read(dialogNotifierProvider.notifier)
            .showCustomAlert(
              title: 'Не удалось сделать подписку текущей',
              message: err.toString(),
            ),
        (_) => null,
      );
    }

    void stopBenchmark() {
      stopRequested.value = true;
      cancelRef.value?.cancel('Пользователь остановил тест');
    }

    Future<List<_BenchmarkTarget>> loadBenchmarkTargets() async {
      if (profileRepo == null) return const <_BenchmarkTarget>[];

      final targets = <_BenchmarkTarget>[];
      for (final profile in visibleProfiles) {
        final generatedConfig = await profileRepo
            .generateConfig(profile.id)
            .getOrElse((_) => '')
            .run();
        if (generatedConfig.isEmpty) continue;

        var sectionGroup = subscriptionGroup(profile);
        if (sectionGroup == null) {
          final rawConfig = await profileRepo
              .getRawConfig(profile.id)
              .getOrElse((_) => '')
              .run();
          if (rawConfig.isNotEmpty) {
            final parsed = _parseOfflineGroup(
              rawConfig,
              fallbackGroupName: profile.name,
            );
            sectionGroup = parsed == null ? null : _toOutboundGroup(parsed);
          }
        }
        if (sectionGroup == null) continue;

        for (final server in _visibleServers(sectionGroup)) {
          targets.add(
            _BenchmarkTarget(
              profile: profile,
              server: server,
              generatedConfig: generatedConfig,
            ),
          );
        }
      }

      return targets;
    }

    Future<({int ping, int speed})> runDetachedBenchmark(
      _BenchmarkTarget target, {
      void Function(int value)? onProgress,
    }) async {
      final outbound = _extractOutbound(
        target.generatedConfig,
        target.server.tag,
      );
      if (outbound == null) {
        return (ping: -1, speed: 0);
      }

      final httpClient = ref.read(httpClientProvider);
      final displayName =
          '${target.profile.name} / ${_displayName(target.server)}';
      final testPort = await probe_utils.allocateFreePort();
      final configJson = _buildSpeedtestSingboxConfig(outbound, testPort.port);

      Directory? tempDir;
      Process? process;
      try {
        tempDir = await Directory.systemTemp.createTemp('gorion_st_');
        final tempFile = File(p.join(tempDir.path, 'config.json'));
        await tempFile.writeAsString(configJson);

        _devConsoleLog('start $displayName on socks${testPort.port}');
        // Close the reserved socket immediately before starting the subprocess.
        await testPort.socket.close();
        process = await Process.start(probe_utils.hiddifyCliPath(), [
          'srun',
          '-c',
          tempFile.path,
        ]);
        unawaited(process.stdout.drain<void>());
        unawaited(process.stderr.drain<void>());

        final portReady = await _waitForLocalPortReady(testPort.port);
        if (!portReady || stopRequested.value) {
          return (ping: -1, speed: 0);
        }

        final testClient = DioHttpClient(
          timeout: const Duration(seconds: 15),
          userAgent: httpClient.userAgent,
          debug: false,
        );
        testClient.setProxyPort(testPort.port);

        final pingSamples = <int>[];
        for (var attempt = 0; attempt < 2; attempt++) {
          if (stopRequested.value) break;
          final ping = await testClient.pingTest(
            _pingBenchmarkUrl,
            requestMode: NetworkRequestMode.proxy,
            timeout: const Duration(seconds: 10),
          );
          if (ping > 0) {
            pingSamples.add(ping);
          }
          if (attempt == 0) {
            await Future.delayed(const Duration(milliseconds: 100));
          }
        }

        final ping = pingSamples.isEmpty ? -1 : (pingSamples..sort()).first;
        if (ping <= 0 || stopRequested.value) {
          return (ping: ping, speed: 0);
        }

        final speed = await testClient
            .benchmarkDownload(
              _throughputBenchmarkUrl,
              requestMode: NetworkRequestMode.proxy,
              maxBytes: _throughputBenchmarkBytes,
              maxDuration: const Duration(seconds: 10),
              onProgress: onProgress,
            )
            .timeout(_batchSpeedTimeout, onTimeout: () => 0);

        return (ping: ping, speed: speed);
      } catch (error) {
        _devConsoleLog('$displayName failed: $error', level: 'Warning');
        return (ping: -1, speed: 0);
      } finally {
        try {
          process?.kill();
        } catch (_) {}
        if (tempDir != null) {
          try {
            await tempDir.delete(recursive: true);
          } catch (_) {}
        }
      }
    }

    Future<void> runSingleBenchmark() async {
      if (isTesting.value || visibleProfiles.isEmpty || profileRepo == null) {
        return;
      }

      try {
        isTesting.value = true;
        stopRequested.value = false;
        ref.read(benchmarkActiveProvider.notifier).state = true;
        pingResults.value = {};
        speedResults.value = {};
        pingCompleted.value = 0;
        pingTotal.value = 0;
        pingStatus.value = 'Подготовка…';
        benchmarkStartedAt.value = DateTime.now();
        benchmarkElapsed.value = Duration.zero;
        benchmarkingTags.value = {};

        final targets = await loadBenchmarkTargets();
        pingTotal.value = targets.length;
        if (targets.isEmpty) {
          pingStatus.value = 'Нет серверов для теста';
          return;
        }

        var completed = 0;
        for (final target in targets) {
          if (stopRequested.value) break;

          final key = _benchmarkKey(target.profile.id, target.server.tag);
          benchmarkingTags.value = {key};
          pingStatus.value =
              '${target.profile.name} · ${_displayName(target.server)}';

          final result = await runDetachedBenchmark(target);
          pingResults.value = {...pingResults.value, key: result.ping};
          speedResults.value = {...speedResults.value, key: result.speed};

          completed += 1;
          pingCompleted.value = completed;
        }

        pingStatus.value = stopRequested.value ? 'Остановлено' : 'Готово';
      } finally {
        benchmarkingTags.value = {};
        ref.read(selectedServerPreviewProvider.notifier).state = null;
        if (context.mounted) {
          isTesting.value = false;
          ref.read(benchmarkActiveProvider.notifier).state = false;
          if (pingStatus.value != 'Остановлено') pingStatus.value = null;
        }
      }
    }

    Future<void> runBatchBenchmark() async {
      if (isTesting.value || visibleProfiles.isEmpty || profileRepo == null) {
        return;
      }

      try {
        isTesting.value = true;
        stopRequested.value = false;
        ref.read(benchmarkActiveProvider.notifier).state = true;
        pingResults.value = {};
        speedResults.value = {};
        pingCompleted.value = 0;
        pingTotal.value = 0;
        pingStatus.value = 'Подготовка…';
        benchmarkStartedAt.value = DateTime.now();
        benchmarkElapsed.value = Duration.zero;
        benchmarkingTags.value = {};

        final targets = await loadBenchmarkTargets();
        pingTotal.value = targets.length;
        if (targets.isEmpty) {
          pingStatus.value = 'Нет серверов для теста';
          return;
        }

        final semaphore = _Semaphore(_batchSpeedMaxConcurrentServers);
        var completedCount = 0;

        final tasks = targets.map((target) async {
          if (stopRequested.value) return;
          await semaphore.acquire();
          final key = _benchmarkKey(target.profile.id, target.server.tag);
          try {
            if (stopRequested.value) return;
            benchmarkingTags.value = {...benchmarkingTags.value, key};

            final result = await runDetachedBenchmark(
              target,
              onProgress: (value) {
                speedResults.value = {...speedResults.value, key: value};
              },
            );
            pingResults.value = {...pingResults.value, key: result.ping};
            speedResults.value = {...speedResults.value, key: result.speed};
          } finally {
            final nextBenchmarking = {...benchmarkingTags.value};
            nextBenchmarking.remove(key);
            benchmarkingTags.value = nextBenchmarking;
            completedCount += 1;
            pingCompleted.value = completedCount;
            pingStatus.value =
                'Параллельный тест $completedCount/${targets.length}';
            semaphore.release();
          }
        }).toList();

        await Future.wait(tasks);
        pingStatus.value = stopRequested.value ? 'Остановлено' : 'Готово';
      } finally {
        benchmarkingTags.value = {};
        ref.read(selectedServerPreviewProvider.notifier).state = null;
        if (context.mounted) {
          isTesting.value = false;
          ref.read(benchmarkActiveProvider.notifier).state = false;
          if (pingStatus.value != 'Остановлено') pingStatus.value = null;
        }
      }
    }

    return SizedBox(
      width: panelWidth,
      child: Padding(
        padding: const EdgeInsets.only(top: topOffset, bottom: 16, left: 8),
        child: Column(
          children: [
            GlassPanel(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
              borderRadius: 20,
              backgroundColor: Colors.white,
              opacity: 0.08,
              strokeOpacity: 0.22,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.18),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
              ],
              child: Column(
                children: [
                  _GlassTextField(
                    controller: searchCtrl,
                    hint: 'Поиск',
                    prefixIcon: const Icon(
                      Icons.search_rounded,
                      size: 18,
                      color: Color(0xFF8899AA),
                    ),
                  ),
                  const Gap(8),
                  Row(
                    children: [
                      Expanded(
                        child: _SortDropdown(
                          value: sortMode.value,
                          onChanged: (mode) => sortMode.value = mode,
                        ),
                      ),
                      const Gap(6),
                      if (isTesting.value)
                        _SmallGlassButton(
                          icon: Icons.stop_circle_rounded,
                          tooltip: 'Остановить тест',
                          isStop: true,
                          onTap: stopBenchmark,
                        )
                      else
                        _BenchmarkMenuButton(
                          enabled:
                              visibleProfiles.isNotEmpty && profileRepo != null,
                          onSingle: runSingleBenchmark,
                          onBatch: runBatchBenchmark,
                        ),
                      if (isRemoteProfile) ...[
                        const Gap(6),
                        _SmallGlassButton(
                          icon: updateState?.running == true
                              ? Icons.sync_rounded
                              : Icons.refresh_rounded,
                          tooltip: 'Обновить подписки',
                          onTap: updateState?.running == true
                              ? null
                              : () {
                                  ref
                                      .read(
                                        foregroundProfilesUpdateNotifierProvider
                                            .notifier,
                                      )
                                      .trigger();
                                },
                        ),
                      ],
                    ],
                  ),
                  if (isTesting.value || pingStatus.value != null) ...[
                    const Gap(10),
                    _PingTestProgress(
                      completed: pingCompleted.value,
                      total: pingTotal.value,
                      status: pingStatus.value,
                      elapsed: benchmarkElapsed.value,
                    ),
                  ],
                ],
              ),
            ),
            const Gap(8),
            _SubscriptionStrip(
              title: 'Подписки',
              subtitle: subscriptionsSubtitle,
              updateState: updateState,
              onAdd: () => ref
                  .read(bottomSheetsNotifierProvider.notifier)
                  .showAddProfile(),
              onManage: () => ref
                  .read(bottomSheetsNotifierProvider.notifier)
                  .showProfilesOverview(),
            ),
            Expanded(
              child: () {
                if (profilesAsync.connectionState == ConnectionState.waiting &&
                    !profilesAsync.hasData) {
                  return const Center(
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Color(0xFF1EFFAC),
                    ),
                  );
                }
                if (allProfiles.isEmpty) {
                  return const Center(child: _EmptyServersCard());
                }
                if (allProfiles.isNotEmpty && visibleProfiles.isEmpty) {
                  return ListView(
                    padding: const EdgeInsets.only(top: 8, right: 4, bottom: 8),
                    children: [
                      _SubscriptionsHiddenHint(
                        onManage: () => ref
                            .read(bottomSheetsNotifierProvider.notifier)
                            .showProfilesOverview(),
                      ),
                    ],
                  );
                }

                return ListView(
                  padding: const EdgeInsets.only(right: 4, bottom: 8),
                  children: [
                    const Gap(8),
                    PageReveal(
                      key: const ValueKey('auto-server-card-reveal'),
                      delay: serverCardRevealDelay(0, baseMilliseconds: 40),
                      duration: const Duration(milliseconds: 220),
                      child: _ServerCard(
                        key: const ValueKey('auto-server-card'),
                        server: autoCardServer,
                        isSelected: autoServerSelectionEnabled,
                        groupName: autoCardDescription,
                        detailLines: autoCardDetailLines,
                        groupTag: onlineGroup?.tag ?? '',
                        pingOverride: autoCardPing,
                        hasSpeedResult: false,
                        isBenchmarking: false,
                        selectionProgress: autoServerSelectionProgress,
                        onSelect: () async {
                          ref
                                  .read(selectedServerPreviewProvider.notifier)
                                  .state =
                              null;
                          ref
                                  .read(pendingServerSelectionProvider.notifier)
                                  .state =
                              null;
                          await ref
                              .read(Preferences.autoSelectServer.notifier)
                              .update(true);
                        },
                      ),
                    ),
                    const Gap(2),
                    for (final profile in visibleProfiles) ...[
                      Builder(
                        builder: (context) {
                          final sectionGroup = subscriptionGroup(profile);
                          final sectionServers = visibleSubscriptionServers(
                            profile,
                          );
                          final isExpanded = expandedSubscriptionIds.value
                              .contains(profile.id);
                          final isActiveProfile =
                              connectionMode ==
                                  ProfileConnectionMode.currentProfile &&
                              profile.id == activeProfile?.id;

                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _SubscriptionCompactRow(
                                name: profile.name,
                                serverCount: sectionServers.length,
                                isActive: isActiveProfile,
                                isExpanded: isExpanded,
                                onTap: () {
                                  final next = {
                                    ...expandedSubscriptionIds.value,
                                  };
                                  if (!next.add(profile.id)) {
                                    next.remove(profile.id);
                                  }
                                  expandedSubscriptionIds.value = next;
                                },
                              ),
                              if (isExpanded) ...[
                                const Gap(6),
                                if (sectionGroup == null)
                                  const _SubscriptionServersPlaceholder(
                                    message:
                                        'Не удалось загрузить серверы для этой подписки.',
                                  )
                                else if (sectionServers.isEmpty)
                                  _SubscriptionServersPlaceholder(
                                    message: searchQuery.value.isNotEmpty
                                        ? 'По текущему фильтру серверы не найдены.'
                                        : 'В этой подписке пока нет доступных серверов.',
                                  )
                                else
                                  for (
                                    var index = 0;
                                    index < sectionServers.length;
                                    index++
                                  ) ...[
                                    Builder(
                                      builder: (context) {
                                        final server = sectionServers[index];
                                        final isAutoExcluded =
                                            isAutoSelectExcluded(
                                              profile.id,
                                              server,
                                            );
                                        return PageReveal(
                                          key: ValueKey(
                                            'reveal-${_benchmarkKey(profile.id, server.tag)}',
                                          ),
                                          delay: serverCardRevealDelay(
                                            index,
                                            baseMilliseconds: 90,
                                          ),
                                          duration: const Duration(
                                            milliseconds: 220,
                                          ),
                                          offset: const Offset(0, 0.045),
                                          child: _ServerCard(
                                            key: ValueKey(
                                              _benchmarkKey(
                                                profile.id,
                                                server.tag,
                                              ),
                                            ),
                                            server: server,
                                            isSelected:
                                                !autoServerSelectionEnabled &&
                                                ((pendingSelection?.profileId ==
                                                            profile.id &&
                                                        pendingSelection
                                                                ?.outboundTag ==
                                                            server.tag) ||
                                                    (isActiveProfile &&
                                                        (selectedPreview != null
                                                            ? selectedPreview
                                                                      .tag ==
                                                                  server.tag
                                                            : server
                                                                  .isSelected))),
                                            groupName: '',
                                            groupTag: sectionGroup.tag,
                                            pingOverride:
                                                pingResults.value[_benchmarkKey(
                                                  profile.id,
                                                  server.tag,
                                                )],
                                            speedOverride:
                                                speedResults
                                                    .value[_benchmarkKey(
                                                  profile.id,
                                                  server.tag,
                                                )],
                                            hasSpeedResult: speedResults.value
                                                .containsKey(
                                                  _benchmarkKey(
                                                    profile.id,
                                                    server.tag,
                                                  ),
                                                ),
                                            isBenchmarking: benchmarkingTags
                                                .value
                                                .contains(
                                                  _benchmarkKey(
                                                    profile.id,
                                                    server.tag,
                                                  ),
                                                ),
                                            isAutoExcluded: isAutoExcluded,
                                            onToggleAutoExclusion: () =>
                                                toggleAutoSelectExclusion(
                                                  profile,
                                                  server,
                                                ),
                                            onShowDetails: () =>
                                                showServerSettings(
                                                  profile,
                                                  server,
                                                ),
                                            onSelect: isTesting.value
                                                ? null
                                                : () async {
                                                    await ref
                                                        .read(
                                                          Preferences
                                                              .autoSelectServer
                                                              .notifier,
                                                        )
                                                        .update(false);
                                                    final selectionRequestId =
                                                        DateTime.now()
                                                            .microsecondsSinceEpoch;
                                                    ref
                                                        .read(
                                                          selectedServerPreviewProvider
                                                              .notifier,
                                                        )
                                                        .state = server.clone()
                                                      ..isSelected = true;
                                                    ref
                                                        .read(
                                                          pendingServerSelectionProvider
                                                              .notifier,
                                                        )
                                                        .state = PendingServerSelection(
                                                      requestId:
                                                          selectionRequestId,
                                                      profileId: profile.id,
                                                      groupTag:
                                                          connectionMode ==
                                                              ProfileConnectionMode
                                                                  .mergedProfiles
                                                          ? null
                                                          : sectionGroup.tag,
                                                      outboundTag: server.tag,
                                                    );
                                                    if (!isActiveProfile &&
                                                        connectionMode ==
                                                            ProfileConnectionMode
                                                                .currentProfile) {
                                                      await setActiveSubscription(
                                                        profile,
                                                      );
                                                      return;
                                                    }
                                                    final liveGroupTag =
                                                        connectionMode ==
                                                            ProfileConnectionMode
                                                                .mergedProfiles
                                                        ? onlineGroup?.tag
                                                        : sectionGroup.tag;
                                                    if (liveGroupTag == null) {
                                                      return;
                                                    }
                                                    final result = await ref
                                                        .read(
                                                          proxyRepositoryProvider,
                                                        )
                                                        .selectProxy(
                                                          liveGroupTag,
                                                          server.tag,
                                                        )
                                                        .run();
                                                    result.match((_) => null, (
                                                      _,
                                                    ) {
                                                      final currentPending = ref
                                                          .read(
                                                            pendingServerSelectionProvider,
                                                          );
                                                      if (currentPending
                                                              ?.requestId ==
                                                          selectionRequestId) {
                                                        ref
                                                                .read(
                                                                  pendingServerSelectionProvider
                                                                      .notifier,
                                                                )
                                                                .state =
                                                            null;
                                                      }
                                                    });
                                                  },
                                          ),
                                        );
                                      },
                                    ),
                                  ],
                              ],
                              const Gap(8),
                            ],
                          );
                        },
                      ),
                    ],
                  ],
                );
              }(),
            ),
          ],
        ),
      ),
    );
  }
}

_ParsedOfflineGroup? _parseOfflineGroup(
  String rawConfig, {
  required String fallbackGroupName,
}) {
  final decoded = safeDecodeBase64(rawConfig).trim();
  if (decoded.isEmpty) return null;

  return _parseJsonOfflineGroup(
        decoded,
        fallbackGroupName: fallbackGroupName,
      ) ??
      _parseLinkOfflineGroup(decoded, fallbackGroupName: fallbackGroupName);
}

_ParsedOfflineGroup? _parseJsonOfflineGroup(
  String content, {
  required String fallbackGroupName,
}) {
  final jsonText = _extractJsonPayload(content);
  if (jsonText == null) return null;

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
      if (node is! Map) return;

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

    if (proxies.isEmpty) return null;
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

  if (items.isEmpty) return null;
  return _ParsedOfflineGroup(
    tag: fallbackGroupName,
    selectedTag: null,
    items: items,
  );
}

String? _extractJsonPayload(String content) {
  final startIndex = content.indexOf('{');
  if (startIndex == -1) return null;

  final endIndex = content.lastIndexOf('}');
  if (endIndex <= startIndex) return null;

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

OutboundGroup? _toOutboundGroup(_ParsedOfflineGroup? group) {
  if (group == null || group.items.isEmpty) return null;

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

class _GlassTextField extends StatelessWidget {
  const _GlassTextField({
    required this.controller,
    required this.hint,
    this.prefixIcon,
  });

  final TextEditingController controller;
  final String hint;
  final Widget? prefixIcon;

  @override
  Widget build(BuildContext context) {
    return GlassPanel(
      height: ServersPanelWidget.searchFieldHeight,
      borderRadius: ServersPanelWidget.searchFieldRadius,
      backgroundColor: Colors.white,
      opacity: 0.06,
      strokeOpacity: 0.0,
      child: TextField(
        controller: controller,
        textAlignVertical: TextAlignVertical.center,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 15,
          fontWeight: FontWeight.w600,
          height: 1.1,
        ),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(
            color: Colors.white.withValues(alpha: 0.92),
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
          prefixIcon: prefixIcon,
          prefixIconConstraints: prefixIcon == null
              ? null
              : const BoxConstraints(
                  minWidth: 42,
                  minHeight: ServersPanelWidget.searchFieldHeight,
                ),
          contentPadding: prefixIcon == null
              ? const EdgeInsets.symmetric(horizontal: 18)
              : const EdgeInsets.only(right: 18),
          isDense: true,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          disabledBorder: InputBorder.none,
          errorBorder: InputBorder.none,
          focusedErrorBorder: InputBorder.none,
        ),
      ),
    );
  }
}

class _SortDropdown extends StatelessWidget {
  const _SortDropdown({required this.value, required this.onChanged});

  final _ServerSortMode value;
  final ValueChanged<_ServerSortMode> onChanged;

  String get _label => switch (value) {
    _ServerSortMode.none => 'Без сортировки',
    _ServerSortMode.ping => 'По пингу',
    _ServerSortMode.alpha => 'По алфавиту',
  };

  @override
  Widget build(BuildContext context) {
    final isActive = value != _ServerSortMode.none;

    return GlassPanel(
      height: 42,
      borderRadius: 15,
      backgroundColor: Colors.white,
      opacity: isActive ? 0.09 : 0.05,
      strokeOpacity: isActive ? 0.2 : 0.08,
      child: PopupMenuButton<_ServerSortMode>(
        initialValue: value,
        tooltip: 'Сортировка',
        onSelected: onChanged,
        color: const Color(0xCC09110D),
        elevation: 12,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        itemBuilder: (context) => [
          _sortMenuItem(_ServerSortMode.none, 'Без сортировки', value),
          _sortMenuItem(_ServerSortMode.ping, 'По пингу', value),
          _sortMenuItem(_ServerSortMode.alpha, 'По алфавиту', value),
        ],
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            children: [
              Icon(
                Icons.tune_rounded,
                size: 15,
                color: isActive
                    ? const Color(0xFF1EFFAC)
                    : Colors.white.withValues(alpha: 0.55),
              ),
              const Gap(8),
              Expanded(
                child: Text(
                  _label,
                  style: TextStyle(
                    color: isActive
                        ? const Color(0xFF1EFFAC)
                        : Colors.white.withValues(alpha: 0.7),
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Icon(
                Icons.keyboard_arrow_down_rounded,
                color: Colors.white.withValues(alpha: 0.5),
              ),
            ],
          ),
        ),
      ),
    );
  }

  PopupMenuItem<_ServerSortMode> _sortMenuItem(
    _ServerSortMode mode,
    String label,
    _ServerSortMode currentValue,
  ) {
    final selected = mode == currentValue;

    return PopupMenuItem<_ServerSortMode>(
      value: mode,
      child: Row(
        children: [
          Icon(
            selected ? Icons.check_rounded : Icons.circle_outlined,
            size: 16,
            color: selected
                ? const Color(0xFF1EFFAC)
                : Colors.white.withValues(alpha: 0.55),
          ),
          const Gap(8),
          Text(
            label,
            style: TextStyle(
              color: selected
                  ? const Color(0xFF1EFFAC)
                  : Colors.white.withValues(alpha: 0.82),
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _BenchmarkMenuButton extends StatelessWidget {
  const _BenchmarkMenuButton({
    required this.enabled,
    required this.onSingle,
    required this.onBatch,
  });

  final bool enabled;
  final VoidCallback onSingle;
  final VoidCallback onBatch;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Тест серверов',
      child: PopupMenuButton<_BenchmarkMode>(
        enabled: enabled,
        tooltip: '',
        color: const Color(0xCC09110D),
        elevation: 12,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        onSelected: (mode) {
          if (mode == _BenchmarkMode.single) {
            onSingle();
          } else {
            onBatch();
          }
        },
        itemBuilder: (context) => [
          _benchmarkMenuItem(
            _BenchmarkMode.batch,
            Icons.bolt_rounded,
            'Пакетный тест',
            'Пинг быстро, скорость через сервер',
            const Color(0xFF1EFFAC),
          ),
          _benchmarkMenuItem(
            _BenchmarkMode.single,
            Icons.network_check_rounded,
            'Одиночный тест',
            'Полный тест по очереди (точнее)',
            const Color(0xFFF59E0B),
          ),
        ],
        child: GlassPanel(
          width: 42,
          height: 42,
          borderRadius: 15,
          backgroundColor: Colors.white,
          opacity: enabled ? 0.07 : 0.03,
          strokeOpacity: enabled ? 0.14 : 0.06,
          child: Center(
            child: Icon(
              Icons.network_check_rounded,
              size: 17,
              color: enabled
                  ? Colors.white.withValues(alpha: 0.75)
                  : Colors.white.withValues(alpha: 0.28),
            ),
          ),
        ),
      ),
    );
  }

  PopupMenuItem<_BenchmarkMode> _benchmarkMenuItem(
    _BenchmarkMode mode,
    IconData icon,
    String title,
    String subtitle,
    Color color,
  ) {
    return PopupMenuItem<_BenchmarkMode>(
      value: mode,
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const Gap(10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.92),
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
              Text(
                subtitle,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.45),
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

enum _BenchmarkMode { single, batch }

class _SmallGlassButton extends StatelessWidget {
  const _SmallGlassButton({
    required this.icon,
    this.tooltip = '',
    this.isStop = false,
    this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final bool isStop;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final iconColor = isStop
        ? const Color(0xFFEF4444).withValues(alpha: 0.88)
        : enabled
        ? Colors.white.withValues(alpha: 0.75)
        : Colors.white.withValues(alpha: 0.28);

    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        child: GlassPanel(
          width: 42,
          height: 42,
          borderRadius: 15,
          backgroundColor: isStop ? Colors.red : Colors.white,
          opacity: isStop ? 0.1 : (enabled ? 0.07 : 0.03),
          strokeOpacity: isStop ? 0.22 : (enabled ? 0.14 : 0.06),
          child: Center(child: Icon(icon, size: 17, color: iconColor)),
        ),
      ),
    );
  }
}

class _PingTestProgress extends StatelessWidget {
  const _PingTestProgress({
    required this.completed,
    required this.total,
    required this.status,
    required this.elapsed,
  });

  final int completed;
  final int total;
  final String? status;
  final Duration elapsed;

  @override
  Widget build(BuildContext context) {
    final progress = total > 0 ? completed / total : null;
    final label =
        status ??
        (total > 0
            ? 'Проверено $completed из $total'
            : 'Подготовка benchmark…');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.72),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Gap(8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.12),
                  width: 0.7,
                ),
              ),
              child: Text(
                _formatElapsed(elapsed),
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.82),
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.3,
                ),
              ),
            ),
          ],
        ),
        const Gap(6),
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(
            minHeight: 6,
            value: total > 0 ? progress : null,
            backgroundColor: Colors.white.withValues(alpha: 0.08),
            valueColor: const AlwaysStoppedAnimation(Color(0xFF1EFFAC)),
          ),
        ),
      ],
    );
  }
}

class _SubscriptionStrip extends StatelessWidget {
  const _SubscriptionStrip({
    required this.title,
    required this.subtitle,
    required this.updateState,
    this.onAdd,
    this.onManage,
  });

  final String title;
  final String subtitle;
  final ({
    String? currentName,
    int completed,
    int total,
    int updated,
    int failed,
    bool running,
    bool force,
    DateTime? lastRun,
    String? message,
  })?
  updateState;
  final VoidCallback? onAdd;
  final VoidCallback? onManage;

  @override
  Widget build(BuildContext context) {
    final isRunning = updateState?.running == true;
    final progress = isRunning && (updateState?.total ?? 0) > 0
        ? (updateState!.completed / updateState!.total).clamp(0.0, 1.0)
        : null;
    final statusLine = isRunning
        ? '${updateState?.message ?? 'Обновляем подписки…'}${updateState?.currentName != null ? ' · ${updateState!.currentName}' : ''}'
        : _formatUpdateSummary(updateState);

    return GlassPanel(
      padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
      borderRadius: 15,
      backgroundColor: Colors.white,
      opacity: 0.06,
      strokeOpacity: 0.14,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const Gap(2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.56),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const Gap(8),
              _SmallGlassButton(
                icon: Icons.add_rounded,
                tooltip: 'Добавить подписку',
                onTap: onAdd,
              ),
              const Gap(6),
              _SmallGlassButton(
                icon: Icons.inventory_2_outlined,
                tooltip: 'Список подписок',
                onTap: onManage,
              ),
            ],
          ),
          if (statusLine != null && statusLine.isNotEmpty) ...[
            const Gap(10),
            Text(
              statusLine,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.7),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          if (isRunning) ...[
            const Gap(8),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                minHeight: 6,
                value: progress,
                backgroundColor: Colors.white.withValues(alpha: 0.08),
                valueColor: const AlwaysStoppedAnimation(Color(0xFF1EFFAC)),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SubscriptionCompactRow extends StatelessWidget {
  const _SubscriptionCompactRow({
    required this.name,
    required this.serverCount,
    required this.isActive,
    required this.isExpanded,
    required this.onTap,
  });

  final String name;
  final int serverCount;
  final bool isActive;
  final bool isExpanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = isActive
        ? const Color(0xFF1EFFAC)
        : Colors.white.withValues(alpha: 0.78);

    return GestureDetector(
      onTap: onTap,
      child: GlassPanel(
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        margin: const EdgeInsets.only(right: 4),
        borderRadius: 12,
        backgroundColor: Colors.white,
        opacity: isActive ? 0.08 : 0.05,
        strokeOpacity: isActive ? 0.22 : 0.14,
        strokeColor: isActive ? const Color(0xFF1EFFAC) : Colors.white,
        child: Row(
          children: [
            Icon(Icons.layers_rounded, size: 13, color: accent),
            const Gap(8),
            Expanded(
              child: Text(
                name,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: isActive ? FontWeight.w800 : FontWeight.w700,
                  letterSpacing: 0.2,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text(
              '$serverCount',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.4),
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
            const Gap(6),
            AnimatedRotation(
              turns: isExpanded ? 0.25 : 0,
              duration: const Duration(milliseconds: 200),
              child: Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: Colors.white.withValues(alpha: 0.45),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SubscriptionServersPlaceholder extends StatelessWidget {
  const _SubscriptionServersPlaceholder({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 0, 2),
      child: Text(
        message,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.58),
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

class _SubscriptionActionChip extends StatelessWidget {
  const _SubscriptionActionChip({
    required this.icon,
    required this.label,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final color = Colors.white.withValues(alpha: 0.82);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.18), width: 0.7),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: color),
            const Gap(6),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SubscriptionsHiddenHint extends StatelessWidget {
  const _SubscriptionsHiddenHint({required this.onManage});

  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) {
    return GlassPanel(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      borderRadius: 15,
      backgroundColor: Colors.white,
      opacity: 0.05,
      strokeOpacity: 0.14,
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Все подписки скрыты. Включите нужные в настройках подписок.',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.68),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const Gap(10),
          _SubscriptionActionChip(
            icon: Icons.tune_rounded,
            label: 'Открыть',
            onTap: onManage,
          ),
        ],
      ),
    );
  }
}

String? _formatUpdateSummary(
  ({
    String? currentName,
    int completed,
    int total,
    int updated,
    int failed,
    bool running,
    bool force,
    DateTime? lastRun,
    String? message,
  })?
  updateState,
) {
  if (updateState == null) {
    return 'Автообновление проверяет подписки каждые 15 минут.';
  }
  if (updateState.message?.isNotEmpty == true && updateState.running == false) {
    return '${updateState.message}${updateState.lastRun != null ? ' · ${_formatLastRun(updateState.lastRun!)}' : ''}';
  }
  if (updateState.lastRun != null) {
    return _formatLastRun(updateState.lastRun!);
  }
  return 'Автообновление проверяет подписки каждые 15 минут.';
}

String _formatLastRun(DateTime lastRun) {
  final local = lastRun.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return 'Последняя проверка: ${two(local.day)}.${two(local.month)} ${two(local.hour)}:${two(local.minute)}';
}

class _EmptyServersCard extends StatelessWidget {
  const _EmptyServersCard();

  @override
  Widget build(BuildContext context) {
    return GlassPanel(
      margin: const EdgeInsets.only(right: 4, bottom: 10),
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
      borderRadius: 15,
      backgroundColor: Colors.white,
      opacity: 0.05,
      strokeOpacity: 0.16,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FaIcon(
            FontAwesomeIcons.satellite,
            size: 26,
            color: Colors.white.withValues(alpha: 0.22),
          ),
          const Gap(10),
          Text(
            'Нет серверов',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.72),
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

enum _ServerCardMenuAction { toggleAutoExclusion, details }

class _ServerCard extends HookConsumerWidget {
  const _ServerCard({
    super.key,
    required this.server,
    required this.isSelected,
    required this.groupName,
    this.detailLines = const [],
    required this.groupTag,
    this.pingOverride,
    this.speedOverride,
    required this.hasSpeedResult,
    required this.isBenchmarking,
    this.selectionProgress,
    this.isAutoExcluded = false,
    this.onToggleAutoExclusion,
    this.onShowDetails,
    this.onSelect,
  });

  final OutboundInfo server;
  final bool isSelected;
  final String groupName;
  final List<String> detailLines;
  final String groupTag;
  final int? pingOverride;
  final int? speedOverride;
  final bool hasSpeedResult;
  final bool isBenchmarking;
  final AutoServerSelectionProgress? selectionProgress;
  final bool isAutoExcluded;
  final VoidCallback? onToggleAutoExclusion;
  final VoidCallback? onShowDetails;
  final VoidCallback? onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Pulsing glow controller — active only when this card is being benchmarked.
    final pulseCtrl = useAnimationController(
      duration: const Duration(milliseconds: 900),
    );
    final pulseValue = useAnimation(pulseCtrl);
    useEffect(() {
      if (isBenchmarking) {
        pulseCtrl.repeat(reverse: true);
      } else {
        pulseCtrl
          ..stop()
          ..value = 0;
      }
      return null;
    }, [isBenchmarking]);
    final name = _displayName(server);
    final cc = _extractCountryCode(name);
    final flag = cc != null ? _flagEmoji(cc) : '';
    final displayedName = cc != null ? _stripCountryPrefix(name) : name;
    final type = server.type.isNotEmpty ? server.type.toUpperCase() : 'PROXY';
    final ping = pingOverride ?? server.urlTestDelay;
    final typeColor = _typeColor(server.type);
    final pingColor = _pingColor(ping);
    final throughput = speedOverride;
    final speedColor = switch (throughput ?? -1) {
      < 1 => const Color(0xFFEF4444),
      < 256 * 1024 => const Color(0xFFF59E0B),
      < 1024 * 1024 => const Color(0xFF22C55E),
      _ => const Color(0xFF1EFFAC),
    };
    final hasActionsMenu =
        onShowDetails != null || onToggleAutoExclusion != null;

    return GestureDetector(
      onTap: onSelect,
      child: Container(
        margin: const EdgeInsets.only(right: 4, bottom: 8),
        decoration: isBenchmarking
            ? BoxDecoration(
                borderRadius: BorderRadius.circular(15),
                boxShadow: [
                  BoxShadow(
                    color: const Color(
                      0xFF1EFFAC,
                    ).withValues(alpha: 0.06 + pulseValue * 0.22),
                    blurRadius: 12 + pulseValue * 14,
                    spreadRadius: -2,
                  ),
                ],
              )
            : null,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 15, sigmaY: 15),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                color: isBenchmarking
                    ? Colors.white.withValues(alpha: 0.09)
                    : (isSelected
                          ? Colors.white.withValues(alpha: 0.08)
                          : Colors.white.withValues(alpha: 0.045)),
                border: Border.all(
                  color: isBenchmarking
                      ? const Color(0xFF1EFFAC).withValues(alpha: 0.55)
                      : Colors.white.withValues(
                          alpha: isSelected ? 0.14 : 0.08,
                        ),
                  width: isBenchmarking ? 1.3 : 0.7,
                ),
                boxShadow: (isSelected && !isBenchmarking)
                    ? [
                        BoxShadow(
                          color: const Color(
                            0xFF1EFFAC,
                          ).withValues(alpha: 0.08),
                          blurRadius: 18,
                          spreadRadius: -2,
                        ),
                      ]
                    : null,
              ),
              child: Stack(
                children: [
                  if (isSelected)
                    Positioned(
                      left: 0,
                      top: 0,
                      bottom: 0,
                      child: Container(
                        width: 2.5,
                        color: const Color(0xFF1EFFAC),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  if (flag.isNotEmpty) ...[
                                    Text(
                                      flag,
                                      style: const TextStyle(
                                        fontSize: 14,
                                        fontFamily: 'Emoji',
                                      ),
                                    ),
                                    const Gap(6),
                                  ],
                                  Expanded(
                                    child: Text(
                                      displayedName,
                                      style: TextStyle(
                                        color: isSelected
                                            ? Colors.white
                                            : Colors.white.withValues(
                                                alpha: 0.9,
                                              ),
                                        fontSize: 14,
                                        fontWeight: isSelected
                                            ? FontWeight.w700
                                            : FontWeight.w600,
                                        letterSpacing: 0.1,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                              if (groupName.isNotEmpty) ...[
                                const Gap(2),
                                Text(
                                  groupName,
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.44),
                                    fontSize: 12,
                                  ),
                                  maxLines: 3,
                                  overflow: TextOverflow.fade,
                                ),
                              ],
                              if (detailLines.isNotEmpty) ...[
                                const Gap(6),
                                for (
                                  var index = 0;
                                  index < detailLines.length;
                                  index += 1
                                ) ...[
                                  Text(
                                    detailLines[index],
                                    style: TextStyle(
                                      color: Colors.white.withValues(
                                        alpha: 0.58,
                                      ),
                                      fontSize: 11,
                                      fontWeight: FontWeight.w500,
                                      height: 1.25,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  if (index != detailLines.length - 1)
                                    const Gap(2),
                                ],
                              ],
                              if (isAutoExcluded) ...[
                                const Gap(6),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 3,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(
                                      0xFFEF4444,
                                    ).withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(999),
                                    border: Border.all(
                                      color: const Color(
                                        0xFFEF4444,
                                      ).withValues(alpha: 0.26),
                                      width: 0.7,
                                    ),
                                  ),
                                  child: Text(
                                    'Исключён из автовыбора',
                                    style: TextStyle(
                                      color: const Color(
                                        0xFFFF8A8A,
                                      ).withValues(alpha: 0.96),
                                      fontSize: 10,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: 0.25,
                                    ),
                                  ),
                                ),
                              ],
                              if (selectionProgress != null) ...[
                                const Gap(6),
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(999),
                                  child: SizedBox(
                                    height: 4,
                                    child: LinearProgressIndicator(
                                      value: selectionProgress!.value,
                                      backgroundColor: Colors.white.withValues(
                                        alpha: 0.08,
                                      ),
                                      valueColor:
                                          const AlwaysStoppedAnimation<Color>(
                                            Color(0xFF1EFFAC),
                                          ),
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        const Gap(8),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (isBenchmarking)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 3,
                                    ),
                                    decoration: BoxDecoration(
                                      color: const Color(
                                        0xFF1EFFAC,
                                      ).withValues(alpha: 0.14),
                                      borderRadius: BorderRadius.circular(999),
                                      border: Border.all(
                                        color: const Color(
                                          0xFF1EFFAC,
                                        ).withValues(alpha: 0.38),
                                        width: 0.7,
                                      ),
                                    ),
                                    child: const Text(
                                      'TEST',
                                      style: TextStyle(
                                        color: Color(0xFF1EFFAC),
                                        fontSize: 10,
                                        fontWeight: FontWeight.w800,
                                        letterSpacing: 0.5,
                                      ),
                                    ),
                                  )
                                else
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 7,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: typeColor.withValues(alpha: 0.13),
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(
                                        color: typeColor.withValues(
                                          alpha: 0.35,
                                        ),
                                        width: 0.7,
                                      ),
                                    ),
                                    child: Text(
                                      type,
                                      style: TextStyle(
                                        color: typeColor,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: 0.4,
                                      ),
                                    ),
                                  ),
                                if (hasActionsMenu) ...[
                                  const Gap(6),
                                  PopupMenuButton<_ServerCardMenuAction>(
                                    tooltip: 'Действия',
                                    color: const Color(0xCC09110D),
                                    elevation: 12,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                    onSelected: (action) {
                                      switch (action) {
                                        case _ServerCardMenuAction
                                            .toggleAutoExclusion:
                                          onToggleAutoExclusion?.call();
                                        case _ServerCardMenuAction.details:
                                          onShowDetails?.call();
                                      }
                                    },
                                    itemBuilder: (context) => [
                                      if (onToggleAutoExclusion != null)
                                        PopupMenuItem<_ServerCardMenuAction>(
                                          value: _ServerCardMenuAction
                                              .toggleAutoExclusion,
                                          child: Row(
                                            children: [
                                              Icon(
                                                isAutoExcluded
                                                    ? Icons
                                                          .playlist_add_check_circle_rounded
                                                    : Icons.block_rounded,
                                                size: 18,
                                                color: isAutoExcluded
                                                    ? const Color(0xFF1EFFAC)
                                                    : const Color(0xFFEF4444),
                                              ),
                                              const Gap(10),
                                              Text(
                                                isAutoExcluded
                                                    ? 'Вернуть в автовыбор'
                                                    : 'Исключить из автовыбора',
                                                style: TextStyle(
                                                  color: Colors.white
                                                      .withValues(alpha: 0.92),
                                                  fontWeight: FontWeight.w700,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      if (onShowDetails != null)
                                        PopupMenuItem<_ServerCardMenuAction>(
                                          value: _ServerCardMenuAction.details,
                                          child: Row(
                                            children: [
                                              Icon(
                                                Icons.tune_rounded,
                                                size: 18,
                                                color: Colors.white.withValues(
                                                  alpha: 0.72,
                                                ),
                                              ),
                                              const Gap(10),
                                              Text(
                                                'Параметры сервера',
                                                style: TextStyle(
                                                  color: Colors.white
                                                      .withValues(alpha: 0.92),
                                                  fontWeight: FontWeight.w700,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                    ],
                                    child: Container(
                                      width: 28,
                                      height: 28,
                                      decoration: BoxDecoration(
                                        color: Colors.white.withValues(
                                          alpha: 0.06,
                                        ),
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(
                                          color: isAutoExcluded
                                              ? const Color(
                                                  0xFFEF4444,
                                                ).withValues(alpha: 0.22)
                                              : Colors.white.withValues(
                                                  alpha: 0.08,
                                                ),
                                          width: 0.7,
                                        ),
                                      ),
                                      child: Icon(
                                        isAutoExcluded
                                            ? Icons.block_rounded
                                            : Icons.more_horiz_rounded,
                                        size: 15,
                                        color: isAutoExcluded
                                            ? const Color(
                                                0xFFFF8A8A,
                                              ).withValues(alpha: 0.96)
                                            : Colors.white.withValues(
                                                alpha: 0.72,
                                              ),
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            if (ping == -1) ...[
                              const Gap(5),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    width: 5,
                                    height: 5,
                                    decoration: const BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: Color(0xFFEF4444),
                                    ),
                                  ),
                                  const Gap(4),
                                  const Text(
                                    'NO',
                                    style: TextStyle(
                                      color: Color(0xFFEF4444),
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 0.5,
                                    ),
                                  ),
                                ],
                              ),
                            ] else if (ping > 0) ...[
                              const Gap(5),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    width: 5,
                                    height: 5,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: pingColor,
                                    ),
                                  ),
                                  const Gap(4),
                                  Text(
                                    '$ping ms',
                                    style: TextStyle(
                                      color: pingColor,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                            if (isBenchmarking && !hasSpeedResult) ...[
                              const Gap(4),
                              Text(
                                'benchmark…',
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.82),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                            if (hasSpeedResult) ...[
                              const Gap(4),
                              Text(
                                throughput != null && throughput > 0
                                    ? _formatRate(throughput)
                                    : 'FAIL',
                                style: TextStyle(
                                  color: throughput != null && throughput > 0
                                      ? speedColor
                                      : const Color(0xFFEF4444),
                                  fontSize: 13,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.2,
                                ),
                              ),
                              Text(
                                isBenchmarking
                                    ? 'live throughput'
                                    : 'throughput',
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.46),
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.4,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ServerSettingsDialog extends StatelessWidget {
  const _ServerSettingsDialog({required this.server, required this.outbound});

  final OutboundInfo server;
  final Map<String, dynamic>? outbound;

  @override
  Widget build(BuildContext context) {
    final prettyJson = outbound == null
        ? null
        : const JsonEncoder.withIndent('  ').convert(outbound);

    Widget infoRow(String title, String value) {
      if (value.isEmpty || value == '0') return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 88,
              child: Text(
                title,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.88),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const Gap(8),
            Expanded(
              child: SelectableText(
                value,
                style: TextStyle(color: Colors.white.withValues(alpha: 0.74)),
              ),
            ),
          ],
        ),
      );
    }

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: GlassPanel(
        borderRadius: 24,
        backgroundColor: const Color(0xFF08110D),
        opacity: 0.9,
        strokeOpacity: 0.22,
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
        child: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                EmojiFlagText(
                  _displayName(server),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const Gap(16),
                infoRow('Тип', server.type.toUpperCase()),
                infoRow('Host', server.host),
                infoRow('Port', server.port.toString()),
                infoRow('Tag', server.tag),
                if (prettyJson != null) ...[
                  Divider(
                    height: 24,
                    color: Colors.white.withValues(alpha: 0.08),
                  ),
                  const Text(
                    'Сырые настройки сервера',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const Gap(8),
                  GlassPanel(
                    borderRadius: 16,
                    backgroundColor: Colors.white,
                    opacity: 0.04,
                    strokeOpacity: 0.08,
                    padding: const EdgeInsets.all(12),
                    child: SelectableText(
                      prettyJson,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.78),
                      ),
                    ),
                  ),
                ] else
                  Text(
                    'Полная конфигурация сейчас недоступна, но базовые параметры сервера уже видны.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Colors.white.withValues(alpha: 0.7),
                    ),
                  ),
                const Gap(16),
                Row(
                  children: [
                    if (prettyJson != null)
                      Expanded(
                        child: _DialogActionButton(
                          label: 'Копировать JSON',
                          accent: true,
                          onTap: () => Clipboard.setData(
                            ClipboardData(text: prettyJson),
                          ),
                        ),
                      ),
                    if (prettyJson != null) const Gap(10),
                    Expanded(
                      child: _DialogActionButton(
                        label: 'Закрыть',
                        onTap: () => Navigator.of(context).pop(),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DialogActionButton extends StatelessWidget {
  const _DialogActionButton({
    required this.label,
    this.onTap,
    this.accent = false,
  });

  final String label;
  final VoidCallback? onTap;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final color = accent ? const Color(0xFF1EFFAC) : Colors.white;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 44,
        decoration: BoxDecoration(
          color: accent
              ? const Color(0xFF1EFFAC).withValues(alpha: 0.14)
              : Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withValues(alpha: 0.22), width: 0.8),
        ),
        child: Center(
          child: Text(
            label,
            style: TextStyle(color: color, fontWeight: FontWeight.w800),
          ),
        ),
      ),
    );
  }
}
