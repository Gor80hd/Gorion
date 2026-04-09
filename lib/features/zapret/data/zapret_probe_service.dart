import 'dart:async';
import 'dart:io';

import 'package:gorion_clean/core/http_client/http_client_provider.dart';
import 'package:gorion_clean/features/zapret/model/zapret_models.dart';

class ZapretProbeService {
  ZapretProbeService({this.userAgent = 'Gorion/1.0', this.httpClient});

  static const _discordDownloadUrl =
      'https://discord.com/api/download?platform=win&format=exe';
  static const _discordDownloadUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36';

  final String userAgent;
  final DioHttpClient? httpClient;

  static const List<ZapretProbeTarget> defaultTargets = [
    ZapretProbeTarget(
      id: 'youtube',
      label: 'YouTube',
      kind: ZapretProbeKind.http,
      address: 'https://www.youtube.com/generate_204',
    ),
    ZapretProbeTarget(
      id: 'discord',
      label: 'Discord',
      kind: ZapretProbeKind.http,
      address: 'https://discord.com/api/v9/experiments',
    ),
    ZapretProbeTarget(
      id: 'google',
      label: 'Google',
      kind: ZapretProbeKind.http,
      address: 'https://www.google.com/generate_204',
    ),
    ZapretProbeTarget(
      id: 'cloudflare',
      label: 'Cloudflare',
      kind: ZapretProbeKind.http,
      address: 'https://cp.cloudflare.com/generate_204',
    ),
    ZapretProbeTarget(
      id: 'dns-1-1-1-1',
      label: 'DNS 1.1.1.1',
      kind: ZapretProbeKind.ping,
      address: '1.1.1.1',
      requiredForSuccess: false,
    ),
    ZapretProbeTarget(
      id: 'dns-8-8-8-8',
      label: 'DNS 8.8.8.8',
      kind: ZapretProbeKind.ping,
      address: '8.8.8.8',
      requiredForSuccess: false,
    ),
  ];

  Future<ZapretProbeReport> runDefaultProbes({
    void Function(String line)? onLog,
  }) async {
    return runProbes(onLog: onLog);
  }

  Future<ZapretProbeReport> runProbes({
    List<ZapretProbeTarget>? targets,
    void Function(String line)? onLog,
  }) async {
    final client =
        httpClient ??
        DioHttpClient(
          timeout: const Duration(seconds: 8),
          userAgent: userAgent,
        );
    final probeTargets = targets ?? defaultTargets;

    final results = await Future.wait([
      for (final target in probeTargets)
        switch (target.kind) {
          ZapretProbeKind.http => _runHttpProbe(client, target),
          ZapretProbeKind.ping => _runPingProbe(target),
        },
    ]);

    for (final result in results) {
      onLog?.call(result.summary);
    }

    return ZapretProbeReport(results: List.unmodifiable(results));
  }

  List<ZapretProbeTarget> targetsById(Iterable<String> ids) {
    final idSet = ids.toSet();
    return [
      for (final target in defaultTargets)
        if (idSet.contains(target.id)) target,
    ];
  }

  Future<ZapretProbeResult> _runHttpProbe(
    DioHttpClient client,
    ZapretProbeTarget target,
  ) async {
    return switch (target.id) {
      'youtube' || 'google' || 'cloudflare' => _runValidatedHttpProbe(
        client: client,
        target: target,
        expectedStatuses: const {204},
      ),
      'discord' => _runDiscordProbe(client, target),
      _ => _runValidatedHttpProbe(
        client: client,
        target: target,
        expectedStatuses: const {200},
      ),
    };
  }

  Future<ZapretProbeResult> _runValidatedHttpProbe({
    required DioHttpClient client,
    required ZapretProbeTarget target,
    required Set<int> expectedStatuses,
  }) async {
    final attempt = await _probeHttp(
      client: client,
      url: target.address,
      method: HttpProbeMethod.head,
      expectedStatuses: expectedStatuses,
    );

    return ZapretProbeResult(
      target: target,
      success: attempt.success,
      latencyMs: attempt.latencyMs,
      details: attempt.details,
    );
  }

