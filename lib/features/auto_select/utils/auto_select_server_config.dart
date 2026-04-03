import 'dart:convert';

typedef AutoSelectConfigCandidate = ({String tag, String type, String? host, int? port});

const selectableOutboundTypes = {
  'http',
  'hysteria',
  'hysteria2',
  'mieru',
  'naive',
  'shadowtls',
  'shadowsocks',
  'shadowsocksr',
  'socks',
  'ssh',
  'trojan',
  'tuic',
  'vless',
  'vmess',
  'warp',
  'wireguard',
  'awg',
  'xvless',
  'xvmess',
  'xtrojan',
  'xfreedom',
  'xshadowsocks',
  'xsocks',
};

const _selectorLikeTypes = {'selector', 'urltest'};

List<AutoSelectConfigCandidate> extractAutoSelectConfigCandidates(String generatedConfig) {
  final config = _decodeConfig(generatedConfig);
  if (config == null) return const [];

  final outbounds = config['outbounds'];
  if (outbounds is! List) return const [];

  final candidates = <AutoSelectConfigCandidate>[];
  for (final outbound in outbounds) {
    if (outbound is! Map) continue;

    final map = Map<String, dynamic>.from(outbound.cast<String, dynamic>());
    final tag = map['tag']?.toString().trim() ?? '';
    final type = map['type']?.toString().trim().toLowerCase() ?? '';
    if (tag.isEmpty || type.isEmpty) continue;
    if (tag.contains('§hide§')) continue;
    if (!selectableOutboundTypes.contains(type)) continue;

    final host = _extractCandidateHost(map);
    final port = _extractCandidatePort(map);
    candidates.add((tag: tag, type: type, host: host, port: port));
  }

  return candidates;
}

/// Builds a minimal sing-box config that forwards all traffic through
/// [outbound] on a local mixed proxy bound to [mixedPort].
///
/// The resulting JSON has no DNS section, no complex routing rules, no Clash
/// API and no URL-test group — just what is needed to proxy a single TCP
/// connection through the target server so a basic HTTP probe can verify it.
/// This starts much faster and fails faster than a full profile config.
String buildMinimalProbeConfig({
  required Map<String, dynamic> outbound,
  required int mixedPort,
}) {
  return jsonEncode({
    'log': {'level': 'warn'},
    'inbounds': [
      {
        'type': 'mixed',
        'listen': '127.0.0.1',
        'listen_port': mixedPort,
        'tag': 'probe$mixedPort',
      },
    ],
    'outbounds': [
      outbound,
      {'type': 'direct', 'tag': 'direct'},
    ],
    'route': {'final': outbound['tag']},
  });
}

Map<String, dynamic>? extractAutoSelectConfigOutbound(String generatedConfig, String serverTag) {
  final config = _decodeConfig(generatedConfig);
  if (config == null) return null;

  final outbounds = config['outbounds'];
  if (outbounds is! List) return null;

  for (final outbound in outbounds) {
    if (outbound is! Map) continue;

    final map = Map<String, dynamic>.from(outbound.cast<String, dynamic>());
    if (map['tag']?.toString() == serverTag) {
      return map;
    }
  }

  return null;
}

String? applyAutoSelectConfigSelection(String generatedConfig, String serverTag) {
  final config = _decodeConfig(generatedConfig);
  if (config == null) return null;
  if (extractAutoSelectConfigOutbound(generatedConfig, serverTag) == null) return null;

  final updated = _rewriteSelectedOutbound(config, serverTag);
  return jsonEncode(updated);
}

Map<String, dynamic>? _decodeConfig(String generatedConfig) {
  try {
    final decoded = jsonDecode(generatedConfig);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    if (decoded is Map) {
      return Map<String, dynamic>.from(decoded.cast<String, dynamic>());
    }
  } catch (_) {}
  return null;
}

String? _extractCandidateHost(Map<String, dynamic> outbound) {
  final host = outbound['server']?.toString().trim() ?? outbound['address']?.toString().trim() ?? '';
  return host.isEmpty ? null : host;
}

int? _extractCandidatePort(Map<String, dynamic> outbound) {
  final rawPort = outbound['server_port'] ?? outbound['port'];
  if (rawPort == null) return null;

  final port = int.tryParse(rawPort.toString());
  if (port == null || port <= 0) return null;
  return port;
}

dynamic _rewriteSelectedOutbound(dynamic node, String serverTag) {
  if (node is List) {
    return [for (final item in node) _rewriteSelectedOutbound(item, serverTag)];
  }

  if (node is! Map) {
    return node;
  }

  final map = Map<String, dynamic>.from(node.cast<String, dynamic>());
  final rewritten = <String, dynamic>{};
  for (final entry in map.entries) {
    rewritten[entry.key] = _rewriteSelectedOutbound(entry.value, serverTag);
  }

  final type = rewritten['type']?.toString().trim().toLowerCase();
  final outbounds = rewritten['outbounds'];
  final containsServer = outbounds is List && outbounds.any((item) => item?.toString() == serverTag);
  if (containsServer &&
      (rewritten.containsKey('selected') || rewritten.containsKey('default') || _selectorLikeTypes.contains(type))) {
    rewritten['selected'] = serverTag;
    if (rewritten.containsKey('default')) {
      rewritten['default'] = serverTag;
    }
  }

  return rewritten;
}