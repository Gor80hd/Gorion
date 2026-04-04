import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gorion_clean/features/auto_select/data/auto_select_settings_repository.dart';
import 'package:gorion_clean/features/auto_select/data/auto_selector_service.dart';
import 'package:gorion_clean/features/auto_select/model/auto_select_state.dart';
import 'package:gorion_clean/features/auto_select/utils/auto_select_network_probe.dart';
import 'package:gorion_clean/features/auto_select/utils/auto_select_server_config.dart';
import 'package:gorion_clean/features/profiles/model/profile_models.dart';
import 'package:gorion_clean/features/runtime/data/singbox_runtime_support.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

class PreparedAutoConnectSelection {
  const PreparedAutoConnectSelection({
    required this.selectedServerTag,
    required this.delayByTag,
    required this.probes,
    required this.summary,
    required this.reusedRecentSuccessfulSelection,
    required this.requiresImmediatePostConnectCheck,
  });

  final String selectedServerTag;
  final Map<String, int> delayByTag;
  final List<AutoSelectProbeResult> probes;
  final String summary;
  final bool reusedRecentSuccessfulSelection;
  final bool requiresImmediatePostConnectCheck;
}

class AutoSelectPreconnectProbeResult {
  const AutoSelectPreconnectProbeResult({
    required this.serverTag,
    required this.urlTestDelay,
    required this.domainProbeOk,
    required this.ipProbeOk,
    required this.throughputBytesPerSecond,
  });

  final String serverTag;
  final int? urlTestDelay;
  final bool domainProbeOk;
  final bool ipProbeOk;
  final int throughputBytesPerSecond;

  AutoSelectProbeResult toUiProbeResult() {
    return AutoSelectProbeResult(
      serverTag: serverTag,
      urlTestDelay: urlTestDelay,
      domainProbeOk: domainProbeOk,
      ipProbeOk: ipProbeOk,
    );
  }
}

typedef AutoSelectPreconnectCandidateProbe =
    Future<AutoSelectPreconnectProbeResult> Function({
      required String profileId,
      required String templateConfig,
      required AutoSelectConfigCandidate candidate,
      required AutoSelectSettings settings,
    });

class AutoSelectPreconnectService {
  AutoSelectPreconnectService({
    required AutoSelectSettingsRepository settingsRepository,
    AutoSelectPreconnectCandidateProbe? probeCandidate,
    this.preconnectProbeBatchSize = 4,
    this.maxPreconnectProbeCandidates = 16,
    this.preconnectProbeSuccessTarget = 3,
    this.preconnectProbeTimeout = const Duration(seconds: 14),
    this.fastAcceptPingThresholdMs = 250,
    this.pingEquivalenceThresholdMs = 30,
    this.throughputPreferenceWindowMs = 90,
    this.minimumUsableThroughput = 24 * 1024,
  }) : _settingsRepository = settingsRepository,
       _probeCandidate =
           probeCandidate ?? _DetachedAutoSelectPreconnectProbe.run;

  final AutoSelectSettingsRepository _settingsRepository;
  final AutoSelectPreconnectCandidateProbe _probeCandidate;
  final int preconnectProbeBatchSize;
  final int maxPreconnectProbeCandidates;
  final int preconnectProbeSuccessTarget;
  final Duration preconnectProbeTimeout;
  final int fastAcceptPingThresholdMs;
  final int pingEquivalenceThresholdMs;
  final int throughputPreferenceWindowMs;
  final int minimumUsableThroughput;

  Future<PreparedAutoConnectSelection?> recentSuccessfulSelection({
    required ProxyProfile profile,
    required String templateConfig,
  }) async {
    final storedState = await _settingsRepository.clearExpiredCaches();
    final settings = storedState.settings;
    if (!settings.enabled || !profile.prefersAutoSelection) {
      return null;
    }

    final extractedCandidates = extractAutoSelectConfigCandidates(
      templateConfig,
    );
    if (extractedCandidates.isEmpty) {
      return null;
    }

    final candidates = extractedCandidates
        .where((candidate) => !settings.isExcluded(profile.id, candidate.tag))
        .toList(growable: false);
    if (candidates.isEmpty) {
      return null;
    }

    return _resolveRecentSuccessfulSelection(
      storedState: storedState,
      profileId: profile.id,
      candidates: candidates,
    );
  }

