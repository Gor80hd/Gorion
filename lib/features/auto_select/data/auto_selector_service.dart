import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gorion_clean/features/auto_select/model/auto_select_state.dart';
import 'package:gorion_clean/features/auto_select/utils/auto_select_network_probe.dart';
import 'package:gorion_clean/features/auto_select/utils/auto_select_server_config.dart';
import 'package:gorion_clean/features/profiles/model/profile_models.dart';
import 'package:gorion_clean/features/runtime/data/clash_api_client.dart';
import 'package:gorion_clean/features/runtime/data/singbox_runtime_support.dart';
import 'package:gorion_clean/features/runtime/model/runtime_models.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

typedef AutoSelectDelayMeasurer =
    Future<Map<String, int>> Function({
      required RuntimeSession session,
      required String groupTag,
      required String testUrl,
    });

typedef AutoSelectSelectedTagLoader =
    Future<String?> Function({
      required RuntimeSession session,
      required String selectorTag,
    });

typedef AutoSelectProxySelector =
    Future<void> Function({
      required RuntimeSession session,
      required String selectorTag,
      required String serverTag,
    });

typedef AutoSelectLocalProxyProbe =
    Future<bool> Function({required int mixedPort, required Uri url});
typedef AutoSelectLocalProxyThroughput =
    Future<int> Function({required int mixedPort, required Uri url});
typedef AutoSelectDetachedServerProbe =
    Future<AutoSelectDetachedProbeResult> Function({
      required RuntimeSession session,
      required ServerEntry server,
      required String domainProbeUrl,
      required String ipProbeUrl,
      required String throughputProbeUrl,
    });

typedef AutoSelectPause = Future<void> Function(Duration duration);
typedef AutoSelectClock = DateTime Function();

class AutoSelectProbeResult {
  const AutoSelectProbeResult({
    required this.serverTag,
    required this.urlTestDelay,
    required this.domainProbeOk,
    required this.ipProbeOk,
    this.throughputBytesPerSecond = 0,
  });

  final String serverTag;
  final int? urlTestDelay;
  final bool domainProbeOk;
  final bool ipProbeOk;
  final int throughputBytesPerSecond;

  bool get fullyHealthy =>
      throughputBytesPerSecond > 0 && domainProbeOk && ipProbeOk;
  bool get hasEndToEndConnectivity => healthScore > 0;

  int get healthScore {
    if (throughputBytesPerSecond > 0 && domainProbeOk && ipProbeOk) {
      return 5;
    }
    if (throughputBytesPerSecond > 0 && (domainProbeOk || ipProbeOk)) {
      return 4;
    }
    if (throughputBytesPerSecond > 0) {
      return 3;
    }
    if (domainProbeOk && ipProbeOk) {
      return 2;
    }
    if (domainProbeOk || ipProbeOk) {
      return 1;
    }
    return 0;
  }
}

class AutoSelectDetachedProbeResult {
  const AutoSelectDetachedProbeResult({
    required this.domainProbeOk,
    required this.ipProbeOk,
    required this.throughputBytesPerSecond,
  });

  final bool domainProbeOk;
  final bool ipProbeOk;
  final int throughputBytesPerSecond;
}

class AutoSelectOutcome {
  const AutoSelectOutcome({
    required this.selectedServerTag,
    required this.delayByTag,
    required this.probes,
    required this.summary,
    required this.didSwitch,
    required this.hasReachableCandidate,
    this.previousServerTag,
  });

  final String selectedServerTag;
  final Map<String, int> delayByTag;
  final List<AutoSelectProbeResult> probes;
  final String summary;
  final bool didSwitch;
  final bool hasReachableCandidate;
  final String? previousServerTag;
}

class AutoSelectorService {
  AutoSelectorService({
    AutoSelectDelayMeasurer? measureGroupDelay,
    AutoSelectSelectedTagLoader? loadSelectedTag,
    AutoSelectProxySelector? selectProxy,
    AutoSelectLocalProxyProbe? probeViaLocalProxy,
    AutoSelectLocalProxyThroughput? measureThroughputViaLocalProxy,
    AutoSelectDetachedServerProbe? probeDetachedServer,
    AutoSelectPause? pause,
    AutoSelectClock? clock,
    this.maxInspectedCandidates = 6,
    this.maxContenderPool = 32,
    this.fastAcceptDelayMs = 250,
    this.betterDelayThresholdMs = 75,
    this.minimumUsableThroughput = 24 * 1024,
    this.throughputPreferenceWindowMs = 90,
    this.throughputProbeUrl = defaultAutoSelectThroughputProbeUrl,
    this.switchCooldown = const Duration(seconds: 8),
    this.failedProbeCooldown = const Duration(seconds: 45),
    this.proxySettleDelay = const Duration(milliseconds: 700),
    this.deepRefreshInterval = const Duration(hours: 3),
  }) : _measureGroupDelay = measureGroupDelay ?? _defaultMeasureGroupDelay,
       _loadSelectedTag = loadSelectedTag ?? _defaultLoadSelectedTag,
       _selectProxy = selectProxy ?? _defaultSelectProxy,
       _probeViaLocalProxy = probeViaLocalProxy ?? _defaultProbeViaLocalProxy,
       _measureThroughputViaLocalProxy =
           measureThroughputViaLocalProxy ??
           _defaultMeasureThroughputViaLocalProxy,
       _pause = pause ?? _defaultPause,
       _clock = clock ?? DateTime.now {
    _probeDetachedServer = probeDetachedServer ?? _defaultProbeDetachedServer;
  }

