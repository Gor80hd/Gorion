import 'package:gorion_clean/features/settings/model/split_tunnel_settings.dart';

class SplitTunnelTagSuggestion {
  const SplitTunnelTagSuggestion({
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
    required this.action,
    this.geositeTags = const [],
    this.geoipTags = const [],
    this.domainSuffixes = const [],
    this.ipCidrs = const [],
  });

  final String id;
  final String label;
  final String description;
  final SplitTunnelAction action;
  final List<String> geositeTags;
  final List<String> geoipTags;
  final List<String> domainSuffixes;
  final List<String> ipCidrs;
}

const splitTunnelSuggestedGeositeTags = <SplitTunnelTagSuggestion>[
  SplitTunnelTagSuggestion(
    tag: 'category-ru',
    label: 'geosite:category-ru',
    description: 'Россия: основные домены и онлайн-сервисы.',
  ),
  SplitTunnelTagSuggestion(
    tag: 'category-gov-ru',
    label: 'geosite:category-gov-ru',
    description: 'Россия: государственные сервисы и домены.',
  ),
  SplitTunnelTagSuggestion(
    tag: 'category-bank-ru',
    label: 'geosite:category-bank-ru',
    description: 'Россия: банки и платёжные сервисы.',
  ),
  SplitTunnelTagSuggestion(
    tag: 'category-media-ru',
    label: 'geosite:category-media-ru',
    description: 'Россия: медиа и новостные сайты.',
  ),
  SplitTunnelTagSuggestion(
    tag: 'category-ecommerce-ru',
    label: 'geosite:category-ecommerce-ru',
    description: 'Россия: маркетплейсы и e-commerce.',
  ),
  SplitTunnelTagSuggestion(
    tag: 'category-entertainment-ru',
    label: 'geosite:category-entertainment-ru',
    description: 'Россия: развлекательные сервисы.',
  ),
  SplitTunnelTagSuggestion(
    tag: 'apple',
    label: 'geosite:apple',
    description: 'Сервисы Apple.',
  ),
  SplitTunnelTagSuggestion(
    tag: 'google',
    label: 'geosite:google',
    description: 'Сервисы Google.',
  ),
  SplitTunnelTagSuggestion(
    tag: 'youtube',
    label: 'geosite:youtube',
    description: 'YouTube и связанные домены.',
  ),
  SplitTunnelTagSuggestion(
    tag: 'telegram',
    label: 'geosite:telegram',
    description: 'Домены Telegram.',
  ),
  SplitTunnelTagSuggestion(
    tag: 'github',
    label: 'geosite:github',
    description: 'GitHub и связанные домены.',
  ),
  SplitTunnelTagSuggestion(
    tag: 'netflix',
    label: 'geosite:netflix',
    description: 'Домены Netflix.',
  ),
  SplitTunnelTagSuggestion(
    tag: 'openai',
    label: 'geosite:openai',
    description: 'Домены OpenAI.',
  ),
  SplitTunnelTagSuggestion(
    tag: 'category-ads-all',
    label: 'geosite:category-ads-all',
    description: 'Рекламные и трекинговые домены.',
  ),
  SplitTunnelTagSuggestion(
    tag: 'cn',
    label: 'geosite:cn',
    description: 'Домены Китая.',
  ),
];

const splitTunnelSuggestedGeoipTags = <SplitTunnelTagSuggestion>[
  SplitTunnelTagSuggestion(
    tag: 'private',
    label: 'geoip:private',
    description: 'LAN и private ranges.',
  ),
  SplitTunnelTagSuggestion(
    tag: 'ru',
    label: 'geoip:ru',
    description: 'Россия: IP-диапазоны страны.',
  ),
  SplitTunnelTagSuggestion(
    tag: 'telegram',
    label: 'geoip:telegram',
    description: 'IP Telegram.',
  ),
  SplitTunnelTagSuggestion(
    tag: 'google',
    label: 'geoip:google',
    description: 'IP Google.',
  ),
  SplitTunnelTagSuggestion(
    tag: 'netflix',
    label: 'geoip:netflix',
    description: 'IP Netflix.',
  ),
  SplitTunnelTagSuggestion(
    tag: 'cloudflare',
    label: 'geoip:cloudflare',
    description: 'IP Cloudflare.',
  ),
  SplitTunnelTagSuggestion(
    tag: 'cloudfront',
    label: 'geoip:cloudfront',
    description: 'IP Amazon CloudFront.',
  ),
  SplitTunnelTagSuggestion(
    tag: 'apple',
    label: 'geoip:apple',
    description: 'IP Apple.',
  ),
  SplitTunnelTagSuggestion(
    tag: 'facebook',
    label: 'geoip:facebook',
    description: 'IP Meta / Facebook.',
  ),
  SplitTunnelTagSuggestion(
    tag: 'cn',
    label: 'geoip:cn',
    description: 'IP-диапазоны Китая.',
  ),
];

