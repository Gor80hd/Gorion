import 'dart:convert';
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:gorion_clean/features/runtime/model/runtime_models.dart';

class ClashApiSnapshot {
  const ClashApiSnapshot({required this.selectedTag, required this.delayByTag});

  final String? selectedTag;
  final Map<String, int> delayByTag;
}

class ClashApiClient {
  ClashApiClient({required this.baseUrl, required this.secret, Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: baseUrl,
              connectTimeout: const Duration(seconds: 3),
              receiveTimeout: const Duration(seconds: 8),
              headers: {'Authorization': 'Bearer $secret'},
            ),
          );

  factory ClashApiClient.fromSession(RuntimeSession session) {
    return ClashApiClient(
      baseUrl: session.controllerBaseUrl,
      secret: session.secret,
    );
  }

  final String baseUrl;
  final String secret;
  final Dio _dio;

  Future<void> waitUntilReady({
    Duration timeout = const Duration(seconds: 12),
    void Function(String message)? onLog,
    String? Function()? abortReason,
  }) async {
    final startedAt = DateTime.now();
    var attempt = 0;
    DioException? lastError;
    while (DateTime.now().difference(startedAt) < timeout) {
      final earlyAbort = abortReason?.call();
      if (earlyAbort != null) {
        throw Exception(earlyAbort);
      }

      attempt += 1;
      try {
        onLog?.call('Clash API probe #$attempt -> GET $baseUrl/version');
        await _dio.get<dynamic>('/version');
        onLog?.call('Clash API became ready on probe #$attempt.');
        return;
      } on DioException catch (error) {
        lastError = error;
        onLog?.call(
          'Clash API probe #$attempt failed: ${_describeDioException(error)}',
        );

        final abortAfterFailure = abortReason?.call();
        if (abortAfterFailure != null) {
          throw Exception(abortAfterFailure);
        }

        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }

    final details = lastError == null
        ? ''
        : ' Last error: ${_describeDioException(lastError)}';
    throw TimeoutException(
      'The local sing-box controller did not become ready in time.$details',
    );
  }

  String _describeDioException(DioException error) {
    final parts = <String>[error.type.name];
    final statusCode = error.response?.statusCode;
    if (statusCode != null) {
      parts.add('status=$statusCode');
    }

    final message = error.message?.trim();
    if (message != null && message.isNotEmpty) {
      parts.add(message);
    }

    return parts.join(', ');
  }

  Future<ClashApiSnapshot> fetchSnapshot({required String selectorTag}) async {
    final body = await _getJsonMap('/proxies');
    final rawProxies = body['proxies'];
    if (rawProxies is! Map) {
      return const ClashApiSnapshot(selectedTag: null, delayByTag: {});
    }

    final proxies = _asStringKeyedMap(rawProxies) ?? const <String, dynamic>{};
    String? selectedTag;
    final delays = <String, int>{};

    for (final entry in proxies.entries) {
      final map = _asStringKeyedMap(entry.value);
      if (map == null) {
        continue;
      }

      if (entry.key == selectorTag) {
        final now = map['now']?.toString().trim();
        if (now != null && now.isNotEmpty) {
          selectedTag = now;
        }
      }

      final history = map['history'];
      if (history is List && history.isNotEmpty) {
        final first = history.first;
        if (first is Map && first['delay'] is num) {
          delays[entry.key] = (first['delay'] as num).toInt();
        }
      }
    }

    return ClashApiSnapshot(selectedTag: selectedTag, delayByTag: delays);
  }

  Future<void> selectProxy({
    required String selectorTag,
    required String serverTag,
  }) async {
    await _dio.put<void>(
      '/proxies/${Uri.encodeComponent(selectorTag)}',
      data: {'name': serverTag},
    );
  }

  Future<Map<String, int>> measureGroupDelay({
    required String groupTag,
    required String testUrl,
    int timeoutMs = 8000,
  }) async {
    final body = await _getJsonMap(
      '/group/${Uri.encodeComponent(groupTag)}/delay',
      queryParameters: {'url': testUrl, 'timeout': timeoutMs},
    );

    final delays = <String, int>{};
    for (final entry in body.entries) {
      if (entry.value is num) {
        delays[entry.key] = (entry.value as num).toInt();
      }
    }
    return delays;
  }

  Future<Map<String, dynamic>> _getJsonMap(
    String path, {
    Map<String, dynamic>? queryParameters,
  }) async {
    final response = await _dio.get<dynamic>(
      path,
      queryParameters: queryParameters,
      options: Options(responseType: ResponseType.plain),
    );
    return _decodeJsonMap(response.data);
  }

  Map<String, dynamic> _decodeJsonMap(dynamic data) {
    if (data == null) {
      return <String, dynamic>{};
    }

    if (data is String) {
      final trimmed = data.trim();
      if (trimmed.isEmpty) {
        return <String, dynamic>{};
      }

      return _decodeJsonMap(jsonDecode(trimmed));
    }

    if (data is List<int>) {
      return _decodeJsonMap(utf8.decode(data));
    }

    final map = _asStringKeyedMap(data);
    if (map != null) {
      return map;
    }

    throw FormatException(
      'Expected a JSON object from Clash API, received ${data.runtimeType}.',
    );
  }

  Map<String, dynamic>? _asStringKeyedMap(dynamic value) {
    if (value is Map<String, dynamic>) {
      return Map<String, dynamic>.from(value);
    }
    if (value is Map) {
      return Map<String, dynamic>.from(value.cast<String, dynamic>());
    }
    return null;
  }
}