  final AutoSelectDelayMeasurer _measureGroupDelay;
  final AutoSelectSelectedTagLoader _loadSelectedTag;
  final AutoSelectProxySelector _selectProxy;
  final AutoSelectLocalProxyProbe _probeViaLocalProxy;
  final AutoSelectLocalProxyThroughput _measureThroughputViaLocalProxy;
  late final AutoSelectDetachedServerProbe _probeDetachedServer;
  final AutoSelectPause _pause;
  final AutoSelectClock _clock;
  final int maxInspectedCandidates;
  // Maximum number of servers that enter the rotation pool for maintenance
  // contender checks.  Servers are ranked by URLTest delay first (best to
  // worst), so the pool naturally contains the most promising candidates.  A
  // bounded pool keeps rotation fast: with the default of 32 servers and a
  // batch size of 5, a full rotation takes ≈7 cycles (≈7 minutes).
  final int maxContenderPool;
  final int fastAcceptDelayMs;
  final int betterDelayThresholdMs;
  final int minimumUsableThroughput;
  final int throughputPreferenceWindowMs;
  final String throughputProbeUrl;
  final Duration switchCooldown;
  final Duration failedProbeCooldown;
  final Duration proxySettleDelay;
  // Interval at which all failed-probe cooldowns and the rotation index are
  // reset for a profile.  This gives previously-dead servers a fresh chance
  // (they may have recovered) and lets the pool discover new good candidates.
  final Duration deepRefreshInterval;
  final Map<String, DateTime> _failedProbeCooldownByServer =
      <String, DateTime>{};
  final Map<String, DateTime> _lastSwitchAtByProfile = <String, DateTime>{};
  final Map<String, DateTime> _lastDeepRefreshAtByProfile =
      <String, DateTime>{};

  // Caches the last time the active server passed a full live-proxy health
  // check.  Valid for _currentServeSuccessCacheTtl so the probe is not
  // repeated on every 60-second maintenance tick for a healthy setup.
  static const _currentServerSuccessCacheTtl = Duration(minutes: 5);
  final Map<String, DateTime> _currentServerSuccessCacheByServer =
      <String, DateTime>{};

  // Tracks where in the eligible contender pool each profile left off so
  // successive maintenance cycles rotate through all candidate servers rather
  // than re-probing the same first-N servers every time (especially important
  // when URLTest is unavailable and sorting falls back to fixed list order).
  final Map<String, int> _contenderStartIndexByProfile = <String, int>{};

  Future<AutoSelectOutcome> selectBestServer({
    required RuntimeSession session,
    required List<ServerEntry> servers,
    required String domainProbeUrl,
    String ipProbeUrl = 'http://1.1.1.1',
    AutoSelectProgressReporter? onProgress,
  }) async {
    if (servers.isEmpty) {
      throw const FormatException('There are no servers to auto-select from.');
    }

    final inspectedCandidates = servers.length < maxInspectedCandidates
        ? servers.length
        : maxInspectedCandidates;
    final totalSteps = inspectedCandidates + 2;
    _reportProgress(
      onProgress,
      'Refreshing URLTest delays for ${servers.length} candidate servers.',
      completedSteps: 1,
      totalSteps: totalSteps,
    );

    final delayByTag = await _refreshDelaysOrFallback(
      session: session,
      testUrl: domainProbeUrl,
      onProgress: onProgress,
      totalSteps: totalSteps,
    );

    final currentTag = await _loadSelectedTagOrFallback(
      session: session,
      onProgress: onProgress,
      completedSteps: 1,
      totalSteps: totalSteps,
    );
    final candidates = _sortCandidatesByDelay(servers, delayByTag);

    return _forceBestSelection(
      session: session,
      candidates: candidates,
      delayByTag: delayByTag,
      currentTag: currentTag,
      domainProbeUrl: domainProbeUrl,
      ipProbeUrl: ipProbeUrl,
      onProgress: onProgress,
      totalSteps: totalSteps,
    );
  }