const splitTunnelPresets = <SplitTunnelPreset>[
  SplitTunnelPreset(
    id: 'lan-direct',
    label: 'LAN / private',
    description: 'Локальные адреса и hostname уйдут в direct.',
    action: SplitTunnelAction.direct,
    geoipTags: ['private'],
    domainSuffixes: ['local', 'lan', 'localhost'],
  ),
  SplitTunnelPreset(
    id: 'ru-direct',
    label: 'RU direct',
    description: 'Российские домены и IP пойдут напрямую.',
    action: SplitTunnelAction.direct,
    geositeTags: ['category-ru'],
    geoipTags: ['ru', 'private'],
    domainSuffixes: ['local', 'lan', 'localhost'],
  ),
  SplitTunnelPreset(
    id: 'apple-direct',
    label: 'Apple direct',
    description: 'Apple-сервисы уйдут в DIRECT по geosite.',
    action: SplitTunnelAction.direct,
    geositeTags: ['apple'],
  ),
  SplitTunnelPreset(
    id: 'ads-block',
    label: 'Ads block',
    description: 'Основные рекламные и трекинговые домены будут блокироваться.',
    action: SplitTunnelAction.block,
    geositeTags: ['category-ads-all'],
    domainSuffixes: [
      'doubleclick.net',
      'googleadservices.com',
      'googlesyndication.com',
      'googletagmanager.com',
    ],
  ),
  SplitTunnelPreset(
    id: 'telegram-proxy',
    label: 'Telegram proxy',
    description: 'Маршрутизировать Telegram через активный proxy.',
    action: SplitTunnelAction.proxy,
    geoipTags: ['telegram'],
    domainSuffixes: ['t.me', 'telegram.org', 'telegram.me'],
  ),
  SplitTunnelPreset(
    id: 'google-proxy',
    label: 'Google / YouTube proxy',
    description: 'Маршрутизировать сервисы Google и YouTube через proxy.',
    action: SplitTunnelAction.proxy,
    geoipTags: ['google'],
    domainSuffixes: ['google.com', 'gstatic.com', 'youtube.com', 'youtu.be'],
  ),
  SplitTunnelPreset(
    id: 'netflix-proxy',
    label: 'Netflix proxy',
    description: 'Оставлять Netflix на активном proxy-маршруте.',
    action: SplitTunnelAction.proxy,
    geoipTags: ['netflix'],
    domainSuffixes: ['netflix.com', 'nflxvideo.net', 'nflximg.net'],
  ),
];

List<SplitTunnelPreset> splitTunnelPresetsForAction(SplitTunnelAction action) {
  return [
    for (final preset in splitTunnelPresets)
      if (preset.action == action) preset,
  ];
}

SplitTunnelSettings applySplitTunnelPreset({
  required SplitTunnelSettings current,
  required SplitTunnelPreset preset,
}) {
  final currentGroup = current.groupFor(preset.action);
  final nextGroup = currentGroup.copyWith(
    geositeTags: [...currentGroup.geositeTags, ...preset.geositeTags],
    geoipTags: [...currentGroup.geoipTags, ...preset.geoipTags],
    domainSuffixes: [...currentGroup.domainSuffixes, ...preset.domainSuffixes],
    ipCidrs: [...currentGroup.ipCidrs, ...preset.ipCidrs],
  );
  return current
      .copyWith(enabled: true)
      .copyWithGroup(preset.action, nextGroup);
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