  Future<PreparedAutoConnectSelection?> prepare({
    required ProxyProfile profile,
    required String templateConfig,
    AutoSelectProgressReporter? onProgress,
  }) async {
    final storedState = await _settingsRepository.clearExpiredCaches();
    final settings = storedState.settings;
    if (!settings.enabled || !profile.prefersAutoSelection) {
      return null;
    }

    final extractedCandidates = extractAutoSelectConfigCandidates(
      templateConfig,
    );
    if (extractedCandidates.isEmpty) {
      throw const FormatException(
        'No selectable servers were found in the saved profile config.',
      );
    }

    final candidates = extractedCandidates
        .where((candidate) => !settings.isExcluded(profile.id, candidate.tag))
        .toList(growable: false);
    if (candidates.isEmpty) {
      throw const FormatException(
        'All servers for this profile are excluded from automatic selection.',
      );
    }

    final reusedRecentSuccessfulSelection = _resolveRecentSuccessfulSelection(
      storedState: storedState,
      profileId: profile.id,
      candidates: candidates,
    );
    if (reusedRecentSuccessfulSelection != null) {
      onProgress?.call(
        AutoSelectProgressEvent(
          message:
              'Reusing recent successful server ${reusedRecentSuccessfulSelection.selectedServerTag} before probing new candidates.',
          completedSteps: 2,
          totalSteps: 2,
        ),
      );
      return reusedRecentSuccessfulSelection;
    }

    final prioritizedCandidates = _prioritizeCandidates(
      candidates,
      profile: profile,
      storedState: storedState,
    );
    final probePlan = _buildPreconnectProbePlan(prioritizedCandidates);
    final totalSteps = probePlan.length + 2;
    onProgress?.call(
      AutoSelectProgressEvent(
        message:
            'Preparing detached probes for ${probePlan.length} server candidates before starting sing-box.',
        completedSteps: 1,
        totalSteps: totalSteps,
      ),
    );
    final delayByTag = <String, int>{};
    final allProbeResults = <AutoSelectPreconnectProbeResult>[];
    final successfulProbeResults = <AutoSelectPreconnectProbeResult>[];
    var fastAccepted = false;

    for (
      var batchStart = 0;
      batchStart < probePlan.length && !fastAccepted;
      batchStart += preconnectProbeBatchSize
    ) {
      final batchEnd = batchStart + preconnectProbeBatchSize < probePlan.length
          ? batchStart + preconnectProbeBatchSize
          : probePlan.length;
      final batch = probePlan.sublist(batchStart, batchEnd);
      for (var index = 0; index < batch.length; index += 1) {
        final probeIndex = batchStart + index;
        final candidate = batch[index];
        onProgress?.call(
          AutoSelectProgressEvent(
            message:
                'Probing ${candidate.tag} (${probeIndex + 1}/${probePlan.length}) in a detached sing-box runtime.',
            completedSteps: allProbeResults.length + 1,
            totalSteps: totalSteps,
          ),
        );
      }
      final batchResults = await Future.wait(
        batch.map(
          (candidate) => _safeProbeCandidate(
            profileId: profile.id,
            templateConfig: templateConfig,
            candidate: candidate,
            settings: settings,
          ),
        ),
      );

      for (var index = 0; index < batchResults.length; index += 1) {
        final probeResult = batchResults[index];
        allProbeResults.add(probeResult);
        final delay = probeResult.urlTestDelay;
        if (delay != null && delay > 0) {
          delayByTag[probeResult.serverTag] = delay;
        }

        onProgress?.call(
          AutoSelectProgressEvent(
            message: _describeProbeResult(probeResult, settings),
            completedSteps: allProbeResults.length + 1,
            totalSteps: totalSteps,
          ),
        );

        if (!_isSuccessfulProbe(probeResult, settings)) {
          continue;
        }

        successfulProbeResults.add(probeResult);
        if ((probeResult.urlTestDelay ?? 1 << 30) <=
            fastAcceptPingThresholdMs) {
          fastAccepted = true;
        }
      }

      if (successfulProbeResults.length >= preconnectProbeSuccessTarget) {
        break;
      }
    }

    if (successfulProbeResults.isEmpty) {
      final rankedProbeResults = _rankProbeResults(allProbeResults);
      final bestEffortCandidate = _pickBestEffortCandidate(rankedProbeResults);
      if (bestEffortCandidate != null) {
        final bestEffortSummary =
            'No fully confirmed server passed the detached pre-connect probe. Using best-effort candidate ${bestEffortCandidate.serverTag} and rechecking immediately after connect.';
        onProgress?.call(
          AutoSelectProgressEvent(
            message: bestEffortSummary,
            completedSteps: totalSteps,
            totalSteps: totalSteps,
          ),
        );
        return PreparedAutoConnectSelection(
          selectedServerTag: bestEffortCandidate.serverTag,
          delayByTag: delayByTag,
          probes: [
            for (final probe in rankedProbeResults) probe.toUiProbeResult(),
          ],
          summary: bestEffortSummary,
          reusedRecentSuccessfulSelection: false,
          requiresImmediatePostConnectCheck: true,
        );
      }

      onProgress?.call(
        AutoSelectProgressEvent(
          message:
              'No candidate passed the detached pre-connect probe. Continuing with the saved server and retrying after connect.',
          completedSteps: totalSteps,
          totalSteps: totalSteps,
        ),
      );
      return null;
    }

    final winner = _pickWinner(successfulProbeResults);
    final rankedProbes = [
      for (final probe in _rankProbeResults(allProbeResults))
        probe.toUiProbeResult(),
    ];
    final winnerDelay = winner.urlTestDelay;
    final throughputKbps = (winner.throughputBytesPerSecond / 1024)
        .toStringAsFixed(0);
    final summary = winnerDelay == null
        ? 'Auto-selector chose ${winner.serverTag} before connect after confirming end-to-end proxy traffic.'
        : 'Auto-selector chose ${winner.serverTag} before connect ($winnerDelay ms, $throughputKbps KB/s).';

    onProgress?.call(
      AutoSelectProgressEvent(
        message: summary,
        completedSteps: totalSteps,
        totalSteps: totalSteps,
      ),
    );

    return PreparedAutoConnectSelection(
      selectedServerTag: winner.serverTag,
      delayByTag: delayByTag,
      probes: rankedProbes,
      summary: summary,
      reusedRecentSuccessfulSelection: false,
      requiresImmediatePostConnectCheck: false,
    );
  }