  Future<AutoSelectOutcome> maintainBestServer({
    required RuntimeSession session,
    required List<ServerEntry> servers,
    required String domainProbeUrl,
    String ipProbeUrl = 'http://1.1.1.1',
    bool allowSwitchDuringCooldown = false,
    AutoSelectProgressReporter? onProgress,
  }) async {
    if (servers.isEmpty) {
      throw const FormatException('There are no servers to auto-select from.');
    }

    final inspectedCandidates = servers.length < maxInspectedCandidates
        ? servers.length
        : maxInspectedCandidates;
    final totalSteps = inspectedCandidates + 2;
    _reportProgress(
      onProgress,
      'Refreshing URLTest delays and checking the current server.',
      completedSteps: 1,
      totalSteps: totalSteps,
    );

    final delayByTag = await _refreshDelaysOrFallback(
      session: session,
      testUrl: domainProbeUrl,
      onProgress: onProgress,
      totalSteps: totalSteps,
    );
    final currentTag = await _loadSelectedTagOrFallback(
      session: session,
      onProgress: onProgress,
      completedSteps: 1,
      totalSteps: totalSteps,
    );
    // Every deepRefreshInterval, clear failed-probe cooldowns and reset the
    // rotation index for this profile.  Servers that were dead before may
    // have recovered, and previously-untried servers get a fair chance.
    _maybeDeepRefresh(session.profileId, onProgress: onProgress);

    final candidates = _sortCandidatesByDelay(servers, delayByTag);
    final currentServer = _findServerByTag(candidates, currentTag);
    if (currentServer == null) {
      return _forceBestSelection(
        session: session,
        candidates: candidates,
        delayByTag: delayByTag,
        currentTag: currentTag,
        domainProbeUrl: domainProbeUrl,
        ipProbeUrl: ipProbeUrl,
        onProgress: onProgress,
        totalSteps: totalSteps,
      );
    }

    final probes = <AutoSelectProbeResult>[];
    var completedSteps = 1;

    // Skip the expensive live-proxy health check when the current server
    // passed recently (within _currentServerSuccessCacheTtl = 5 minutes) and
    // the caller is not forcing a switch (allowSwitchDuringCooldown = true is
    // only set right after connect or when the user manually triggers a check).
    final useCachedCurrentProbe =
        !allowSwitchDuringCooldown &&
        _isCurrentServerSuccessCached(session.profileId, currentServer.tag);

    final AutoSelectProbeResult currentProbe;
    if (useCachedCurrentProbe) {
      _reportProgress(
        onProgress,
        'Current server ${currentServer.tag} passed a live-proxy health check recently — skipping re-probe.',
        completedSteps: completedSteps,
        totalSteps: totalSteps,
      );
      // Synthesise a passing result using the freshly measured URLTest delay.
      currentProbe = AutoSelectProbeResult(
        serverTag: currentServer.tag,
        urlTestDelay: delayByTag[currentServer.tag],
        domainProbeOk: true,
        ipProbeOk: true,
        throughputBytesPerSecond: minimumUsableThroughput,
      );
    } else {
      _reportProgress(
        onProgress,
        'Probing current server ${currentServer.tag} through the local proxy.',
        completedSteps: completedSteps,
        totalSteps: totalSteps,
      );
      currentProbe = await _probeServer(
        session: session,
        server: currentServer,
        delayByTag: delayByTag,
        domainProbeUrl: domainProbeUrl,
        ipProbeUrl: ipProbeUrl,
        ensureSelected: false,
      );
      if (currentProbe.hasEndToEndConnectivity) {
        _markCurrentServerSucceeded(session.profileId, currentServer.tag);
      } else {
        _invalidateCurrentServerSuccessCache(
          session.profileId,
          currentServer.tag,
        );
      }
    }

    probes.add(currentProbe);
    completedSteps += 1;
    _reportProgress(
      onProgress,
      useCachedCurrentProbe
          ? 'Current server ${currentServer.tag} health assumed OK from recent cache.'
          : _describeProbeResult(currentProbe, kind: 'check current'),
      completedSteps: completedSteps,
      totalSteps: totalSteps,
    );

    if (!currentProbe.hasEndToEndConnectivity) {
      // Include servers that are cooling down at the end of the recovery list
      // (like Gorion) rather than excluding them entirely.  If all alternatives
      // have failed recently they still get one more attempt before giving up.
      final otherCandidates = candidates
          .where((server) => server.tag != currentServer.tag)
          .toList(growable: false);
      final readyCandidates = otherCandidates
          .where(
            (server) =>
                !_isFailedProbeCoolingDown(session.profileId, server.tag),
          )
          .toList(growable: false);
      final coolingCandidates = otherCandidates
          .where(
            (server) =>
                _isFailedProbeCoolingDown(session.profileId, server.tag),
          )
          .toList(growable: false);
      final recoveryCandidates = [
        ...readyCandidates,
        ...coolingCandidates,
      ].take(maxInspectedCandidates - 1).toList(growable: false);

      AutoSelectProbeResult? replacement;
      for (var index = 0; index < recoveryCandidates.length; index += 1) {
        final candidate = recoveryCandidates[index];
        _reportProgress(
          onProgress,
          'Current server failed the probe. Checking replacement ${candidate.tag} (${index + 1}/${recoveryCandidates.length}).',
          completedSteps: completedSteps,
          totalSteps: totalSteps,
        );
        final probe = await _probeServerDetached(
          session: session,
          server: candidate,
          delayByTag: delayByTag,
          domainProbeUrl: domainProbeUrl,
          ipProbeUrl: ipProbeUrl,
        );
        probes.add(probe);
        completedSteps += 1;
        _reportProgress(
          onProgress,
          _describeProbeResult(probe, kind: 'check recovery'),
          completedSteps: completedSteps,
          totalSteps: totalSteps,
        );
        if (probe.hasEndToEndConnectivity) {
          replacement = probe;
          break;
        }
      }

      final ranked = _rankProbes(probes);
      final didSwitch =
          replacement != null && replacement.serverTag != currentServer.tag;
      if (didSwitch) {
        await _selectProxy(
          session: session,
          selectorTag: session.manualSelectorTag,
          serverTag: replacement.serverTag,
        );
        _recordSwitch(session.profileId);
      }

      final summary = didSwitch
          ? 'Auto-selector recovered from ${currentServer.tag} to ${replacement.serverTag} after the current server failed the end-to-end proxy probe.'
          : 'Current server ${currentServer.tag} failed the latest end-to-end proxy probe, and no reachable replacement was confirmed.';

      _reportProgress(
        onProgress,
        summary,
        completedSteps: totalSteps,
        totalSteps: totalSteps,
      );

      return AutoSelectOutcome(
        selectedServerTag: replacement?.serverTag ?? currentServer.tag,
        previousServerTag: currentServer.tag,
        delayByTag: delayByTag,
        probes: ranked,
        summary: summary,
        didSwitch: didSwitch,
        hasReachableCandidate: replacement != null,
      );
    }

    if (!allowSwitchDuringCooldown && _isSwitchCoolingDown(session.profileId)) {
      _reportProgress(
        onProgress,
        'Keeping ${currentServer.tag} because the automatic switch cooldown is still active.',
        completedSteps: totalSteps,
        totalSteps: totalSteps,
      );
      return AutoSelectOutcome(
        selectedServerTag: currentServer.tag,
        previousServerTag: currentServer.tag,
        delayByTag: delayByTag,
        probes: _rankProbes(probes),
        summary:
            'Current server ${currentServer.tag} stayed selected because the last automatic switch was too recent.',
        didSwitch: false,
        hasReachableCandidate: true,
      );
    }

    // Build the eligible contender pool (excludes current server and any
    // server still cooling down after a recent failure), then cap it to
    // maxContenderPool.  Candidates are already sorted by URLTest delay so
    // the cap keeps the most promising servers in the pool.  When URLTest is
    // unavailable the order falls back to profile list order, which is still
    // better than an unbounded pool of potentially thousands of dead servers
    // (1000 servers / batch-5 = 200 cycles × 60s = 3 hours per rotation).
    final contenderPool =
        candidates
            .where((s) => s.tag != currentServer.tag)
            .where(
              (s) => !_isFailedProbeCoolingDown(session.profileId, s.tag),
            )
            .take(maxContenderPool)
            .toList(growable: false);
    final batchSize = maxInspectedCandidates - 1;
    final startIdx = _getAndAdvanceContenderIndex(
      session.profileId,
      contenderPool.length,
      batchSize,
    );
    final contenderCandidates = <ServerEntry>[];
    for (
      var i = 0;
      i < contenderPool.length && contenderCandidates.length < batchSize;
      i += 1
    ) {
      contenderCandidates.add(
        contenderPool[(startIdx + i) % contenderPool.length],
      );
    }

    final contenderProbes = <AutoSelectProbeResult>[];
    for (var index = 0; index < contenderCandidates.length; index += 1) {
      final candidate = contenderCandidates[index];
      _reportProgress(
        onProgress,
        'Probing contender ${candidate.tag} (${index + 1}/${contenderCandidates.length}).',
        completedSteps: completedSteps,
        totalSteps: totalSteps,
      );

      final probe = await _probeServerDetached(
        session: session,
        server: candidate,
        delayByTag: delayByTag,
        domainProbeUrl: domainProbeUrl,
        ipProbeUrl: ipProbeUrl,
      );
      probes.add(probe);
      contenderProbes.add(probe);
      completedSteps += 1;
      _reportProgress(
        onProgress,
        _describeProbeResult(probe, kind: 'check contender'),
        completedSteps: completedSteps,
        totalSteps: totalSteps,
      );
    }

    final ranked = _rankProbes(probes);
    final betterCandidates =
        contenderProbes
            .where((probe) => _beatsCurrentSelection(currentProbe, probe))
            .toList()
          ..sort(_compareProbesByPriority);

    final winner = betterCandidates.isEmpty ? null : betterCandidates.first;
    final hasUrlTestDelays = delayByTag.isNotEmpty;
    final didSwitch = winner != null && winner.serverTag != currentServer.tag;
    if (didSwitch) {
      await _selectProxy(
        session: session,
        selectorTag: session.manualSelectorTag,
        serverTag: winner.serverTag,
      );
      _recordSwitch(session.profileId);
    }

    final summary = didSwitch
        ? hasUrlTestDelays
              ? 'Auto-selector switched from ${currentServer.tag} to ${winner.serverTag} after confirming better end-to-end health and latency.'
              : 'Auto-selector switched from ${currentServer.tag} to ${winner.serverTag} after confirming better end-to-end health.'
        : hasUrlTestDelays
        ? 'Current server ${currentServer.tag} stayed selected after the latest URLTest and proxy probe check.'
        : 'Current server ${currentServer.tag} stayed selected after the latest proxy probe check.';

    _reportProgress(
      onProgress,
      summary,
      completedSteps: totalSteps,
      totalSteps: totalSteps,
    );

    return AutoSelectOutcome(
      selectedServerTag: winner?.serverTag ?? currentServer.tag,
      previousServerTag: currentServer.tag,
      delayByTag: delayByTag,
      probes: ranked,
      summary: summary,
      didSwitch: didSwitch,
      hasReachableCandidate: true,
    );
  }

