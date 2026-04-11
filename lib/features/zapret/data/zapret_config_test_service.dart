import 'dart:async';
import 'dart:io';

import 'package:gorion_clean/features/zapret/data/zapret_runtime_service.dart';
import 'package:gorion_clean/features/zapret/model/zapret_models.dart';
import 'package:gorion_clean/features/zapret/model/zapret_settings.dart';
import 'package:path/path.dart' as p;

class ZapretConfigTestService {
  ZapretConfigTestService({
    required ZapretRuntimeService runtimeService,
    Duration startupDelay = const Duration(seconds: 4),
    Duration requestTimeout = const Duration(seconds: 5),
  }) : _runtimeService = runtimeService,
       _startupDelay = startupDelay,
       _requestTimeout = requestTimeout;

  final ZapretRuntimeService _runtimeService;
  final Duration _startupDelay;
  final Duration _requestTimeout;

  Future<ZapretConfigTestSuite> runHttpSuite({
    required ZapretSettings settings,
    FutureOr<void> Function(
      int completed,
      int total,
      ZapretConfigOption config,
    )?
    onProgress,
  }) async {
    if (!Platform.isWindows) {
      throw UnsupportedError(
        'Автотест конфигов Boost сейчас поддерживается только на Windows.',
      );
    }

    final hydratedSettings = await _runtimeService.hydrateSettings(settings);
    final installDirectory = hydratedSettings.normalizedInstallDirectory;
    if (installDirectory.isEmpty) {
      throw const FormatException('Сначала укажите каталог установки zapret.');
    }

    final configs = _runtimeService.listAvailableProfiles(installDirectory);
    if (configs.isEmpty) {
      throw const FormatException(
        'В папке zapret не найдены конфиги для тестирования.',
      );
    }

    final targetFile = _resolveTargetsFile(installDirectory);
    if (targetFile == null) {
      throw FileSystemException(
        'Не найден файл целей стандартного теста (targets.txt).',
        p.join(installDirectory, 'files', 'targets.txt'),
      );
    }

    final parsedTargets = _loadTargets(targetFile);
    _ensureCriticalTargets(parsedTargets);
    final primaryTargets = parsedTargets
        .where((target) => target.requiredForSuccess)
        .toList(growable: false);
    if (primaryTargets.isEmpty) {
      throw const FormatException(
        'В targets.txt не найдено ни одной HTTP/HTTPS цели для основных проверок.',
      );
    }
    final results = <ZapretConfigTestResult>[];

    for (var index = 0; index < configs.length; index += 1) {
      final config = configs[index];
      if (onProgress != null) {
        await onProgress(index, configs.length, config);
      }
      results.add(
        await _testSingleConfig(
          baseSettings: hydratedSettings,
          config: config,
          targets: parsedTargets,
        ),
      );
    }

    results.sort(_compareResults);
    return ZapretConfigTestSuite(
      targets: List<ZapretProbeTarget>.unmodifiable(parsedTargets),
      results: List<ZapretConfigTestResult>.unmodifiable(results),
      targetsPath: targetFile.path,
      ignoredTargetCount: 0,
    );
  }

  File? _resolveTargetsFile(String installDirectory) {
    final candidates = <String>[
      p.join(installDirectory, 'files', 'targets.txt'),
      p.join(installDirectory, 'targets.txt'),
      p.join(installDirectory, 'utils', 'targets.txt'),
    ];

    for (final candidate in candidates) {
      final file = File(candidate);
      if (file.existsSync()) {
        return file;
      }
    }

    return null;
  }

  List<ZapretProbeTarget> _loadTargets(File targetFile) {
    final targets = <ZapretProbeTarget>[];
    final lines = targetFile.readAsLinesSync();

    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#') || line.startsWith(';')) {
        continue;
      }

      final match = RegExp(r'^\s*([^=]+?)\s*=\s*"(.+)"\s*$').firstMatch(line);
      if (match == null) {
        continue;
      }