  PreparedAutoConnectSelection? _resolveRecentSuccessfulSelection({
    required StoredAutoSelectState storedState,
    required String profileId,
    required List<AutoSelectConfigCandidate> candidates,
  }) {
    final recentSuccessfulAutoConnect = storedState.recentSuccessfulAutoConnect;
    if (recentSuccessfulAutoConnect == null ||
        !recentSuccessfulAutoConnect.matchesProfile(profileId)) {
      return null;
    }

    for (final candidate in candidates) {
      if (candidate.tag == recentSuccessfulAutoConnect.tag) {
        return PreparedAutoConnectSelection(
          selectedServerTag: candidate.tag,
          delayByTag: const {},
          probes: const [],
          summary:
              'Auto-selector reused the recent successful server ${candidate.tag} before starting sing-box.',
          reusedRecentSuccessfulSelection: true,
          requiresImmediatePostConnectCheck: false,
        );
      }
    }

    return null;
  }

  Future<AutoSelectPreconnectProbeResult> _safeProbeCandidate({
    required String profileId,
    required String templateConfig,
    required AutoSelectConfigCandidate candidate,
    required AutoSelectSettings settings,
  }) async {
    try {
      return await _probeCandidate(
        profileId: profileId,
        templateConfig: templateConfig,
        candidate: candidate,
        settings: settings,
      ).timeout(preconnectProbeTimeout);
    } on Object {
      return AutoSelectPreconnectProbeResult(
        serverTag: candidate.tag,
        urlTestDelay: null,
        domainProbeOk: false,
        ipProbeOk: false,
        throughputBytesPerSecond: 0,
      );
    }
  }