  void recordExternalSelection({required String profileId}) {
    _recordSwitch(profileId);
  }

  void resetProfileState(String profileId) {
    _lastSwitchAtByProfile.remove(profileId);
    _failedProbeCooldownByServer.removeWhere(
      (key, _) => key.startsWith('$profileId::'),
    );
    _currentServerSuccessCacheByServer.removeWhere(
      (key, _) => key.startsWith('$profileId::'),
    );
    _contenderStartIndexByProfile.remove(profileId);
    _lastDeepRefreshAtByProfile.remove(profileId);
  }

  Future<AutoSelectOutcome> _forceBestSelection({
    required RuntimeSession session,
    required List<ServerEntry> candidates,
    required Map<String, int> delayByTag,
    required String? currentTag,
    required String domainProbeUrl,
    required String ipProbeUrl,
    required AutoSelectProgressReporter? onProgress,
    required int totalSteps,
  }) async {
    final probes = <AutoSelectProbeResult>[];
    final inspected = candidates
        .take(maxInspectedCandidates)
        .toList(growable: false);
    var completedSteps = 1;
    for (var index = 0; index < inspected.length; index += 1) {
      final server = inspected[index];
      _reportProgress(
        onProgress,
        'Probing candidate ${server.tag} (${index + 1}/${inspected.length}) through the local proxy.',
        completedSteps: completedSteps,
        totalSteps: totalSteps,
      );
      final probe = await _probeServerDetached(
        session: session,
        server: server,
        delayByTag: delayByTag,
        domainProbeUrl: domainProbeUrl,
        ipProbeUrl: ipProbeUrl,
      );
      probes.add(probe);
      completedSteps += 1;
      _reportProgress(
        onProgress,
        _describeProbeResult(probe, kind: 'check candidate'),
        completedSteps: completedSteps,
        totalSteps: totalSteps,
      );

      if (probe.fullyHealthy &&
          (probe.urlTestDelay ?? 999999) <= fastAcceptDelayMs) {
        break;
      }
    }

    if (probes.isEmpty) {
      throw const FormatException(
        'The auto-selector could not probe any server candidates.',
      );
    }

    final ranked = _rankProbes(probes);
    final winner = ranked.first;
    if (!winner.hasEndToEndConnectivity) {
      throw const FormatException(
        'No candidate passed an end-to-end proxy probe. TCP-only success is ignored by design.',
      );
    }

    final didSwitch = currentTag != winner.serverTag;
    if (didSwitch) {
      await _selectProxy(
        session: session,
        selectorTag: session.manualSelectorTag,
        serverTag: winner.serverTag,
      );
      _recordSwitch(session.profileId);
    }

    final summary = winner.fullyHealthy
        ? delayByTag.isNotEmpty
              ? 'Auto-selector chose ${winner.serverTag} using URLTest plus IP and domain probes through the local proxy.'
              : 'Auto-selector chose ${winner.serverTag} using IP and domain probes through the local proxy after URLTest refresh was unavailable.'
        : winner.domainProbeOk
        ? 'Auto-selector chose ${winner.serverTag}. Domain traffic worked, but the IP-only probe stayed partial.'
        : 'Auto-selector chose ${winner.serverTag} with partial confidence. IP-only probe worked, domain probe did not.';

    _reportProgress(
      onProgress,
      summary,
      completedSteps: totalSteps,
      totalSteps: totalSteps,
    );

    return AutoSelectOutcome(
      selectedServerTag: winner.serverTag,
      previousServerTag: currentTag,
      delayByTag: delayByTag,
      probes: ranked,
      summary: summary,
      didSwitch: didSwitch,
      hasReachableCandidate: true,
    );
  }

