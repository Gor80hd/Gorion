import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum NetworkRequestMode { auto, proxy, direct }

enum HttpProbeMethod { head, get }

class HttpProbeResponse {
  const HttpProbeResponse({
    required this.statusCode,
    required this.latencyMs,
    this.location,
    this.effectiveUrl,
    this.body,
  });

  final int? statusCode;
  final int latencyMs;
  final String? location;
  final String? effectiveUrl;
  final String? body;
}

class DioHttpClient {
  DioHttpClient({
    required Duration timeout,
    required this.userAgent,
    bool debug = false,
  }) : _timeout = timeout;

  final Duration _timeout;
  final String userAgent;
  int _proxyPort = 0;

  void setProxyPort(int port) => _proxyPort = port;

  Dio _buildDio({required bool useProxy}) {
    final dio = Dio(
      BaseOptions(
        connectTimeout: _timeout,
        sendTimeout: _timeout,
        receiveTimeout: _timeout,
        headers: {'User-Agent': userAgent},
      ),
    );

    if (useProxy && _proxyPort > 0) {
      dio.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () {
          final client = HttpClient();
          final port = _proxyPort;
          client.findProxy = (_) => 'PROXY 127.0.0.1:$port';
          client.badCertificateCallback = (certificate, host, port) => true;
          return client;
        },
      );
    }

    return dio;
  }

  Future<int> pingTest(
    String url, {
    NetworkRequestMode requestMode = NetworkRequestMode.auto,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final response = await probeHttp(
      url,
      method: HttpProbeMethod.head,
      requestMode: requestMode,
      timeout: timeout,
    );
    return response?.latencyMs ?? -1;
  }

  Future<HttpProbeResponse?> probeHttp(
    String url, {
    HttpProbeMethod method = HttpProbeMethod.head,
    NetworkRequestMode requestMode = NetworkRequestMode.auto,
    Duration timeout = const Duration(seconds: 10),
    bool followRedirects = true,
    int maxRedirects = 5,
    Map<String, String>? headers,
  }) async {
    final useProxy = requestMode == NetworkRequestMode.proxy;
    final dio = _buildDio(useProxy: useProxy);
    try {
      final start = DateTime.now();
      final response = await dio.request<String>(
        url,
        options: Options(
          method: method == HttpProbeMethod.head ? 'HEAD' : 'GET',
          responseType: ResponseType.plain,
          receiveTimeout: timeout,
          sendTimeout: timeout,
          followRedirects: followRedirects,
          maxRedirects: maxRedirects,
          validateStatus: (_) => true,
          headers: headers,
        ),
      );
      return HttpProbeResponse(
        statusCode: response.statusCode,
        latencyMs: DateTime.now().difference(start).inMilliseconds,
        location: response.headers.value('location'),
        effectiveUrl: response.realUri.toString(),
        body: response.data,
      );
    } catch (_) {
      return null;
    } finally {
      dio.close(force: true);
    }
  }

  Future<HttpProbeResponse?> probeDownload(
    String url, {
    NetworkRequestMode requestMode = NetworkRequestMode.auto,
    Duration timeout = const Duration(seconds: 10),
    bool followRedirects = true,
    int maxRedirects = 5,
    int readBytes = 1024,
    Map<String, String>? headers,
  }) async {
    final useProxy = requestMode == NetworkRequestMode.proxy;
    final dio = _buildDio(useProxy: useProxy);
    try {
      final start = DateTime.now();
      final response = await dio.get<ResponseBody>(
        url,
        options: Options(
          responseType: ResponseType.stream,
          receiveTimeout: timeout,
          sendTimeout: timeout,
          followRedirects: followRedirects,
          maxRedirects: maxRedirects,
          validateStatus: (_) => true,
          headers: headers,
        ),
      );

      var receivedBytes = 0;
      if (response.data case final responseBody?) {
        await for (final chunk in responseBody.stream) {
          receivedBytes += chunk.length;
          if (receivedBytes >= readBytes) {
            break;
          }
        }
      }

      return HttpProbeResponse(
        statusCode: response.statusCode,
        latencyMs: DateTime.now().difference(start).inMilliseconds,
        location: response.headers.value('location'),
        effectiveUrl: response.realUri.toString(),
        body: receivedBytes > 0 ? 'bytes=$receivedBytes' : null,
      );
    } catch (_) {
      return null;
    } finally {
      dio.close(force: true);
    }
  }

  Future<int> benchmarkDownload(
    String url, {
    NetworkRequestMode requestMode = NetworkRequestMode.auto,
    int maxBytes = 2 * 1024 * 1024,
    Duration maxDuration = const Duration(seconds: 10),
    void Function(int bytes)? onProgress,
  }) async {
    final useProxy = requestMode == NetworkRequestMode.proxy;
    final dio = _buildDio(useProxy: useProxy);
    try {
      var received = 0;
      final start = DateTime.now();
      await dio
          .get<ResponseBody>(
            url,
            options: Options(responseType: ResponseType.stream),
          )
          .then((response) async {
            await for (final chunk in response.data!.stream) {
              received += chunk.length;
              onProgress?.call(received);
              final elapsed = DateTime.now().difference(start);
              if (received >= maxBytes || elapsed >= maxDuration) break;
            }
          });
      final elapsed = DateTime.now().difference(start);
      if (elapsed.inMilliseconds <= 0) return 0;
      return (received / elapsed.inMilliseconds * 1000).round();
    } catch (_) {
      return 0;
    } finally {
      dio.close(force: true);
    }
  }
}

class _HttpClientState {
  const _HttpClientState({required this.userAgent});
  final String userAgent;
}

final httpClientProvider = Provider<_HttpClientState>((ref) {
  return const _HttpClientState(userAgent: 'Gorion/1.0');
});
