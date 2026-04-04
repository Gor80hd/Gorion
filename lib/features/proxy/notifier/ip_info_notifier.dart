import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gorion_clean/core/http_client/http_client_provider.dart';
import 'package:gorion_clean/features/home/application/dashboard_controller.dart';
import 'package:gorion_clean/features/proxy/model/ip_info_entity.dart';
import 'package:gorion_clean/features/runtime/model/runtime_models.dart';

final ipInfoNotifierProvider = FutureProvider<IpInfo>((ref) async {
  final (stage, proxyPort) = ref.watch(
    dashboardControllerProvider.select(
      (state) => (state.connectionStage, state.runtimeSession?.mixedPort),
    ),
  );
  if (stage != ConnectionStage.connected || proxyPort == null || proxyPort <= 0) {
    throw StateError('Proxy IP info not available');
  }

  final userAgent = ref.watch(httpClientProvider).userAgent;
  return _lookupIpInfo(
    userAgent: userAgent,
    mode: _IpLookupMode.proxy,
    proxyPort: proxyPort,
  );
});

final directIpInfoNotifierProvider = FutureProvider<IpInfo>((ref) async {
  ref.watch(
    dashboardControllerProvider.select(
      (state) => (
        state.connectionStage,
        state.runtimeMode,
        state.runtimeSession?.mixedPort,
      ),
    ),
  );

  final userAgent = ref.watch(httpClientProvider).userAgent;
  return _lookupIpInfo(userAgent: userAgent, mode: _IpLookupMode.direct);
});

enum _IpLookupMode { direct, proxy }

typedef _IpInfoParser = IpInfo? Function(Object? data);

class _IpInfoEndpoint {
  const _IpInfoEndpoint({required this.url, required this.parser});

  final String url;
  final _IpInfoParser parser;
}

const _ipInfoEndpoints = <_IpInfoEndpoint>[
  _IpInfoEndpoint(url: 'https://api.ip.sb/geoip', parser: _parseIpSbInfo),
  _IpInfoEndpoint(url: 'https://ipwho.is/', parser: _parseIpWhoIsInfo),
];

Future<IpInfo> _lookupIpInfo({
  required String userAgent,
  required _IpLookupMode mode,
  int? proxyPort,
}) async {
  final dio = _buildDio(
    userAgent: userAgent,
    mode: mode,
    proxyPort: proxyPort,
  );

  try {
    for (final endpoint in _ipInfoEndpoints) {
      try {
        final response = await dio.get<Object>(
          endpoint.url,
          options: Options(
            responseType: ResponseType.json,
            validateStatus: (status) => status != null && status >= 200 && status < 500,
          ),
        );
        final parsed = endpoint.parser(response.data);
        if (parsed != null) {
          return parsed;
        }
      } on Object {
        continue;
      }
    }
  } finally {
    dio.close(force: true);
  }

  throw StateError('IP info not available');
}

Dio _buildDio({
  required String userAgent,
  required _IpLookupMode mode,
  int? proxyPort,
}) {
  final dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 4),
      sendTimeout: const Duration(seconds: 4),
      receiveTimeout: const Duration(seconds: 4),
      headers: {'User-Agent': userAgent},
    ),
  );

  dio.httpClientAdapter = IOHttpClientAdapter(
    createHttpClient: () {
      final client = HttpClient();
      client.findProxy = (_) {
        return switch (mode) {
          _IpLookupMode.direct => 'DIRECT',
          _IpLookupMode.proxy when proxyPort != null && proxyPort > 0 =>
            'PROXY 127.0.0.1:$proxyPort',
          _IpLookupMode.proxy => 'DIRECT',
        };
      };
      return client;
    },
  );

  return dio;
}

IpInfo? _parseIpSbInfo(Object? data) {
  final map = _asJsonMap(data);
  if (map == null) {
    return null;
  }

  return _buildIpInfo(
    ip: _readString(map, const ['ip', 'query']),
    countryCode: _readString(map, const ['country_code', 'countryCode']),
    region: _readString(map, const ['region', 'region_name', 'regionName']),
    city: _readString(map, const ['city']),
    timezone: _readTimezone(map['timezone']),
    asn: _readString(map, const ['asn']),
    org: _readString(map, const ['organization', 'org', 'isp']),
  );
}

IpInfo? _parseIpWhoIsInfo(Object? data) {
  final map = _asJsonMap(data);
  if (map == null) {
    return null;
  }

  final success = map['success'];
  if (success is bool && !success) {
    return null;
  }

  final connection = _asJsonMap(map['connection']);
  final timezone = _asJsonMap(map['timezone']);

  return _buildIpInfo(
    ip: _readString(map, const ['ip']),
    countryCode: _readString(map, const ['country_code', 'countryCode']),
    region: _readString(map, const ['region']),
    city: _readString(map, const ['city']),
    timezone: _readString(timezone, const ['id']) ?? _readString(map, const ['timezone']),
    asn: _readString(connection, const ['asn']) ?? _readString(map, const ['asn']),
    org: _readString(connection, const ['org', 'isp']) ??
        _readString(map, const ['connection', 'organization']),
  );
}

IpInfo? _buildIpInfo({
  required String? ip,
  required String? countryCode,
  String? region,
  String? city,
  String? timezone,
  String? asn,
  String? org,
}) {
  if (ip == null || ip.isEmpty || countryCode == null || countryCode.isEmpty) {
    return null;
  }

  return IpInfo(
    ip: ip,
    countryCode: countryCode,
    region: region,
    city: city,
    timezone: timezone,
    asn: asn,
    org: org,
  );
}

Map<String, dynamic>? _asJsonMap(Object? data) {
  if (data is Map) {
    return data.map((key, value) => MapEntry(key.toString(), value));
  }
  if (data is String && data.trim().isNotEmpty) {
    try {
      final decoded = jsonDecode(data);
      if (decoded is Map) {
        return decoded.map((key, value) => MapEntry(key.toString(), value));
      }
    } on FormatException {
      return null;
    }
  }
  return null;
}

String? _readString(Map<String, dynamic>? map, List<String> keys) {
  if (map == null) {
    return null;
  }
  for (final key in keys) {
    final value = map[key]?.toString().trim();
    if (value != null && value.isNotEmpty && value.toLowerCase() != 'null') {
      return value;
    }
  }
  return null;
}

String? _readTimezone(Object? value) {
  if (value is String) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
  if (value is Map) {
    return _readString(
      value.map((key, item) => MapEntry(key.toString(), item)),
      const ['id'],
    );
  }
  return null;
}