  Future<AutoSelectProbeResult> _probeServer({
    required RuntimeSession session,
    required ServerEntry server,
    required Map<String, int> delayByTag,
    required String domainProbeUrl,
    required String ipProbeUrl,
    bool ensureSelected = true,
  }) async {
    if (ensureSelected) {
      await _selectProxy(
        session: session,
        selectorTag: session.manualSelectorTag,
        serverTag: server.tag,
      );
      await _pause(proxySettleDelay);
    }

    final domainProbeOk = await _probeViaLocalProxy(
      mixedPort: session.mixedPort,
      url: Uri.parse(domainProbeUrl),
    );
    final ipProbeOk = await _probeViaLocalProxy(
      mixedPort: session.mixedPort,
      url: Uri.parse(ipProbeUrl),
    );
    final measuredThroughput = await _measureThroughputViaLocalProxy(
      mixedPort: session.mixedPort,
      url: Uri.parse(throughputProbeUrl),
    );
    final usableThroughput = measuredThroughput >= minimumUsableThroughput
        ? measuredThroughput
        : 0;

    final probe = AutoSelectProbeResult(
      serverTag: server.tag,
      urlTestDelay: delayByTag[server.tag],
      domainProbeOk: domainProbeOk,
      ipProbeOk: ipProbeOk,
      throughputBytesPerSecond: usableThroughput,
    );
    _rememberProbeResult(session.profileId, probe);
    return probe;
  }

  Future<AutoSelectProbeResult> _probeServerDetached({
    required RuntimeSession session,
    required ServerEntry server,
    required Map<String, int> delayByTag,
    required String domainProbeUrl,
    required String ipProbeUrl,
  }) async {
    try {
      final detachedProbe = await _probeDetachedServer(
        session: session,
        server: server,
        domainProbeUrl: domainProbeUrl,
        ipProbeUrl: ipProbeUrl,
        throughputProbeUrl: throughputProbeUrl,
      );
      final usableThroughput =
          detachedProbe.throughputBytesPerSecond >= minimumUsableThroughput
          ? detachedProbe.throughputBytesPerSecond
          : 0;
      final probe = AutoSelectProbeResult(
        serverTag: server.tag,
        urlTestDelay: delayByTag[server.tag],
        domainProbeOk: detachedProbe.domainProbeOk,
        ipProbeOk: detachedProbe.ipProbeOk,
        throughputBytesPerSecond: usableThroughput,
      );
      _rememberProbeResult(session.profileId, probe);
      return probe;
    } on Object {
      final probe = AutoSelectProbeResult(
        serverTag: server.tag,
        urlTestDelay: delayByTag[server.tag],
        domainProbeOk: false,
        ipProbeOk: false,
        throughputBytesPerSecond: 0,
      );
      _rememberProbeResult(session.profileId, probe);
      return probe;
    }
  }