  bool _isSuccessfulProbe(
    AutoSelectPreconnectProbeResult probeResult,
    AutoSelectSettings settings,
  ) {
    final delay = probeResult.urlTestDelay ?? 0;
    final hasUsableThroughput =
        probeResult.throughputBytesPerSecond >= minimumUsableThroughput;
    if (!hasUsableThroughput) {
      return false;
    }

    if (delay > 0) {
      return true;
    }

    return probeResult.domainProbeOk || probeResult.ipProbeOk;
  }

  AutoSelectPreconnectProbeResult _pickWinner(
    List<AutoSelectPreconnectProbeResult> successfulProbeResults,
  ) {
    final ranked = [...successfulProbeResults]..sort(_compareSuccessfulProbes);
    return ranked.first;
  }

  List<AutoSelectPreconnectProbeResult> _rankProbeResults(
    List<AutoSelectPreconnectProbeResult> probeResults,
  ) {
    final ranked = [...probeResults];
    ranked.sort((left, right) {
      final leftScore = _healthScore(left);
      final rightScore = _healthScore(right);
      final scoreCompare = rightScore.compareTo(leftScore);
      if (scoreCompare != 0) {
        return scoreCompare;
      }
      return _compareSuccessfulProbes(left, right);
    });
    return ranked;
  }

  AutoSelectPreconnectProbeResult? _pickBestEffortCandidate(
    List<AutoSelectPreconnectProbeResult> rankedProbeResults,
  ) {
    final probes = [...rankedProbeResults]..sort(_compareBestEffortProbes);
    for (final probeResult in probes) {
      if (_hasAnyConnectivitySignal(probeResult)) {
        return probeResult;
      }
    }
    return null;
  }

  int _compareBestEffortProbes(
    AutoSelectPreconnectProbeResult left,
    AutoSelectPreconnectProbeResult right,
  ) {
    final throughputCompare = right.throughputBytesPerSecond.compareTo(
      left.throughputBytesPerSecond,
    );
    if (throughputCompare != 0) {
      return throughputCompare;
    }

    final leftDelay = left.urlTestDelay ?? 0;
    final rightDelay = right.urlTestDelay ?? 0;
    final leftHasDelay = leftDelay > 0;
    final rightHasDelay = rightDelay > 0;
    if (leftHasDelay != rightHasDelay) {
      return rightHasDelay ? 1 : -1;
    }
    if (leftHasDelay && rightHasDelay) {
      final delayCompare = leftDelay.compareTo(rightDelay);
      if (delayCompare != 0) {
        return delayCompare;
      }
    }

    final healthCompare = _healthScore(right).compareTo(_healthScore(left));
    if (healthCompare != 0) {
      return healthCompare;
    }

    return left.serverTag.compareTo(right.serverTag);
  }

  bool _hasAnyConnectivitySignal(AutoSelectPreconnectProbeResult probeResult) {
    return probeResult.domainProbeOk ||
        probeResult.ipProbeOk ||
        probeResult.throughputBytesPerSecond > 0;
  }

