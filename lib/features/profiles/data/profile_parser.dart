import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:gorion_clean/features/auto_select/utils/auto_select_server_config.dart';
import 'package:gorion_clean/features/profiles/model/profile_models.dart';
import 'package:gorion_clean/utils/server_display_text.dart';

const _trueBooleanValues = {'1', 'true', 'yes', 'on'};
const _falseBooleanValues = {'0', 'false', 'no', 'off'};

class ProfileParser {
  ProfileParser({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              followRedirects: true,
              responseType: ResponseType.bytes,
              receiveTimeout: const Duration(seconds: 20),
              sendTimeout: const Duration(seconds: 20),
              headers: const {'user-agent': 'Gorion/1.0', 'accept': '*/*'},
            ),
          );

  final Dio _dio;

  Future<ParsedSubscription> fetchAndParse(String url) async {
    final source = Uri.parse(url.trim());
    if (!source.hasScheme || source.host.isEmpty) {
      throw const FormatException('Subscription URL must be absolute.');
    }

    final response = await _dio.get<List<int>>(source.toString());
    final headers = _flattenHeaders(response.headers.map);
    final rawContent = _decodeResponseBody(response.data ?? const []);

    return parseContent(
      rawContent: rawContent,
      source: source,
      headers: headers,
    );
  }

  ParsedSubscription parseContent({
    required String rawContent,
    required Uri source,
    Map<String, String> headers = const {},
  }) {
    final config = _decodeSubscriptionConfig(rawContent);
    if (config == null) {
      throw const FormatException(
        'Only sing-box JSON configs or base64/plain remote subscriptions with share links are supported right now.',
      );
    }

    final configJson = jsonEncode(config);
    final candidates = extractAutoSelectConfigCandidates(configJson);
    if (candidates.isEmpty) {
      throw const FormatException(
        'No selectable servers were found in this subscription.',
      );
    }

    final servers = [
      for (final candidate in candidates)
        ServerEntry(
          tag: candidate.tag,
          displayName: _beautifyServerName(candidate.tag),
          type: candidate.type,
          host: candidate.host,
          port: candidate.port,
          configFingerprint: candidate.configFingerprint,
        ),
    ];

    return ParsedSubscription(
      name: _resolveProfileName(
        headers: headers,
        source: source,
        fallback: servers.first.displayName,
      ),
      normalizedConfigJson: configJson,
      servers: servers,
      subscriptionInfo: _parseSubscriptionInfo(headers),
    );
  }

  static Map<String, String> _flattenHeaders(
    Map<String, List<String>> rawHeaders,
  ) {
    final headers = <String, String>{};
    for (final entry in rawHeaders.entries) {
      if (entry.value.isEmpty) {
        continue;
      }
      headers[entry.key.toLowerCase()] = entry.value.first;
    }
    return headers;
  }

  static String _decodeResponseBody(List<int> bytes) {
    try {
      return utf8.decode(bytes).trim();
    } on FormatException {
      final utf8Text = utf8.decode(bytes, allowMalformed: true).trim();
      final latin1Text = latin1.decode(bytes).trim();
      if (utf8Text.isEmpty) {
        return latin1Text;
      }
      if (latin1Text.isEmpty) {
        return utf8Text;
      }
      if (_utf8MojibakeScore(latin1Text) > 0) {
        return utf8Text;
      }
      if (_replacementCharacterCount(utf8Text) > 0) {
        return latin1Text;
      }
      return utf8Text;
    }
  }

  static String decodeResponseBodyForTesting(List<int> bytes) {
    return _decodeResponseBody(bytes);
  }

  static Map<String, dynamic>? _decodeSubscriptionConfig(String rawContent) {
    final trimmed = rawContent.replaceFirst('\uFEFF', '').trim();
    if (trimmed.isEmpty) {
      return null;
    }

    final directConfig = _decodeConfig(trimmed);
    if (directConfig != null) {
      return directConfig;
    }

    final directOutbounds = _parseRemoteOutbounds(trimmed);
    if (directOutbounds.isNotEmpty) {
      return {'outbounds': directOutbounds};
    }

    final decodedBase64 = _tryDecodeBase64(trimmed);
    if (decodedBase64 == null) {
      return null;
    }

    final decodedConfig = _decodeConfig(decodedBase64);
    if (decodedConfig != null) {
      return decodedConfig;
    }

    final decodedOutbounds = _parseRemoteOutbounds(decodedBase64);
    if (decodedOutbounds.isNotEmpty) {
      return {'outbounds': decodedOutbounds};
    }

    return null;
  }