  Future<Map<String, int>> _refreshDelaysOrFallback({
    required RuntimeSession session,
    required String testUrl,
    required AutoSelectProgressReporter? onProgress,
    required int totalSteps,
  }) async {
    try {
      return await _measureGroupDelay(
        session: session,
        groupTag: session.autoGroupTag,
        testUrl: testUrl,
      );
    } on Object {
      _reportProgress(
        onProgress,
        'URLTest refresh failed, continuing with end-to-end proxy probes only.',
        completedSteps: 1,
        totalSteps: totalSteps,
      );
      return const <String, int>{};
    }
  }

  Future<String?> _loadSelectedTagOrFallback({
    required RuntimeSession session,
    required AutoSelectProgressReporter? onProgress,
    required int completedSteps,
    required int totalSteps,
  }) async {
    try {
      return await _loadSelectedTag(
        session: session,
        selectorTag: session.manualSelectorTag,
      );
    } on Object {
      _reportProgress(
        onProgress,
        'Could not read the current selected server from Clash API, probing candidates directly.',
        completedSteps: completedSteps,
        totalSteps: totalSteps,
      );
      return null;
    }
  }

  List<ServerEntry> _sortCandidatesByDelay(
    List<ServerEntry> servers,
    Map<String, int> delayByTag,
  ) {
    final originalIndexByTag = <String, int>{
      for (var index = 0; index < servers.length; index += 1)
        servers[index].tag: index,
    };
    final candidates = [...servers];
    candidates.sort((left, right) {
      final leftDelay = delayByTag[left.tag];
      final rightDelay = delayByTag[right.tag];
      if (leftDelay == null && rightDelay == null) {
        return originalIndexByTag[left.tag]!.compareTo(
          originalIndexByTag[right.tag]!,
        );
      }
      if (leftDelay == null) {
        return 1;
      }
      if (rightDelay == null) {
        return -1;
      }

      final delayCompare = leftDelay.compareTo(rightDelay);
      if (delayCompare != 0) {
        return delayCompare;
      }

      return originalIndexByTag[left.tag]!.compareTo(
        originalIndexByTag[right.tag]!,
      );
    });
    return candidates;
  }

  ServerEntry? _findServerByTag(List<ServerEntry> servers, String? tag) {
    if (tag == null || tag.isEmpty) {
      return null;
    }
    for (final server in servers) {
      if (server.tag == tag) {
        return server;
      }
    }
    return null;
  }

  List<AutoSelectProbeResult> _rankProbes(List<AutoSelectProbeResult> probes) {
    final ranked = [...probes];
    ranked.sort(_compareProbesByPriority);
    return ranked;
  }

  void _reportProgress(
    AutoSelectProgressReporter? onProgress,
    String message, {
    int? completedSteps,
    int? totalSteps,
  }) {
    onProgress?.call(
      AutoSelectProgressEvent(
        message: message,
        completedSteps: completedSteps,
        totalSteps: totalSteps,
      ),
    );
  }

  String _describeProbeResult(
    AutoSelectProbeResult probe, {
    String kind = 'check',
  }) {
    final delayLabel = probe.urlTestDelay == null
        ? 'n/a'
        : '${probe.urlTestDelay}ms';
    final throughputKbps = (probe.throughputBytesPerSecond / 1024)
        .toStringAsFixed(0);
    return '$kind ${probe.serverTag}: $delayLabel, ${probe.domainProbeOk ? 'domain OK' : 'domain failed'}, ${probe.ipProbeOk ? 'IP OK' : 'IP failed'}, $throughputKbps KB/s.';
  }

  int _compareProbesByPriority(
    AutoSelectProbeResult left,
    AutoSelectProbeResult right,
  ) {
    final scoreCompare = right.healthScore.compareTo(left.healthScore);
    if (scoreCompare != 0) {
      return scoreCompare;
    }

    final leftDelay = left.urlTestDelay ?? 1 << 30;
    final rightDelay = right.urlTestDelay ?? 1 << 30;
    final delayGap = (leftDelay - rightDelay).abs();
    if (delayGap <= throughputPreferenceWindowMs) {
      final throughputCompare = right.throughputBytesPerSecond.compareTo(
        left.throughputBytesPerSecond,
      );
      if (throughputCompare != 0) {
        return throughputCompare;
      }
    }
    return leftDelay.compareTo(rightDelay);
  }