  List<AutoSelectConfigCandidate> _prioritizeCandidates(
    List<AutoSelectConfigCandidate> candidates, {
    required ProxyProfile profile,
    required StoredAutoSelectState storedState,
  }) {
    final prioritizedTags = <String>[];
    final recentAutoSelectedServer = storedState.recentAutoSelectedServer;
    if (recentAutoSelectedServer != null &&
        recentAutoSelectedServer.matchesProfile(profile.id)) {
      prioritizedTags.add(recentAutoSelectedServer.tag);
    }

    final resolvedAutoSelectedServerTag = profile.resolvedAutoSelectedServerTag;
    if (resolvedAutoSelectedServerTag != null &&
        resolvedAutoSelectedServerTag.isNotEmpty) {
      prioritizedTags.add(resolvedAutoSelectedServerTag);
    }

    if (prioritizedTags.isEmpty) {
      return candidates;
    }

    final prioritizedCandidates = <AutoSelectConfigCandidate>[];
    final seenTags = <String>{};

    for (final prioritizedTag in prioritizedTags) {
      for (final candidate in candidates) {
        if (candidate.tag != prioritizedTag || !seenTags.add(candidate.tag)) {
          continue;
        }
        prioritizedCandidates.add(candidate);
        break;
      }
    }

    for (final candidate in candidates) {
      if (seenTags.add(candidate.tag)) {
        prioritizedCandidates.add(candidate);
      }
    }

    return prioritizedCandidates;
  }

  int _compareSuccessfulProbes(
    AutoSelectPreconnectProbeResult left,
    AutoSelectPreconnectProbeResult right,
  ) {
    final leftDelay = left.urlTestDelay ?? 1 << 30;
    final rightDelay = right.urlTestDelay ?? 1 << 30;
    final delayGap = leftDelay - rightDelay;
    if (delayGap.abs() <= throughputPreferenceWindowMs) {
      return right.throughputBytesPerSecond.compareTo(
        left.throughputBytesPerSecond,
      );
    }
    return leftDelay.compareTo(rightDelay);
  }

  int _healthScore(AutoSelectPreconnectProbeResult probeResult) {
    if (probeResult.domainProbeOk && probeResult.ipProbeOk) {
      return 3;
    }
    if (probeResult.domainProbeOk) {
      return 2;
    }
    if (probeResult.ipProbeOk) {
      return 1;
    }
    return 0;
  }

  String _describeProbeResult(
    AutoSelectPreconnectProbeResult probeResult,
    AutoSelectSettings settings,
  ) {
    final delayLabel = probeResult.urlTestDelay == null
        ? 'n/a'
        : '${probeResult.urlTestDelay}ms';
    final throughputKbps = (probeResult.throughputBytesPerSecond / 1024)
        .toStringAsFixed(0);
    final ipLabel = settings.checkIp
        ? (probeResult.ipProbeOk ? 'IP OK' : 'IP failed')
        : (probeResult.ipProbeOk ? 'IP OK' : 'IP skipped');
    return 'Probe result for ${probeResult.serverTag}: URLTest $delayLabel, ${probeResult.domainProbeOk ? 'domain OK' : 'domain failed'}, $ipLabel, $throughputKbps KB/s.';
  }

  List<AutoSelectConfigCandidate> _buildPreconnectProbePlan(
    List<AutoSelectConfigCandidate> candidates,
  ) {
    if (candidates.length <= maxPreconnectProbeCandidates) {
      return candidates;
    }

    const segmentCount = 4;
    final segments = <List<AutoSelectConfigCandidate>>[];
    final baseSegmentSize = candidates.length ~/ segmentCount;
    final remainder = candidates.length % segmentCount;
    var offset = 0;
    for (var index = 0; index < segmentCount; index += 1) {
      final segmentSize = baseSegmentSize + (index < remainder ? 1 : 0);
      final end = offset + segmentSize;
      segments.add(candidates.sublist(offset, end));
      offset = end;
    }

    final planned = <AutoSelectConfigCandidate>[];
    var cursor = 0;
    while (planned.length < maxPreconnectProbeCandidates) {
      var addedAny = false;
      for (final segment in segments) {
        if (cursor >= segment.length) {
          continue;
        }
        planned.add(segment[cursor]);
        addedAny = true;
        if (planned.length >= maxPreconnectProbeCandidates) {
          break;
        }
      }
      if (!addedAny) {
        break;
      }
      cursor += 1;
    }
    return planned;
  }
}