  Future<ZapretProbeResult> _runDiscordProbe(
    DioHttpClient client,
    ZapretProbeTarget target,
  ) async {
    final apiAttempt = await _probeHttp(
      client: client,
      url: 'https://discord.com/api/v9/experiments',
      method: HttpProbeMethod.get,
      expectedStatuses: const {200},
      bodyContains: 'fingerprint',
      successLabel: 'GET experiments 200',
    );
    final redirectAttempt = await _probeHttp(
      client: client,
      url: _discordDownloadUrl,
      method: HttpProbeMethod.head,
      expectedStatuses: const {302},
      followRedirects: false,
      maxRedirects: 0,
      locationContains: 'discordapp.net',
      successLabel: 'HEAD update redirect 302',
    );
    final downloadAttempt = await _probeDownload(
      client: client,
      url: _discordDownloadUrl,
      expectedStatuses: const {200, 206},
      effectiveUrlContains: 'discordapp.net',
      successLabel: 'GET installer bytes',
    );

    final success =
        apiAttempt.success &&
        redirectAttempt.success &&
        downloadAttempt.success;
    final latencyMs = _combinedLatency(
      apiAttempt.latencyMs,
      _combinedLatency(redirectAttempt.latencyMs, downloadAttempt.latencyMs),
    );
    final details = success
        ? '${apiAttempt.details}; ${redirectAttempt.details}; ${downloadAttempt.details}'
        : 'API ${apiAttempt.details}; redirect ${redirectAttempt.details}; download ${downloadAttempt.details}';

    return ZapretProbeResult(
      target: target,
      success: success,
      latencyMs: success ? latencyMs : null,
      details: details,
    );
  }

  Future<_HttpProbeAttempt> _probeHttp({
    required DioHttpClient client,
    required String url,
    required HttpProbeMethod method,
    required Set<int> expectedStatuses,
    String? bodyContains,
    String? locationContains,
    String? successLabel,
    bool followRedirects = true,
    int maxRedirects = 5,
  }) async {
    const maxAttempts = 2;
    const probeTimeout = Duration(seconds: 4);
    const retryDelay = Duration(milliseconds: 350);

    _HttpProbeAttempt? lastFailure;

    for (var attempt = 1; attempt <= maxAttempts; attempt += 1) {
      final response = await client.probeHttp(
        url,
        method: method,
        requestMode: NetworkRequestMode.direct,
        timeout: probeTimeout,
        followRedirects: followRedirects,
        maxRedirects: maxRedirects,
      );
      if (response != null &&
          _isValidHttpResponse(
            response,
            expectedStatuses: expectedStatuses,
            bodyContains: bodyContains,
            locationContains: locationContains,
          )) {
        return _HttpProbeAttempt(
          success: true,
          latencyMs: response.latencyMs,
          details:
              successLabel ??
              '${_httpMethodLabel(method)} ${response.statusCode} • attempt $attempt/$maxAttempts',
        );
      }

      lastFailure = _HttpProbeAttempt(
        success: false,
        details: _buildHttpFailureDetails(
          method: method,
          url: url,
          response: response,
          expectedStatuses: expectedStatuses,
          bodyContains: bodyContains,
          locationContains: locationContains,
          effectiveUrlContains: null,
          attempt: attempt,
          maxAttempts: maxAttempts,
        ),
      );

      if (attempt < maxAttempts) {
        await Future.delayed(retryDelay);
      }
    }

    return lastFailure ??
        _HttpProbeAttempt(
          success: false,
          details:
              '${_httpMethodLabel(method)} timeout/fail after $maxAttempts attempts',
        );
  }

  Future<_HttpProbeAttempt> _probeDownload({
    required DioHttpClient client,
    required String url,
    required Set<int> expectedStatuses,
    String? effectiveUrlContains,
    String? successLabel,
  }) async {
    const maxAttempts = 2;
    const probeTimeout = Duration(seconds: 6);
    const retryDelay = Duration(milliseconds: 350);

    _HttpProbeAttempt? lastFailure;

    for (var attempt = 1; attempt <= maxAttempts; attempt += 1) {
      final response = await client.probeDownload(
        url,
        requestMode: NetworkRequestMode.direct,
        timeout: probeTimeout,
        headers: const {
          'User-Agent': _discordDownloadUserAgent,
          'Accept': 'application/octet-stream',
          'Range': 'bytes=0-0',
        },
      );
      if (response != null &&
          _isValidHttpResponse(
            response,
            expectedStatuses: expectedStatuses,
            effectiveUrlContains: effectiveUrlContains,
          )) {
        return _HttpProbeAttempt(
          success: true,
          latencyMs: response.latencyMs,
          details:
              successLabel ??
              'GET ${response.statusCode} • attempt $attempt/$maxAttempts',
        );
      }

      lastFailure = _HttpProbeAttempt(
        success: false,
        details: _buildHttpFailureDetails(
          method: HttpProbeMethod.get,
          url: url,
          response: response,
          expectedStatuses: expectedStatuses,
          bodyContains: null,
          locationContains: null,
          effectiveUrlContains: effectiveUrlContains,
          attempt: attempt,
          maxAttempts: maxAttempts,
        ),
      );

      if (attempt < maxAttempts) {
        await Future.delayed(retryDelay);
      }
    }

    return lastFailure ??
        _HttpProbeAttempt(
          success: false,
          details: 'GET download timeout/fail after $maxAttempts attempts',
        );
  }