  bool _beatsCurrentSelection(
    AutoSelectProbeResult current,
    AutoSelectProbeResult contender,
  ) {
    if (!contender.hasEndToEndConnectivity) {
      return false;
    }
    if (contender.healthScore > current.healthScore) {
      return true;
    }
    if (contender.healthScore < current.healthScore) {
      return false;
    }

    final contenderThroughput = contender.throughputBytesPerSecond;
    final currentThroughput = current.throughputBytesPerSecond;
    if (contenderThroughput > currentThroughput) {
      final currentDelay = current.urlTestDelay ?? 1 << 30;
      final contenderDelay = contender.urlTestDelay ?? 1 << 30;
      final delayGap = currentDelay - contenderDelay;
      if (delayGap >= betterDelayThresholdMs ||
          delayGap.abs() <= throughputPreferenceWindowMs) {
        return true;
      }
    }

    final currentDelay = current.urlTestDelay ?? 1 << 30;
    final contenderDelay = contender.urlTestDelay ?? 1 << 30;
    return currentDelay - contenderDelay >= betterDelayThresholdMs;
  }

  // Clears failed-probe cooldowns and resets the rotation index for the given
  // profile if deepRefreshInterval has elapsed since the last deep refresh.
  void _maybeDeepRefresh(
    String profileId, {
    AutoSelectProgressReporter? onProgress,
  }) {
    final last = _lastDeepRefreshAtByProfile[profileId];
    if (last != null && _clock().difference(last) < deepRefreshInterval) {
      return;
    }
    _failedProbeCooldownByServer.removeWhere(
      (key, _) => key.startsWith('$profileId::'),
    );
    _contenderStartIndexByProfile.remove(profileId);
    _lastDeepRefreshAtByProfile[profileId] = _clock();
    _reportProgress(
      onProgress,
      'DEEP-REFRESH: Periodic pool reset — all server cooldowns cleared, rotation restarted.',
    );
  }

  // Returns the index within the pool to start picking contenders from, and
  // advances the stored index by batchSize so the next call starts where this
  // one left off.  This distributes probing across all candidate servers over
  // successive maintenance cycles.
  int _getAndAdvanceContenderIndex(
    String profileId,
    int poolSize,
    int batchSize,
  ) {
    if (poolSize == 0) return 0;
    final current = _contenderStartIndexByProfile[profileId] ?? 0;
    final startIdx = current % poolSize;
    _contenderStartIndexByProfile[profileId] = (current + batchSize) % poolSize;
    return startIdx;
  }

  bool _isSwitchCoolingDown(String profileId) {
    final switchedAt = _lastSwitchAtByProfile[profileId];
    if (switchedAt == null) {
      return false;
    }

    final coolingDown = _clock().difference(switchedAt) < switchCooldown;
    if (!coolingDown) {
      _lastSwitchAtByProfile.remove(profileId);
    }
    return coolingDown;
  }

  bool _isFailedProbeCoolingDown(String profileId, String serverTag) {
    final key = '$profileId::$serverTag';
    final cooldownUntil = _failedProbeCooldownByServer[key];
    if (cooldownUntil == null) {
      return false;
    }

    if (_clock().isAfter(cooldownUntil)) {
      _failedProbeCooldownByServer.remove(key);
      return false;
    }
    return true;
  }

  void _rememberProbeResult(String profileId, AutoSelectProbeResult probe) {
    final key = '$profileId::${probe.serverTag}';
    if (probe.hasEndToEndConnectivity) {
      _failedProbeCooldownByServer.remove(key);
      return;
    }

    _failedProbeCooldownByServer[key] = _clock().add(failedProbeCooldown);
    // Also clear the live-proxy success cache so the next maintenance tick
    // re-probes this server rather than trusting a stale healthy result.
    _currentServerSuccessCacheByServer.remove(key);
  }

  void _recordSwitch(String profileId) {
    _lastSwitchAtByProfile[profileId] = _clock();
  }

  bool _isCurrentServerSuccessCached(String profileId, String serverTag) {
    final key = '$profileId::$serverTag';
    final until = _currentServerSuccessCacheByServer[key];
    if (until == null) return false;
    if (_clock().isAfter(until)) {
      _currentServerSuccessCacheByServer.remove(key);
      return false;
    }
    return true;
  }

  void _markCurrentServerSucceeded(String profileId, String serverTag) {
    final key = '$profileId::$serverTag';
    _currentServerSuccessCacheByServer[key] = _clock().add(
      _currentServerSuccessCacheTtl,
    );
  }

  void _invalidateCurrentServerSuccessCache(
    String profileId,
    String serverTag,
  ) {
    _currentServerSuccessCacheByServer.remove('$profileId::$serverTag');
  }

  Future<AutoSelectDetachedProbeResult> _defaultProbeDetachedServer({
    required RuntimeSession session,
    required ServerEntry server,
    required String domainProbeUrl,
    required String ipProbeUrl,
    required String throughputProbeUrl,
  }) async {
    final templateConfig = await File(session.configPath).readAsString();
    return _DetachedAutoSelectProbe.run(
      profileId: session.profileId,
      templateConfig: templateConfig,
      serverTag: server.tag,
      domainProbeUrl: domainProbeUrl,
      ipProbeUrl: ipProbeUrl,
      throughputProbeUrl: throughputProbeUrl,
    );
  }

  static Future<Map<String, int>> _defaultMeasureGroupDelay({
    required RuntimeSession session,
    required String groupTag,
    required String testUrl,
  }) async {
    final clashClient = ClashApiClient.fromSession(session);
    return clashClient.measureGroupDelay(groupTag: groupTag, testUrl: testUrl);
  }

  static Future<String?> _defaultLoadSelectedTag({
    required RuntimeSession session,
    required String selectorTag,
  }) async {
    final clashClient = ClashApiClient.fromSession(session);
    final snapshot = await clashClient.fetchSnapshot(selectorTag: selectorTag);
    return snapshot.selectedTag;
  }