  static Map<String, dynamic>? _decodeConfig(String content) {
    final direct = _tryDecodeJsonObject(content);
    if (direct != null) {
      return direct;
    }

    final firstBrace = content.indexOf('{');
    final lastBrace = content.lastIndexOf('}');
    if (firstBrace >= 0 && lastBrace > firstBrace) {
      return _tryDecodeJsonObject(content.substring(firstBrace, lastBrace + 1));
    }
    return null;
  }

  static Map<String, dynamic>? _tryDecodeJsonObject(String content) {
    try {
      final decoded = jsonDecode(content);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded.cast<String, dynamic>());
      }
    } catch (_) {}
    return null;
  }

  static List<Map<String, dynamic>> _parseRemoteOutbounds(String content) {
    final outbounds = <Map<String, dynamic>>[];
    final tagCounts = <String, int>{};

    for (final rawLine in const LineSplitter().convert(content)) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#') || line.startsWith('//')) {
        continue;
      }

      final outbound = _parseRemoteOutboundLine(line);
      if (outbound == null) {
        continue;
      }

      final originalTag = outbound['tag']?.toString().trim() ?? '';
      final baseTag = originalTag.isEmpty
          ? _fallbackOutboundTag(outbound)
          : originalTag;
      outbound['tag'] = _ensureUniqueTag(baseTag, tagCounts);
      outbounds.add(outbound);
    }

    return outbounds;
  }

  static Map<String, dynamic>? _parseRemoteOutboundLine(String line) {
    final match = RegExp(
      r'^([A-Za-z][A-Za-z0-9+.-]*):\/\/',
      caseSensitive: false,
    ).firstMatch(line);
    if (match == null) {
      return null;
    }

    switch (match.group(1)?.toLowerCase()) {
      case 'vless':
        return _parseVlessOutbound(line);
      case 'vmess':
        return _parseVmessOutbound(line);
      case 'trojan':
        return _parseTrojanOutbound(line);
      case 'ss':
      case 'shadowsocks':
        return _parseShadowsocksOutbound(line);
    }

    return null;
  }

  static Map<String, dynamic>? _parseVlessOutbound(String line) {
    final uri = _tryParseShareUri(line);
    if (uri == null) {
      return null;
    }

    final outbound = _buildCredentialOutbound(
      type: 'vless',
      uri: uri,
      credentialKey: 'uuid',
    );
    if (outbound == null) {
      return null;
    }

    final query = _queryParameters(uri);
    final flow = _firstNonEmpty(query, const ['flow']);
    if (flow != null) {
      outbound['flow'] = flow;
    }

    final packetEncoding = _firstNonEmpty(query, const [
      'packetencoding',
      'packet-encoding',
    ]);
    if (packetEncoding != null) {
      outbound['packet_encoding'] = packetEncoding;
    }

    final security = (_firstNonEmpty(query, const ['security']) ?? '')
        .toLowerCase();
    final tls = _buildTlsConfig(query);
    if (security == 'reality' && tls == null) {
      return null;
    }
    if (tls != null) {
      outbound['tls'] = tls;
    }

    final transport = _buildTransportConfigFromValues(
      transportType: _firstNonEmpty(query, const ['type']) ?? 'tcp',
      headerType: _firstNonEmpty(query, const ['headertype']),
      hostValue: _firstNonEmpty(query, const ['host']),
      pathValue: _firstNonEmpty(query, const ['path']),
      serviceName: _firstNonEmpty(query, const ['servicename', 'service-name']),
      maxEarlyData: _firstNonEmpty(query, const ['ed', 'maxearlydata']),
      earlyDataHeaderName: _firstNonEmpty(query, const [
        'eh',
        'earlydataheadername',
      ]),
    );
    if (transport != null) {
      outbound['transport'] = transport;
    }

    return outbound;
  }

  static Map<String, dynamic>? _parseTrojanOutbound(String line) {
    final uri = _tryParseShareUri(line);
    if (uri == null) {
      return null;
    }

    final outbound = _buildCredentialOutbound(
      type: 'trojan',
      uri: uri,
      credentialKey: 'password',
    );
    if (outbound == null) {
      return null;
    }

    final query = _queryParameters(uri);
    final tls = _buildTlsConfig(query, forceEnabled: true);
    if (tls != null) {
      outbound['tls'] = tls;
    }

    final transport = _buildTransportConfigFromValues(
      transportType: _firstNonEmpty(query, const ['type']) ?? 'tcp',
      headerType: _firstNonEmpty(query, const ['headertype']),
      hostValue: _firstNonEmpty(query, const ['host']),
      pathValue: _firstNonEmpty(query, const ['path']),
      serviceName: _firstNonEmpty(query, const ['servicename', 'service-name']),
      maxEarlyData: _firstNonEmpty(query, const ['ed', 'maxearlydata']),
      earlyDataHeaderName: _firstNonEmpty(query, const [
        'eh',
        'earlydataheadername',
      ]),
    );
    if (transport != null) {
      outbound['transport'] = transport;
    }

    return outbound;
  }

  static Map<String, dynamic>? _parseVmessOutbound(String line) {
    final encodedBody = line.substring('vmess://'.length).trim();
    final decodedBody = _tryDecodeBase64(encodedBody);
    if (decodedBody != null) {
      final decodedJson = _tryDecodeJsonObject(decodedBody);
      if (decodedJson != null) {
        return _parseVmessJsonOutbound(decodedJson);
      }
    }

    final uri = _tryParseShareUri(line);
    if (uri == null) {
      return null;
    }

    final outbound = _buildCredentialOutbound(
      type: 'vmess',
      uri: uri,
      credentialKey: 'uuid',
    );
    if (outbound == null) {
      return null;
    }

    final query = _queryParameters(uri);
    outbound['security'] = _resolveVmessSecurity(query) ?? 'auto';
    outbound['alter_id'] =
        _parseInt(_firstNonEmpty(query, const ['alterid', 'aid'])) ?? 0;

    final security = (_firstNonEmpty(query, const ['security']) ?? '')
        .toLowerCase();
    final tls = _buildTlsConfig(query);
    if (security == 'reality' && tls == null) {
      return null;
    }
    if (tls != null) {
      outbound['tls'] = tls;
    }

    final transport = _buildTransportConfigFromValues(
      transportType: _firstNonEmpty(query, const ['type']) ?? 'tcp',
      headerType: _firstNonEmpty(query, const ['headertype']),
      hostValue: _firstNonEmpty(query, const ['host']),
      pathValue: _firstNonEmpty(query, const ['path']),
      serviceName: _firstNonEmpty(query, const ['servicename', 'service-name']),
      maxEarlyData: _firstNonEmpty(query, const ['ed', 'maxearlydata']),
      earlyDataHeaderName: _firstNonEmpty(query, const [
        'eh',
        'earlydataheadername',
      ]),
    );
    if (transport != null) {
      outbound['transport'] = transport;
    }

    return outbound;
  }

  static Map<String, dynamic>? _parseVmessJsonOutbound(
    Map<String, dynamic> decodedJson,
  ) {
    final server = _trimToNull(decodedJson['add'] ?? decodedJson['server']);
    final port = _parsePort(decodedJson['port'] ?? decodedJson['server_port']);
    final uuid = _trimToNull(decodedJson['id'] ?? decodedJson['uuid']);
    if (server == null || port == null || uuid == null) {
      return null;
    }

    final outbound = <String, dynamic>{
      'type': 'vmess',
      'tag': _trimToNull(decodedJson['ps']) ?? '$server:$port',
      'server': server,
      'server_port': port,
      'uuid': uuid,
      'security':
          _trimToNull(decodedJson['scy'] ?? decodedJson['security']) ?? 'auto',
      'alter_id': _parseInt(decodedJson['aid']) ?? 0,
    };

    final tlsParams = <String, String>{
      if (_trimToNull(decodedJson['tls']) != null)
        'security': _trimToNull(decodedJson['tls'])!,
      if (_trimToNull(decodedJson['sni']) != null)
        'sni': _trimToNull(decodedJson['sni'])!,
      if (_trimToNull(decodedJson['alpn']) != null)
        'alpn': _trimToNull(decodedJson['alpn'])!,
      if (_trimToNull(decodedJson['fp']) != null)
        'fp': _trimToNull(decodedJson['fp'])!,
      if (_trimToNull(decodedJson['allowInsecure']) != null)
        'allowinsecure': _trimToNull(decodedJson['allowInsecure'])!,
      if (_trimToNull(decodedJson['pbk']) != null)
        'pbk': _trimToNull(decodedJson['pbk'])!,
      if (_trimToNull(decodedJson['sid']) != null)
        'sid': _trimToNull(decodedJson['sid'])!,
    };
    final tlsSecurity = (tlsParams['security'] ?? '').toLowerCase();
    final tls = _buildTlsConfig(tlsParams);
    if (tlsSecurity == 'reality' && tls == null) {
      return null;
    }
    if (tls != null) {
      outbound['tls'] = tls;
    }

    final transport = _buildTransportConfigFromValues(
      transportType: _trimToNull(decodedJson['net']) ?? 'tcp',
      headerType: _trimToNull(decodedJson['type']),
      hostValue: _trimToNull(decodedJson['host']),
      pathValue: _trimToNull(decodedJson['path']),
      serviceName: _trimToNull(decodedJson['serviceName']),
      maxEarlyData: _trimToNull(decodedJson['ed']),
      earlyDataHeaderName: _trimToNull(decodedJson['eh']),
    );
    if (transport != null) {
      outbound['transport'] = transport;
    }

    return outbound;
  }

  static Map<String, dynamic>? _parseShadowsocksOutbound(String line) {
    final schemeSeparator = line.indexOf('://');
    if (schemeSeparator < 0) {
      return null;
    }

    final rawBody = line.substring(schemeSeparator + 3);
    final fragmentIndex = rawBody.indexOf('#');
    final fragment = fragmentIndex >= 0
        ? rawBody.substring(fragmentIndex + 1)
        : '';
    final withoutFragment = fragmentIndex >= 0
        ? rawBody.substring(0, fragmentIndex)
        : rawBody;
    final queryIndex = withoutFragment.indexOf('?');
    final rawQuery = queryIndex >= 0
        ? withoutFragment.substring(queryIndex + 1)
        : '';
    var encodedAuthority = queryIndex >= 0
        ? withoutFragment.substring(0, queryIndex)
        : withoutFragment;

    if (!encodedAuthority.contains('@')) {
      final decodedAuthority = _tryDecodeBase64(encodedAuthority);
      if (decodedAuthority != null && decodedAuthority.contains('@')) {
        encodedAuthority = decodedAuthority;
      }
    }

    final atIndex = encodedAuthority.lastIndexOf('@');
    if (atIndex <= 0) {
      return null;
    }

    var credentials = encodedAuthority.substring(0, atIndex);
    final hostPort = encodedAuthority.substring(atIndex + 1);
    final decodedCredentials = _tryDecodeBase64(credentials);
    if (decodedCredentials != null && decodedCredentials.contains(':')) {
      credentials = decodedCredentials;
    }

    final separatorIndex = credentials.indexOf(':');
    if (separatorIndex <= 0) {
      return null;
    }

    final method =
        _decodeUriComponent(credentials.substring(0, separatorIndex)) ??
        credentials.substring(0, separatorIndex).trim();
    final password =
        _decodeUriComponent(credentials.substring(separatorIndex + 1)) ??
        credentials.substring(separatorIndex + 1).trim();
    final hostPortUri = Uri.tryParse('placeholder://$hostPort');
    if (method.isEmpty ||
        password.isEmpty ||
        hostPortUri == null ||
        hostPortUri.host.isEmpty ||
        hostPortUri.port <= 0) {
      return null;
    }

    final outbound = <String, dynamic>{
      'type': 'shadowsocks',
      'tag':
          _decodeUriComponent(fragment) ??
          '${hostPortUri.host}:${hostPortUri.port}',
      'server': hostPortUri.host,
      'server_port': hostPortUri.port,
      'method': method,
      'password': password,
    };

    final query = _parseRawQuery(rawQuery);
    final plugin = _firstNonEmpty(query, const ['plugin']);
    if (plugin != null) {
      final segments = plugin
          .split(';')
          .map((item) => item.trim())
          .where((item) => item.isNotEmpty)
          .toList();
      if (segments.isNotEmpty) {
        outbound['plugin'] = segments.first;
        if (segments.length > 1) {
          outbound['plugin_opts'] = segments.sublist(1).join(';');
        }
      }
    }

    return outbound;
  }

  static Map<String, dynamic>? _buildCredentialOutbound({
    required String type,
    required Uri uri,
    required String credentialKey,
  }) {
    final host = uri.host.trim();
    final credential = _decodeUriComponent(uri.userInfo) ?? uri.userInfo.trim();
    if (host.isEmpty || credential.isEmpty || uri.port <= 0) {
      return null;
    }

    return {
      'type': type,
      'tag': _resolveOutboundTag(uri),
      'server': host,
      'server_port': uri.port,
      credentialKey: credential,
    };
  }

  static Uri? _tryParseShareUri(String line) {
    final fragmentIndex = line.indexOf('#');
    if (fragmentIndex < 0) {
      return Uri.tryParse(line);
    }

    final prefix = line.substring(0, fragmentIndex);
    final fragment = line.substring(fragmentIndex + 1);
    return Uri.tryParse('$prefix#${Uri.encodeComponent(fragment)}');
  }

  static Map<String, String> _queryParameters(Uri uri) {
    final params = <String, String>{};
    for (final entry in uri.queryParametersAll.entries) {
      for (final value in entry.value) {
        final trimmed = value.trim();
        if (trimmed.isEmpty) {
          continue;
        }
        params[entry.key.toLowerCase()] = trimmed;
        break;
      }
    }
    return params;
  }

  static Map<String, String> _parseRawQuery(String rawQuery) {
    if (rawQuery.trim().isEmpty) {
      return const {};
    }

    try {
      final decoded = Uri.splitQueryString(rawQuery);
      return {
        for (final entry in decoded.entries)
          if (entry.value.trim().isNotEmpty)
            entry.key.toLowerCase(): entry.value.trim(),
      };
    } catch (_) {
      return const {};
    }
  }

  static Map<String, dynamic>? _buildTlsConfig(
    Map<String, String> params, {
    bool forceEnabled = false,
  }) {
    final security = (_firstNonEmpty(params, const ['security']) ?? '')
        .toLowerCase();
    final enabled = forceEnabled || security == 'tls' || security == 'reality';
    if (!enabled) {
      return null;
    }

    final tls = <String, dynamic>{'enabled': true};
    final serverName = _firstNonEmpty(params, const [
      'sni',
      'servername',
      'server-name',
    ]);
    if (serverName != null) {
      tls['server_name'] = serverName;
    }

    final insecure = _parseBoolFlag(
      _firstNonEmpty(params, const ['allowinsecure', 'insecure']),
    );
    if (insecure == true) {
      tls['insecure'] = true;
    }

    final alpn = _splitCsv(_firstNonEmpty(params, const ['alpn']));
    if (alpn.isNotEmpty) {
      tls['alpn'] = alpn;
    }

    final fingerprint = _firstNonEmpty(params, const ['fp', 'fingerprint']);
    if (fingerprint != null) {
      tls['utls'] = {'enabled': true, 'fingerprint': fingerprint};
    }

    if (security == 'reality') {
      final publicKey = _firstNonEmpty(params, const [
        'pbk',
        'publickey',
        'public-key',
      ]);
      if (publicKey == null) {
        return null;
      }

      final shortId = _firstNonEmpty(params, const [
        'sid',
        'shortid',
        'short-id',
      ]);
      final reality = <String, dynamic>{
        'enabled': true,
        'public_key': publicKey,
      };
      if (shortId != null) {
        reality['short_id'] = shortId;
      }
      tls['reality'] = reality;
    }

    return tls;
  }

  static Map<String, dynamic>? _buildTransportConfigFromValues({
    required String transportType,
    String? headerType,
    String? hostValue,
    String? pathValue,
    String? serviceName,
    String? maxEarlyData,
    String? earlyDataHeaderName,
  }) {
    final normalizedType = transportType.trim().toLowerCase();
    final normalizedHeaderType = (headerType ?? '').trim().toLowerCase();
    final path = pathValue?.trim();
    final host = hostValue?.trim();

    switch (normalizedType) {
      case '':
      case 'tcp':
        if (normalizedHeaderType == 'http') {
          final httpHosts = _splitCsv(host);
          return {
            'type': 'http',
            if (httpHosts.isNotEmpty) 'host': httpHosts,
            if (path != null && path.isNotEmpty) 'path': path,
          };
        }
        return null;
      case 'ws':
      case 'websocket':
        final transport = <String, dynamic>{'type': 'ws'};
        if (path != null && path.isNotEmpty) {
          transport['path'] = path;
        }
        if (host != null && host.isNotEmpty) {
          transport['headers'] = {'Host': host};
        }
        final earlyData = _parseInt(maxEarlyData);
        if (earlyData != null && earlyData > 0) {
          transport['max_early_data'] = earlyData;
        }
        final headerName = earlyDataHeaderName?.trim();
        if (headerName != null && headerName.isNotEmpty) {
          transport['early_data_header_name'] = headerName;
        }
        return transport;
      case 'grpc':
        final resolvedServiceName = (serviceName ?? pathValue)
            ?.replaceFirst(RegExp(r'^/+'), '')
            .trim();
        return {
          'type': 'grpc',
          if (resolvedServiceName != null && resolvedServiceName.isNotEmpty)
            'service_name': resolvedServiceName,
        };
      case 'http':
        final httpHosts = _splitCsv(host);
        return {
          'type': 'http',
          if (httpHosts.isNotEmpty) 'host': httpHosts,
          if (path != null && path.isNotEmpty) 'path': path,
        };
      case 'httpupgrade':
      case 'http-upgrade':
        return {
          'type': 'httpupgrade',
          if (host != null && host.isNotEmpty) 'host': host,
          if (path != null && path.isNotEmpty) 'path': path,
        };
      case 'quic':
        return {'type': 'quic'};
    }

    return null;
  }

  static String _resolveOutboundTag(Uri uri) {
    final fragment = _decodeUriComponent(uri.fragment);
    if (fragment != null && fragment.isNotEmpty) {
      return fragment;
    }

    if (uri.port > 0) {
      return '${uri.host}:${uri.port}';
    }
    return uri.host;
  }

  static String _fallbackOutboundTag(Map<String, dynamic> outbound) {
    final host = outbound['server']?.toString().trim() ?? 'server';
    final port = outbound['server_port']?.toString().trim() ?? '';
    final type = outbound['type']?.toString().trim() ?? 'proxy';
    final location = port.isEmpty ? host : '$host:$port';
    return '$location [$type]';
  }

  static String _ensureUniqueTag(String tag, Map<String, int> tagCounts) {
    final count = tagCounts[tag];
    if (count == null) {
      tagCounts[tag] = 1;
      return tag;
    }

    final nextCount = count + 1;
    tagCounts[tag] = nextCount;
    return '$tag ($nextCount)';
  }

  static String? _resolveVmessSecurity(Map<String, String> query) {
    final encryption = _firstNonEmpty(query, const ['encryption']);
    if (encryption != null) {
      return encryption;
    }

    final security = _firstNonEmpty(query, const ['security']);
    if (security == null) {
      return null;
    }

    final normalized = security.toLowerCase();
    if (normalized == 'tls' || normalized == 'reality') {
      return null;
    }

    return security;
  }

  static String? _firstNonEmpty(Map<String, String> values, List<String> keys) {
    for (final key in keys) {
      final value = values[key];
      if (value == null) {
        continue;
      }

      final trimmed = value.trim();
      if (trimmed.isNotEmpty) {
        return trimmed;
      }
    }
    return null;
  }

  static List<String> _splitCsv(String? value) {
    if (value == null || value.trim().isEmpty) {
      return const [];
    }

    return value
        .split(',')
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
  }

  static bool? _parseBoolFlag(String? value) {
    if (value == null) {
      return null;
    }

    final normalized = value.trim().toLowerCase();
    if (_trueBooleanValues.contains(normalized)) {
      return true;
    }
    if (_falseBooleanValues.contains(normalized)) {
      return false;
    }
    return null;
  }

  static int? _parseInt(Object? value) {
    if (value == null) {
      return null;
    }

    if (value is int) {
      return value;
    }

    return int.tryParse(value.toString().trim());
  }

  static int? _parsePort(Object? value) {
    final port = _parseInt(value);
    if (port == null || port <= 0) {
      return null;
    }
    return port;
  }

  static String? _trimToNull(Object? value) {
    if (value == null) {
      return null;
    }

    final trimmed = value.toString().trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static String? _decodeUriComponent(String? value) {
    if (value == null || value.trim().isEmpty) {
      return null;
    }

    try {
      final decoded = Uri.decodeComponent(value).trim();
      return decoded.isEmpty ? null : decoded;
    } catch (_) {
      final trimmed = value.trim();
      return trimmed.isEmpty ? null : trimmed;
    }
  }

  static String? _tryDecodeBase64(String value) {
    final compact = value.replaceAll(RegExp(r'\s+'), '');
    if (compact.isEmpty || compact.length % 4 == 1) {
      return null;
    }
    if (!RegExp(r'^[A-Za-z0-9+/=_-]+$').hasMatch(compact)) {
      return null;
    }

    try {
      final normalized = base64.normalize(compact);
      return utf8.decode(base64Decode(normalized), allowMalformed: true).trim();
    } catch (_) {
      return null;
    }
  }

  static String _resolveProfileName({
    required Map<String, String> headers,
    required Uri source,
    required String fallback,
  }) {
    final headerTitle = _decodeHeaderText(headers['profile-title']);
    if (headerTitle.isNotEmpty) {
      return headerTitle;
    }

    final contentDispositionName = _extractContentDispositionName(
      headers['content-disposition'],
    );
    if (contentDispositionName.isNotEmpty) {
      return contentDispositionName;
    }

    final fragment = _safeUriDecodeComponent(source.fragment).trim();
    if (fragment.isNotEmpty) {
      return fragment;
    }

    final pathSegment = source.pathSegments.isNotEmpty
        ? source.pathSegments.last.trim()
        : '';
    if (pathSegment.isNotEmpty) {
      final dotIndex = pathSegment.lastIndexOf('.');
      return dotIndex > 0 ? pathSegment.substring(0, dotIndex) : pathSegment;
    }

    return fallback;
  }

  static String _decodeHeaderText(String? rawValue) {
    if (rawValue == null || rawValue.trim().isEmpty) {
      return '';
    }

    final uriDecoded = _safeUriDecodeFull(rawValue).trim();
    final base64Payload = uriDecoded.startsWith('base64:')
        ? uriDecoded.substring('base64:'.length).trim()
        : uriDecoded;
    final maybeBase64 = _tryDecodeBase64(base64Payload);
    if (maybeBase64 != null && maybeBase64.isNotEmpty) {
      return maybeBase64;
    }
    return base64Payload;
  }

  static String _extractContentDispositionName(String? rawValue) {
    if (rawValue == null || rawValue.isEmpty) {
      return '';
    }

    final utf8Match = RegExp(
      r"filename\*=UTF-8''([^;]+)",
      caseSensitive: false,
    ).firstMatch(rawValue);
    if (utf8Match != null) {
      return _safeUriDecodeComponent(utf8Match.group(1) ?? '').trim();
    }

    final plainMatch = RegExp(
      r'filename="?([^";]+)"?',
      caseSensitive: false,
    ).firstMatch(rawValue);
    if (plainMatch != null) {
      return plainMatch.group(1)?.trim() ?? '';
    }

    return '';
  }

  static String _safeUriDecodeFull(String value) {
    try {
      return Uri.decodeFull(value);
    } on Object {
      return value;
    }
  }

  static String _safeUriDecodeComponent(String value) {
    try {
      return Uri.decodeComponent(value);
    } on Object {
      return value;
    }
  }

  static int _replacementCharacterCount(String value) {
    var count = 0;
    for (final rune in value.runes) {
      if (rune == 0xFFFD) {
        count += 1;
      }
    }
    return count;
  }

  static int _utf8MojibakeScore(String value) {
    var count = 0;
    for (final rune in value.runes) {
      switch (rune) {
        case 0x00C2: // Â
        case 0x00C3: // Ã
        case 0x00D0: // Ð
        case 0x00D1: // Ñ
        case 0x00F0: // ð
          count += 1;
      }
    }
    return count;
  }

  static SubscriptionInfo? _parseSubscriptionInfo(Map<String, String> headers) {
    final raw = headers['subscription-userinfo'];
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }

    final values = <String, int>{};
    for (final segment in raw.split(';')) {
      final parts = segment.split('=');
      if (parts.length != 2) {
        continue;
      }
      values[parts.first.trim().toLowerCase()] =
          int.tryParse(parts.last.trim()) ?? 0;
    }

    final hasTraffic =
        values.containsKey('upload') ||
        values.containsKey('download') ||
        values.containsKey('total');
    if (!hasTraffic) {
      return null;
    }

    final expireSeconds = values['expire'];
    return SubscriptionInfo(
      upload: values['upload'] ?? 0,
      download: values['download'] ?? 0,
      total: values['total'] ?? 0,
      expireAt: expireSeconds == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              expireSeconds * 1000,
              isUtc: true,
            ).toLocal(),
      webPageUrl: headers['profile-web-page-url'],
      supportUrl: headers['support-url'],
    );
  }

  static String _beautifyServerName(String tag) {
    return normalizeServerDisplayText(tag, replaceUnderscores: true);
  }
}
