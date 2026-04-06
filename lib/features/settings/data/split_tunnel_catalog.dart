import 'package:gorion_clean/features/settings/model/split_tunnel_settings.dart';

class SplitTunnelSuggestion {
  const SplitTunnelSuggestion({
    required this.tag,
    required this.label,
    required this.description,
  });

  final String tag;
  final String label;
  final String description;
}

class SplitTunnelPreset {
  const SplitTunnelPreset({
    required this.id,
    required this.label,
    required this.description,
    this.geositeTags = const [],
    this.geoipTags = const [],
    this.domainSuffixes = const [],
    this.ipCidrs = const [],
  });

  final String id;
  final String label;
  final String description;
  final List<String> geositeTags;
  final List<String> geoipTags;
  final List<String> domainSuffixes;
  final List<String> ipCidrs;
}

const splitTunnelSuggestedGeositeEntries = <SplitTunnelSuggestion>[
  SplitTunnelSuggestion(
    tag: 'cn',
    label: 'geosite:cn',
    description: 'Домены материкового Китая напрямую.',
  ),
  SplitTunnelSuggestion(
    tag: 'apple',
    label: 'geosite:apple',
    description: 'Сервисы Apple напрямую.',
  ),
];

const splitTunnelSuggestedGeoipEntries = <SplitTunnelSuggestion>[
  SplitTunnelSuggestion(
    tag: 'private',
    label: 'geoip:private',
    description: 'LAN и private ranges напрямую.',
  ),
  SplitTunnelSuggestion(
    tag: 'cn',
    label: 'geoip:cn',
    description: 'IP-диапазоны Китая напрямую.',
  ),
  SplitTunnelSuggestion(
    tag: 'ru',
    label: 'geoip:ru',
    description: 'IP-диапазоны России напрямую.',
  ),
  SplitTunnelSuggestion(
    tag: 'us',
    label: 'geoip:us',
    description: 'IP-диапазоны США напрямую.',
  ),
  SplitTunnelSuggestion(
    tag: 'jp',
    label: 'geoip:jp',
    description: 'IP-диапазоны Японии напрямую.',
  ),
  SplitTunnelSuggestion(
    tag: 'telegram',
    label: 'geoip:telegram',
    description: 'IP-адреса Telegram напрямую.',
  ),
  SplitTunnelSuggestion(
    tag: 'google',
    label: 'geoip:google',
    description: 'IP-адреса Google напрямую.',
  ),
  SplitTunnelSuggestion(
    tag: 'netflix',
    label: 'geoip:netflix',
    description: 'IP-адреса Netflix напрямую.',
  ),
];

const splitTunnelPresets = <SplitTunnelPreset>[
  SplitTunnelPreset(
    id: 'lan-bypass',
    label: 'LAN / private',
    description: 'Не гонять private IP и локальные hostname через туннель.',
    geoipTags: ['private'],
    domainSuffixes: ['local', 'lan', 'localhost'],
  ),
  SplitTunnelPreset(
    id: 'cn-bypass',
    label: 'CN direct',
    description: 'Китайские домены и IP пойдут напрямую.',
    geositeTags: ['cn'],
    geoipTags: ['cn', 'private'],
    domainSuffixes: ['local', 'lan', 'localhost'],
  ),
  SplitTunnelPreset(
    id: 'apple-bypass',
    label: 'Apple direct',
    description: 'Apple-сервисы уйдут в DIRECT по geosite.',
    geositeTags: ['apple'],
  ),
];

SplitTunnelSettings applySplitTunnelPreset({
  required SplitTunnelSettings current,
  required SplitTunnelPreset preset,
}) {
  return current.copyWith(
    enabled: true,
    geositeTags: [...current.geositeTags, ...preset.geositeTags],
    geoipTags: [...current.geoipTags, ...preset.geoipTags],
    domainSuffixes: [...current.domainSuffixes, ...preset.domainSuffixes],
    ipCidrs: [...current.ipCidrs, ...preset.ipCidrs],
  );
}

String buildBuiltInGeositeRuleSetUrl(String tag, {int revision = 0}) {
  return _appendRevisionQuery(
    'https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/${normalizeSplitTunnelTag(tag)}.srs',
    revision,
  );
}

String buildBuiltInGeoipRuleSetUrl(String tag, {int revision = 0}) {
  return _appendRevisionQuery(
    'https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geoip/${normalizeSplitTunnelTag(tag)}.srs',
    revision,
  );
}

String _appendRevisionQuery(String url, int revision) {
  if (revision <= 0) {
    return url;
  }

  final uri = Uri.parse(url);
  final queryParameters = Map<String, String>.from(uri.queryParameters);
  queryParameters['gorion_rev'] = revision.toString();
  return uri.replace(queryParameters: queryParameters).toString();
}
