import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum NetworkRequestMode { auto, proxy, direct }

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
          client.badCertificateCallback = (_, __, ___) => true;
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
    final useProxy = requestMode == NetworkRequestMode.proxy;
    final dio = _buildDio(useProxy: useProxy);
    try {
      final start = DateTime.now();
      await dio.head<void>(
        url,
        options: Options(
          receiveTimeout: timeout,
          sendTimeout: timeout,
          validateStatus: (_) => true,
        ),
      );
      return DateTime.now().difference(start).inMilliseconds;
    } catch (_) {
      return -1;
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
      await dio.get<ResponseBody>(
        url,
        options: Options(responseType: ResponseType.stream),
      ).then((response) async {
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