  bool _isValidHttpResponse(
    HttpProbeResponse response, {
    required Set<int> expectedStatuses,
    String? bodyContains,
    String? locationContains,
    String? effectiveUrlContains,
  }) {
    final statusCode = response.statusCode;
    final statusOk =
        statusCode != null && expectedStatuses.contains(statusCode);
    final bodyOk =
        bodyContains == null ||
        (response.body?.toLowerCase().contains(bodyContains.toLowerCase()) ??
            false);
    final locationOk =
        locationContains == null ||
        (response.location?.toLowerCase().contains(
              locationContains.toLowerCase(),
            ) ??
            false);
    final effectiveUrlOk =
        effectiveUrlContains == null ||
        (response.effectiveUrl?.toLowerCase().contains(
              effectiveUrlContains.toLowerCase(),
            ) ??
            false);
    return statusOk && bodyOk && locationOk && effectiveUrlOk;
  }

  String _buildHttpFailureDetails({
    required HttpProbeMethod method,
    required String url,
    required HttpProbeResponse? response,
    required Set<int> expectedStatuses,
    required int attempt,
    required int maxAttempts,
    String? bodyContains,
    String? locationContains,
    String? effectiveUrlContains,
  }) {
    if (response == null) {
      return '${_httpMethodLabel(method)} no response • attempt $attempt/$maxAttempts';
    }

    final issues = <String>[];
    final statusCode = response.statusCode;
    if (statusCode == null || !expectedStatuses.contains(statusCode)) {
      issues.add(
        'status ${statusCode ?? 'none'} expected ${expectedStatuses.join('/')}',
      );
    }
    if (bodyContains != null &&
        !(response.body?.toLowerCase().contains(bodyContains.toLowerCase()) ??
            false)) {
      issues.add('body missing $bodyContains');
    }
    if (locationContains != null &&
        !(response.location?.toLowerCase().contains(
              locationContains.toLowerCase(),
            ) ??
            false)) {
      issues.add('location mismatch');
    }
    if (effectiveUrlContains != null &&
        !(response.effectiveUrl?.toLowerCase().contains(
              effectiveUrlContains.toLowerCase(),
            ) ??
            false)) {
      issues.add('effective url mismatch');
    }
    return '${_httpMethodLabel(method)} ${issues.join(', ')} • attempt $attempt/$maxAttempts';
  }

  int? _combinedLatency(int? left, int? right) {
    if (left == null) {
      return right;
    }
    if (right == null) {
      return left;
    }
    return left > right ? left : right;
  }

  String _httpMethodLabel(HttpProbeMethod method) {
    return method == HttpProbeMethod.head ? 'HEAD' : 'GET';
  }

  Future<ZapretProbeResult> _runPingProbe(ZapretProbeTarget target) async {
    if (!Platform.isWindows) {
      return ZapretProbeResult(
        target: target,
        success: false,
        details: 'Ping probes are only enabled on Windows.',
      );
    }

    try {
      final result = await Process.run('ping', [
        '-n',
        '1',
        '-w',
        '1500',
        target.address,
      ]);
      final stdout = result.stdout?.toString() ?? '';
      final stderr = result.stderr?.toString() ?? '';
      final latency = _parsePingLatency('$stdout\n$stderr');
      return ZapretProbeResult(
        target: target,
        success: result.exitCode == 0,
        latencyMs: latency,
        details: result.exitCode == 0 ? 'ICMP reply' : 'ICMP fail',
      );
    } on Object catch (error) {
      return ZapretProbeResult(
        target: target,
        success: false,
        details: 'Ping error: $error',
      );
    }
  }

  int? _parsePingLatency(String output) {
    final regex = RegExp(
      r'(?:time|время)[=<]?\s*(\d+)\s*(?:ms|мс)',
      caseSensitive: false,
    );
    final match = regex.firstMatch(output);
    return match == null ? null : int.tryParse(match.group(1) ?? '');
  }
}

class _HttpProbeAttempt {
  const _HttpProbeAttempt({
    required this.success,
    required this.details,
    this.latencyMs,
  });

  final bool success;
  final String details;
  final int? latencyMs;
}