  static Future<void> _defaultSelectProxy({
    required RuntimeSession session,
    required String selectorTag,
    required String serverTag,
  }) async {
    final clashClient = ClashApiClient.fromSession(session);
    await clashClient.selectProxy(
      selectorTag: selectorTag,
      serverTag: serverTag,
    );
  }

  static Future<void> _defaultPause(Duration duration) {
    return Future<void>.delayed(duration);
  }

  static Future<bool> _defaultProbeViaLocalProxy({
    required int mixedPort,
    required Uri url,
  }) async {
    return probeHttpViaLocalProxy(mixedPort: mixedPort, url: url);
  }

  static Future<int> _defaultMeasureThroughputViaLocalProxy({
    required int mixedPort,
    required Uri url,
  }) async {
    return measureDownloadThroughputViaLocalProxy(
      mixedPort: mixedPort,
      url: url,
      timeout: const Duration(seconds: 2),
    );
  }
}

class _DetachedAutoSelectProbe {
  static const _probeTimeout = Duration(seconds: 14);
  static const _startupTimeout = Duration(seconds: 8);
  static const _httpProbeTimeout = Duration(seconds: 3);
  static const _throughputTimeout = Duration(seconds: 2);

  static Future<AutoSelectDetachedProbeResult> run({
    required String profileId,
    required String templateConfig,
    required String serverTag,
    required String domainProbeUrl,
    required String ipProbeUrl,
    required String throughputProbeUrl,
  }) async {
    // Extract only the outbound for this server so the probe config is minimal:
    // no DNS rules, no routing complexity, no Clash API — just the server
    // outbound behind a mixed inbound.  This starts much faster than the full
    // profile config and fails fast when the server is dead.
    final outbound = extractAutoSelectConfigOutbound(templateConfig, serverTag);
    if (outbound == null) {
      return const AutoSelectDetachedProbeResult(
        domainProbeOk: false,
        ipProbeOk: false,
        throughputBytesPerSecond: 0,
      );
    }

    final runtimeDir = await ensureGorionRuntimeDirectory(
      subdirectory: p.join('maintain', const Uuid().v4()),
    );
    Process? process;
    StreamSubscription<String>? stdoutSubscription;
    StreamSubscription<String>? stderrSubscription;
    int? startupExitCode;

    try {
      final binaryFile = await prepareSingboxBinary(runtimeDir);
      final mixedPort = await findFreePort();
      final configJson = buildMinimalProbeConfig(
        outbound: outbound,
        mixedPort: mixedPort,
      );

      final configFile = File(p.join(runtimeDir.path, 'maintain-config.json'));
      await configFile.writeAsString(configJson);

      process = await Process.start(
        binaryFile.path,
        ['run', '-c', configFile.path],
        workingDirectory: runtimeDir.path,
        mode: ProcessStartMode.normal,
      );
      stdoutSubscription = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((_) {});
      stderrSubscription = process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((_) {});
      process.exitCode.then((code) {
        startupExitCode = code;
      });

      return await (() async {
        // Wait for the local proxy port to accept connections rather than
        // polling the Clash API — the minimal config has no Clash API at all.
        final portReady = await waitForLocalPortReady(
          mixedPort,
          timeout: _startupTimeout,
          abortReason: () {
            final exitCode = startupExitCode;
            if (exitCode == null) return null;
            return 'Detached post-connect sing-box probe exited early with code $exitCode.';
          },
        );
        if (!portReady) {
          return const AutoSelectDetachedProbeResult(
            domainProbeOk: false,
            ipProbeOk: false,
            throughputBytesPerSecond: 0,
          );
        }

        final probeResults = await Future.wait<bool>([
          probeHttpViaLocalProxy(
            mixedPort: mixedPort,
            url: Uri.parse(domainProbeUrl),
            timeout: _httpProbeTimeout,
          ),
          probeHttpViaLocalProxy(
            mixedPort: mixedPort,
            url: Uri.parse(ipProbeUrl),
            timeout: _httpProbeTimeout,
          ),
        ]);
        final throughputBytesPerSecond =
            await measureDownloadThroughputViaLocalProxy(
              mixedPort: mixedPort,
              url: Uri.parse(throughputProbeUrl),
              timeout: _throughputTimeout,
            );

        return AutoSelectDetachedProbeResult(
          domainProbeOk: probeResults[0],
          ipProbeOk: probeResults[1],
          throughputBytesPerSecond: throughputBytesPerSecond,
        );
      })().timeout(_probeTimeout);
    } finally {
      await stdoutSubscription?.cancel();
      await stderrSubscription?.cancel();
      if (process != null) {
        process.kill();
        try {
          await process.exitCode.timeout(const Duration(seconds: 4));
        } on TimeoutException {
          process.kill(ProcessSignal.sigkill);
          await process.exitCode.timeout(
            const Duration(seconds: 2),
            onTimeout: () => -1,
          );
        }
      }
      if (await runtimeDir.exists()) {
        try {
          await runtimeDir.delete(recursive: true);
        } on FileSystemException {
          await Future<void>.delayed(const Duration(milliseconds: 150));
          if (await runtimeDir.exists()) {
            await runtimeDir.delete(recursive: true);
          }
        }
      }
    }
  }
}