class _DetachedAutoSelectPreconnectProbe {
  static const _probeTimeout = Duration(seconds: 14);
  static const _startupTimeout = Duration(seconds: 8);
  static const _httpProbeTimeout = Duration(seconds: 3);
  static const _throughputTimeout = Duration(seconds: 2);

  static Future<AutoSelectPreconnectProbeResult> run({
    required String profileId,
    required String templateConfig,
    required AutoSelectConfigCandidate candidate,
    required AutoSelectSettings settings,
  }) async {
    // Use a minimal config containing only this server's outbound behind a
    // mixed inbound — no DNS, no routing rules, no Clash API.  This starts
    // significantly faster than the full profile config and fails early when
    // the server is unreachable, keeping the overall pre-connect probe fast.
    final outbound = extractAutoSelectConfigOutbound(
      templateConfig,
      candidate.tag,
    );
    if (outbound == null) {
      return AutoSelectPreconnectProbeResult(
        serverTag: candidate.tag,
        urlTestDelay: null,
        domainProbeOk: false,
        ipProbeOk: false,
        throughputBytesPerSecond: 0,
      );
    }

    final runtimeDir = await ensureGorionRuntimeDirectory(
      subdirectory: p.join('preconnect', const Uuid().v4()),
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

      final configFile = File(
        p.join(runtimeDir.path, 'preconnect-config.json'),
      );
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
        // Wait for the mixed port to accept connections instead of the Clash
        // API (the minimal config has no Clash API).
        final portReady = await waitForLocalPortReady(
          mixedPort,
          timeout: _startupTimeout,
          abortReason: () {
            final exitCode = startupExitCode;
            if (exitCode == null) return null;
            return 'Detached pre-connect sing-box probe exited early with code $exitCode.';
          },
        );
        if (!portReady) {
          return AutoSelectPreconnectProbeResult(
            serverTag: candidate.tag,
            urlTestDelay: null,
            domainProbeOk: false,
            ipProbeOk: false,
            throughputBytesPerSecond: 0,
          );
        }

        final domainProbeFuture = probeHttpViaLocalProxy(
          mixedPort: mixedPort,
          url: Uri.parse(settings.domainProbeUrl),
          timeout: _httpProbeTimeout,
        );
        final throughputFuture = measureDownloadThroughputViaLocalProxy(
          mixedPort: mixedPort,
          url: Uri.parse(defaultAutoSelectThroughputProbeUrl),
          timeout: _throughputTimeout,
        );

        late final bool domainProbeOk;
        late final bool ipProbeOk;
        if (settings.checkIp) {
          final probeResults = await Future.wait<bool>([
            domainProbeFuture,
            probeHttpViaLocalProxy(
              mixedPort: mixedPort,
              url: Uri.parse(settings.ipProbeUrl),
              timeout: _httpProbeTimeout,
            ),
          ]);
          domainProbeOk = probeResults[0];
          ipProbeOk = probeResults[1];
        } else {
          domainProbeOk = await domainProbeFuture;
          ipProbeOk = true;
        }

        final throughputBytesPerSecond = await throughputFuture;

        // urlTestDelay is not available from a minimal config (no Clash API /
        // URLtest group).  The preconnect ranking falls back to throughput when
        // delays are absent, which is equivalent to Gorion's behaviour.
        return AutoSelectPreconnectProbeResult(
          serverTag: candidate.tag,
          urlTestDelay: null,
          domainProbeOk: domainProbeOk,
          ipProbeOk: ipProbeOk,
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
