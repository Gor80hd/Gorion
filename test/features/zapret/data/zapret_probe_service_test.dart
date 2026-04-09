import 'package:flutter_test/flutter_test.dart';
import 'package:gorion_clean/core/http_client/http_client_provider.dart';
import 'package:gorion_clean/features/zapret/data/zapret_probe_service.dart';

void main() {
  test('discord probe validates both API and update endpoints', () async {
    final service = ZapretProbeService(
      httpClient: _FakeDioHttpClient(
        probeHandler: (url, method, _, __, ___) {
          if (url == 'https://discord.com/api/v9/experiments' &&
              method == HttpProbeMethod.get) {
            return const HttpProbeResponse(
              statusCode: 200,
              latencyMs: 716,
              body: '{"fingerprint":"abc"}',
            );
          }
          if (url ==
                  'https://discord.com/api/download?platform=win&format=exe' &&
              method == HttpProbeMethod.head) {
            return const HttpProbeResponse(
              statusCode: 302,
              latencyMs: 245,
              location:
                  'https://stable.dl2.discordapp.net/apps/win/0.0.311/Discord.exe',
            );
          }
          return null;
        },
        downloadHandler: (url, _, __, ___) {
          if (url ==
              'https://discord.com/api/download?platform=win&format=exe') {
            return const HttpProbeResponse(
              statusCode: 206,
              latencyMs: 512,
              effectiveUrl:
                  'https://stable.dl2.discordapp.net/apps/win/0.0.311/Discord.exe',
              body: 'bytes=1',
            );
          }
          return null;
        },
      ),
    );

    final target = ZapretProbeService.defaultTargets.firstWhere(
      (item) => item.id == 'discord',
    );
    final report = await service.runProbes(targets: [target]);
    final result = report.results.single;

    expect(result.success, isTrue);
    expect(result.latencyMs, 716);
    expect(result.details, contains('GET experiments 200'));
    expect(result.details, contains('HEAD update redirect 302'));
    expect(result.details, contains('GET installer bytes'));
  });

  test('generate_204 probes reject non-204 responses', () async {
    final service = ZapretProbeService(
      httpClient: _FakeDioHttpClient((url, method, _, __) {
        if (method == HttpProbeMethod.head) {
          return const HttpProbeResponse(statusCode: 200, latencyMs: 88);
        }
        return null;
      }),
    );

    final target = ZapretProbeService.defaultTargets.firstWhere(
      (item) => item.id == 'google',
    );
    final report = await service.runProbes(targets: [target]);
    final result = report.results.single;

    expect(result.success, isFalse);
    expect(result.details, contains('status 200 expected 204'));
  });
}

typedef _ProbeHandler =
    HttpProbeResponse? Function(
      String url,
      HttpProbeMethod method,
      Map<String, String>? headers,
      bool followRedirects,
      int maxRedirects,
    );

typedef _DownloadProbeHandler =
    HttpProbeResponse? Function(
      String url,
      Map<String, String>? headers,
      bool followRedirects,
      int maxRedirects,
    );

class _FakeDioHttpClient extends DioHttpClient {
  _FakeDioHttpClient({required this.probeHandler, this.downloadHandler})
    : super(timeout: const Duration(seconds: 1), userAgent: 'test');

  final _ProbeHandler probeHandler;
  final _DownloadProbeHandler? downloadHandler;

  @override
  Future<HttpProbeResponse?> probeHttp(
    String url, {
    HttpProbeMethod method = HttpProbeMethod.head,
    NetworkRequestMode requestMode = NetworkRequestMode.auto,
    Duration timeout = const Duration(seconds: 10),
    bool followRedirects = true,
    int maxRedirects = 5,
    Map<String, String>? headers,
  }) async {
    return probeHandler(url, method, headers, followRedirects, maxRedirects);
  }

  @override
  Future<HttpProbeResponse?> probeDownload(
    String url, {
    NetworkRequestMode requestMode = NetworkRequestMode.auto,
    Duration timeout = const Duration(seconds: 10),
    bool followRedirects = true,
    int maxRedirects = 5,
    int readBytes = 1024,
    Map<String, String>? headers,
  }) async {
    return downloadHandler?.call(url, headers, followRedirects, maxRedirects);
  }
}