      final label = match.group(1)!.trim();
      final value = match.group(2)!.trim();
      if (value.toUpperCase().startsWith('PING:')) {
        targets.add(
          ZapretProbeTarget(
            id: '${label}_ping',
            label: '$label Ping',
            kind: ZapretProbeKind.ping,
            address: value.substring(5).trim(),
            requiredForSuccess: false,
          ),
        );
        continue;
      }

      if (value.toUpperCase().startsWith('WSS:') ||
          value.toUpperCase().startsWith('WS:')) {
        final websocketUrl = value.contains(':')
            ? value.substring(value.indexOf(':') + 1).trim()
            : '';
        final uri = Uri.tryParse(websocketUrl);
        final host = uri?.host.trim() ?? '';
        if (uri == null || host.isEmpty) {
          continue;
        }
        targets.add(
          ZapretProbeTarget(
            id: '${label}_ws',
            label: '$label WebSocket',
            kind: ZapretProbeKind.websocket,
            address: websocketUrl,
          ),
        );
        targets.add(
          ZapretProbeTarget(
            id: '${label}_ping',
            label: '$label Ping',
            kind: ZapretProbeKind.ping,
            address: host,
            requiredForSuccess: false,
          ),
        );
        continue;
      }

      final isGetTarget = value.toUpperCase().startsWith('GET:');
      final normalizedValue = isGetTarget ? value.substring(4).trim() : value;

      final uri = Uri.tryParse(normalizedValue);
      final host = uri?.host.trim() ?? '';
      if (host.isEmpty) {
        continue;
      }

      targets.add(
        ZapretProbeTarget(
          id: '${label}_http11',
          label: '$label HTTP/1.1',
          kind: isGetTarget
              ? ZapretProbeKind.http11Get
              : ZapretProbeKind.http11,
          address: normalizedValue,
        ),
      );
      targets.add(
        ZapretProbeTarget(
          id: '${label}_tls12',
          label: '$label TLS 1.2',
          kind: isGetTarget ? ZapretProbeKind.tls12Get : ZapretProbeKind.tls12,
          address: normalizedValue,
        ),
      );
      targets.add(
        ZapretProbeTarget(
          id: '${label}_tls13',
          label: '$label TLS 1.3',
          kind: isGetTarget ? ZapretProbeKind.tls13Get : ZapretProbeKind.tls13,
          address: normalizedValue,
        ),
      );
      targets.add(
        ZapretProbeTarget(
          id: '${label}_ping',
          label: '$label Ping',
          kind: ZapretProbeKind.ping,
          address: host,
          requiredForSuccess: false,
        ),
      );
    }

    return targets;
  }

  void _ensureCriticalTargets(List<ZapretProbeTarget> targets) {
    final ids = targets.map((target) => target.id).toSet();

    void addIfMissing(ZapretProbeTarget target) {
      if (ids.contains(target.id)) {
        return;
      }
      targets.add(target);
      ids.add(target.id);
    }

    addIfMissing(
      const ZapretProbeTarget(
        id: 'DiscordAppShell_http11_get',
        label: 'DiscordAppShell HTTP/1.1 GET',
        kind: ZapretProbeKind.http11Get,
        address: 'https://discord.com/app',
      ),
    );
    addIfMissing(
      const ZapretProbeTarget(
        id: 'DiscordAppShell_tls12_get',
        label: 'DiscordAppShell TLS 1.2 GET',
        kind: ZapretProbeKind.tls12Get,
        address: 'https://discord.com/app',
      ),
    );
    addIfMissing(
      const ZapretProbeTarget(
        id: 'DiscordAppShell_tls13_get',
        label: 'DiscordAppShell TLS 1.3 GET',
        kind: ZapretProbeKind.tls13Get,
        address: 'https://discord.com/app',
      ),
    );
    addIfMissing(
      const ZapretProbeTarget(
        id: 'DiscordApiExperiments_http11_get',
        label: 'DiscordApiExperiments HTTP/1.1 GET',
        kind: ZapretProbeKind.http11Get,
        address: 'https://discord.com/api/v9/experiments',
      ),
    );
    addIfMissing(
      const ZapretProbeTarget(
        id: 'DiscordApiExperiments_tls12_get',
        label: 'DiscordApiExperiments TLS 1.2 GET',
        kind: ZapretProbeKind.tls12Get,
        address: 'https://discord.com/api/v9/experiments',
      ),
    );
    addIfMissing(
      const ZapretProbeTarget(
        id: 'DiscordApiExperiments_tls13_get',
        label: 'DiscordApiExperiments TLS 1.3 GET',
        kind: ZapretProbeKind.tls13Get,
        address: 'https://discord.com/api/v9/experiments',
      ),
    );
    addIfMissing(
      const ZapretProbeTarget(
        id: 'DiscordGatewayWS_ws',
        label: 'DiscordGatewayWS WebSocket',
        kind: ZapretProbeKind.websocket,
        address: 'wss://gateway.discord.gg/?v=9&encoding=json',
      ),
    );
    addIfMissing(
      const ZapretProbeTarget(
        id: 'DiscordGatewayWS_ping',
        label: 'DiscordGatewayWS Ping',
        kind: ZapretProbeKind.ping,
        address: 'gateway.discord.gg',
        requiredForSuccess: false,
      ),
    );
  }

  Future<ZapretConfigTestResult> _testSingleConfig({
    required ZapretSettings baseSettings,
    required ZapretConfigOption config,
    required List<ZapretProbeTarget> targets,
  }) async {
    final settings = baseSettings.copyWith(configFileName: config.fileName);
    final exitCode = Completer<int>();

    try {
      _runtimeService.recordDiagnostic(
        'Стандартный тест конфига ${config.fileName}: подготовка запуска.',
      );
      final session = await _runtimeService.start(
        settings: settings,
        onExit: (code) {
          if (!exitCode.isCompleted) {
            exitCode.complete(code);
          }
        },
        preserveLogs: true,
      );

      await Future<void>.delayed(_startupDelay);
      if (_runtimeService.session?.processId != session.processId) {
        final processExitCode = await exitCode.future.timeout(
          const Duration(milliseconds: 100),
          onTimeout: () => -1,
        );
        return ZapretConfigTestResult(
          config: config,
          report: _buildFailureReport(
            targets,
            'Процесс завершился до начала проверки (код $processExitCode).',
          ),
          launchError: 'Процесс завершился до начала проверки.',
        );
      }

      final report = await _runTargets(targets);
      _runtimeService.recordDiagnostic(
        'Стандартный тест ${config.fileName}: ${report.summary}',
      );
      return ZapretConfigTestResult(config: config, report: report);
    } on Object catch (error) {
      _runtimeService.recordDiagnostic(
        'Стандартный тест ${config.fileName} завершился ошибкой: $error',
        isError: true,
      );
      return ZapretConfigTestResult(
        config: config,
        report: _buildFailureReport(targets, 'Не удалось запустить конфиг.'),
        launchError: error.toString(),
      );
    } finally {
      await _runtimeService.stop();
    }
  }

  ZapretProbeReport _buildFailureReport(
    List<ZapretProbeTarget> targets,
    String details,
  ) {
    return ZapretProbeReport(
      results: targets
          .map(
            (target) => ZapretProbeResult(
              target: target,
              success: false,
              details: details,
            ),
          )
          .toList(growable: false),
    );
  }

  Future<ZapretProbeReport> _runTargets(List<ZapretProbeTarget> targets) async {
    final results = await Future.wait(
      targets.map(_runSingleProbeTarget),
      eagerError: false,
    );
    return ZapretProbeReport(
      results: List<ZapretProbeResult>.unmodifiable(results),
    );
  }

  Future<ZapretProbeResult> _runSingleProbeTarget(
    ZapretProbeTarget target,
  ) async {
    return switch (target.kind) {
      ZapretProbeKind.http11 => _runCurlProbe(
        target: target,
        useHead: true,
        extraArgs: const ['--http1.1'],
      ),
      ZapretProbeKind.tls12 => _runCurlProbe(
        target: target,
        useHead: true,
        extraArgs: const ['--tlsv1.2', '--tls-max', '1.2'],
      ),
      ZapretProbeKind.tls13 => _runCurlProbe(
        target: target,
        useHead: true,
        extraArgs: const ['--tlsv1.3', '--tls-max', '1.3'],
      ),
      ZapretProbeKind.http11Get => _runCurlProbe(
        target: target,
        useHead: false,
        extraArgs: const ['--http1.1'],
      ),
      ZapretProbeKind.tls12Get => _runCurlProbe(
        target: target,
        useHead: false,
        extraArgs: const ['--tlsv1.2', '--tls-max', '1.2'],
      ),
      ZapretProbeKind.tls13Get => _runCurlProbe(
        target: target,
        useHead: false,
        extraArgs: const ['--tlsv1.3', '--tls-max', '1.3'],
      ),
      ZapretProbeKind.websocket => _runWebSocketProbe(target),
      ZapretProbeKind.ping => _runPingProbe(target),
    };
  }

  Future<ZapretProbeResult> _runCurlProbe({
    required ZapretProbeTarget target,
    required bool useHead,
    required List<String> extraArgs,
  }) async {
    final stopwatch = Stopwatch()..start();
    try {
      final result = await Process.run('curl.exe', [
        if (useHead) '-I',
        '-s',
        '-m',
        '${_requestTimeout.inSeconds}',
        '-o',
        'NUL',
        '-w',
        '%{http_code}',
        '--show-error',
        ...extraArgs,
        target.address,
      ]).timeout(_requestTimeout + const Duration(seconds: 1));
      stopwatch.stop();

      final stdout = result.stdout.toString().trim();
      final stderr = result.stderr.toString().trim();
      final success = result.exitCode == 0;
      final details = success
          ? 'HTTP ${stdout.isEmpty ? 'n/a' : stdout}'
          : _normalizeCurlFailure(stderr, stdout);

      return ZapretProbeResult(
        target: target,
        success: success,
        latencyMs: success ? stopwatch.elapsedMilliseconds : null,
        details: details,
      );
    } on TimeoutException {
      return ZapretProbeResult(
        target: target,
        success: false,
        details: 'Таймаут ${_requestTimeout.inSeconds} c',
      );
    } on Object catch (error) {
      return ZapretProbeResult(
        target: target,
        success: false,
        details: error.toString(),
      );
    }
  }

  Future<ZapretProbeResult> _runWebSocketProbe(ZapretProbeTarget target) async {
    final stopwatch = Stopwatch()..start();
    try {
      final socket = await WebSocket.connect(
        target.address,
      ).timeout(_requestTimeout);
      stopwatch.stop();
      final protocol = socket.protocol ?? '';
      await socket.close(WebSocketStatus.normalClosure, 'gorion-probe');
      return ZapretProbeResult(
        target: target,
        success: true,
        latencyMs: stopwatch.elapsedMilliseconds,
        details: protocol.isEmpty
            ? 'WebSocket открыт'
            : 'WebSocket protocol: $protocol',
      );
    } on TimeoutException {
      return ZapretProbeResult(
        target: target,
        success: false,
        details: 'WebSocket timeout',
      );
    } on WebSocketException catch (error) {
      return ZapretProbeResult(
        target: target,
        success: false,
        details: error.message,
      );
    } on SocketException catch (error) {
      return ZapretProbeResult(
        target: target,
        success: false,
        details: error.message,
      );
    } on HandshakeException catch (error) {
      return ZapretProbeResult(
        target: target,
        success: false,
        details: 'TLS: ${error.message}',
      );
    } on Object catch (error) {
      return ZapretProbeResult(
        target: target,
        success: false,
        details: error.toString(),
      );
    }
  }

  String _normalizeCurlFailure(String stderr, String stdout) {
    final details = [
      stderr,
      stdout,
    ].where((entry) => entry.trim().isNotEmpty).join(' | ');
    if (details.isEmpty) {
      return 'curl завершился с ошибкой';
    }
    return details;
  }

  Future<ZapretProbeResult> _runPingProbe(ZapretProbeTarget target) async {
    try {
      final result = await Process.run(
        'powershell.exe',
        [
          '-NoProfile',
          '-NonInteractive',
          '-ExecutionPolicy',
          'Bypass',
          '-Command',
          r"$r=Test-Connection -ComputerName $env:GORION_PING_HOST -Count 3 -ErrorAction Stop; [int][Math]::Round(($r | Measure-Object -Property ResponseTime -Average).Average)",
        ],
        environment: {'GORION_PING_HOST': target.address},
      ).timeout(_requestTimeout + const Duration(seconds: 2));

      if (result.exitCode != 0) {
        final details = [
          result.stderr.toString().trim(),
          result.stdout.toString().trim(),
        ].where((entry) => entry.isNotEmpty).join(' | ');
        return ZapretProbeResult(
          target: target,
          success: false,
          details: details.isEmpty ? 'Ping не прошёл' : details,
        );
      }

      final latency = int.tryParse(result.stdout.toString().trim());
      return ZapretProbeResult(
        target: target,
        success: latency != null,
        latencyMs: latency,
        details: latency == null
            ? 'Не удалось разобрать ping'
            : 'Ping $latency ms',
      );
    } on TimeoutException {
      return ZapretProbeResult(
        target: target,
        success: false,
        details: 'Ping timeout',
      );
    } on Object catch (error) {
      return ZapretProbeResult(
        target: target,
        success: false,
        details: error.toString(),
      );
    }
  }

  int _compareResults(
    ZapretConfigTestResult left,
    ZapretConfigTestResult right,
  ) {
    final leftWorking = left.fullyWorking ? 1 : 0;
    final rightWorking = right.fullyWorking ? 1 : 0;
    final workingComparison = rightWorking.compareTo(leftWorking);
    if (workingComparison != 0) {
      return workingComparison;
    }

    final successComparison = right.successCount.compareTo(left.successCount);
    if (successComparison != 0) {
      return successComparison;
    }

    final pingComparison = right.pingSuccessCount.compareTo(
      left.pingSuccessCount,
    );
    if (pingComparison != 0) {
      return pingComparison;
    }

    final leftLatency = left.averageLatencyMs ?? 1 << 30;
    final rightLatency = right.averageLatencyMs ?? 1 << 30;
    final latencyComparison = leftLatency.compareTo(rightLatency);
    if (latencyComparison != 0) {
      return latencyComparison;
    }

    final leftTotalLatency = left.totalLatencyMs ?? 1 << 30;
    final rightTotalLatency = right.totalLatencyMs ?? 1 << 30;
    final totalLatencyComparison = leftTotalLatency.compareTo(
      rightTotalLatency,
    );
    if (totalLatencyComparison != 0) {
      return totalLatencyComparison;
    }

    final leftLaunchPenalty = left.launchSucceeded ? 0 : 1;
    final rightLaunchPenalty = right.launchSucceeded ? 0 : 1;
    final launchComparison = leftLaunchPenalty.compareTo(rightLaunchPenalty);
    if (launchComparison != 0) {
      return launchComparison;
    }

    return left.config.label.toLowerCase().compareTo(
      right.config.label.toLowerCase(),
    );
  }
}
