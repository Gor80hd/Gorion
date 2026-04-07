enum SplitTunnelRuleSetSource {
  remote('remote'),
  local('local');

  const SplitTunnelRuleSetSource(this.jsonValue);

  final String jsonValue;

  static SplitTunnelRuleSetSource fromJsonValue(dynamic value) {
    final normalized = value?.toString().trim().toLowerCase();
    for (final source in values) {
      if (source.jsonValue == normalized) {
        return source;
      }
    }
    return SplitTunnelRuleSetSource.remote;
  }
}

enum SplitTunnelRuleSetFormat {
  binary('binary'),
  source('source');

  const SplitTunnelRuleSetFormat(this.jsonValue);

  final String jsonValue;

  static SplitTunnelRuleSetFormat fromJsonValue(dynamic value) {
    final normalized = value?.toString().trim().toLowerCase();
    for (final format in values) {
      if (format.jsonValue == normalized) {
        return format;
      }
    }
    return SplitTunnelRuleSetFormat.binary;
  }
}

enum SplitTunnelAction {
  direct('direct'),
  block('block'),
  proxy('proxy');

  const SplitTunnelAction(this.jsonValue);

  final String jsonValue;

  static SplitTunnelAction fromJsonValue(dynamic value) {
    final normalized = value?.toString().trim().toLowerCase();
    for (final action in values) {
      if (action.jsonValue == normalized) {
        return action;
      }
    }
    return SplitTunnelAction.direct;
  }
}

enum SplitTunnelManagedSourceKind { geosite, geoip }

const defaultSplitTunnelRemoteUpdateInterval = '1d';

class SplitTunnelCustomRuleSet {
  const SplitTunnelCustomRuleSet({
    required this.id,
    this.label = '',
    this.source = SplitTunnelRuleSetSource.remote,
    this.url = '',
    this.path = '',
    this.format = SplitTunnelRuleSetFormat.binary,
    this.enabled = true,
  });

  final String id;
  final String label;
  final SplitTunnelRuleSetSource source;
  final String url;
  final String path;
  final SplitTunnelRuleSetFormat format;
  final bool enabled;

  String get normalizedId => normalizeSplitTunnelRuleSetId(id);

  String get normalizedLabel => label.trim();

  String get normalizedUrl => url.trim();

  String get normalizedPath => path.trim();

  bool get isRemote => source == SplitTunnelRuleSetSource.remote;

  bool get hasSource =>
      isRemote ? normalizedUrl.isNotEmpty : normalizedPath.isNotEmpty;

  SplitTunnelCustomRuleSet copyWith({
    String? id,
    String? label,
    SplitTunnelRuleSetSource? source,
    String? url,
    String? path,
    SplitTunnelRuleSetFormat? format,
    bool? enabled,
  }) {
    return SplitTunnelCustomRuleSet(
      id: id ?? this.id,
      label: (label ?? this.label).trim(),
      source: source ?? this.source,
      url: (url ?? this.url).trim(),
      path: (path ?? this.path).trim(),
      format: format ?? this.format,
      enabled: enabled ?? this.enabled,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': normalizedId,
      'label': normalizedLabel,
      'source': source.jsonValue,
      'url': normalizedUrl,
      'path': normalizedPath,
      'format': format.jsonValue,
      'enabled': enabled,
    };
  }

  factory SplitTunnelCustomRuleSet.fromJson(Map<String, dynamic> json) {
    return SplitTunnelCustomRuleSet(
      id: json['id']?.toString() ?? '',
      label: json['label']?.toString().trim() ?? '',
      source: SplitTunnelRuleSetSource.fromJsonValue(json['source']),
      url: json['url']?.toString().trim() ?? '',
      path: json['path']?.toString().trim() ?? '',
      format: SplitTunnelRuleSetFormat.fromJsonValue(json['format']),
      enabled: json['enabled'] as bool? ?? true,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is SplitTunnelCustomRuleSet &&
        other.normalizedId == normalizedId &&
        other.normalizedLabel == normalizedLabel &&
        other.source == source &&
        other.normalizedUrl == normalizedUrl &&
        other.normalizedPath == normalizedPath &&
        other.format == format &&
        other.enabled == enabled;
  }

  @override
  int get hashCode => Object.hash(
    normalizedId,
    normalizedLabel,
    source,
    normalizedUrl,
    normalizedPath,
    format,
    enabled,
  );
}

class SplitTunnelRuleGroup {
  const SplitTunnelRuleGroup({
    this.geositeTags = const [],
    this.geoipTags = const [],
    this.domainSuffixes = const [],
    this.ipCidrs = const [],
    this.customRuleSets = const [],
  });

  final List<String> geositeTags;
  final List<String> geoipTags;
  final List<String> domainSuffixes;
  final List<String> ipCidrs;
  final List<SplitTunnelCustomRuleSet> customRuleSets;

  List<String> get normalizedGeositeTags {
    return _normalizeUniqueStrings(geositeTags, normalizeSplitTunnelTag);
  }

  List<String> get normalizedGeoipTags {
    return _normalizeUniqueStrings(geoipTags, normalizeSplitTunnelTag);
  }

  List<String> get normalizedDomainSuffixes {
    return _normalizeUniqueStrings(
      domainSuffixes,
      normalizeSplitTunnelDomainSuffix,
    );
  }

  List<String> get normalizedIpCidrs {
    return _normalizeUniqueStrings(ipCidrs, normalizeSplitTunnelIpCidr);
  }

  List<SplitTunnelCustomRuleSet> get normalizedCustomRuleSets {
    final seenIds = <String>{};
    final result = <SplitTunnelCustomRuleSet>[];
    for (final ruleSet in customRuleSets) {
      final normalized = ruleSet.copyWith();
      final normalizedId = normalized.normalizedId;
      if (normalizedId.isEmpty ||
          !normalized.hasSource ||
          !seenIds.add(normalizedId)) {
        continue;
      }
      result.add(normalized);
    }
    return result;
  }

  List<SplitTunnelCustomRuleSet> get activeCustomRuleSets {
    return [
      for (final ruleSet in normalizedCustomRuleSets)
        if (ruleSet.enabled) ruleSet,
    ];
  }

  bool get hasRules {
    return normalizedGeositeTags.isNotEmpty ||
        normalizedGeoipTags.isNotEmpty ||
        normalizedDomainSuffixes.isNotEmpty ||
        normalizedIpCidrs.isNotEmpty ||
        activeCustomRuleSets.isNotEmpty;
  }

  bool get hasManagedRemoteSources {
    return hasManagedGeositeSources || hasManagedGeoipSources;
  }

  bool get hasManagedGeositeSources => normalizedGeositeTags.isNotEmpty;

  bool get hasManagedGeoipSources => normalizedGeoipTags.isNotEmpty;

  bool get hasRemoteSources {
    return hasManagedRemoteSources ||
        activeCustomRuleSets.any((ruleSet) => ruleSet.isRemote);
  }

  int get ruleCount {
    return normalizedGeositeTags.length +
        normalizedGeoipTags.length +
        normalizedDomainSuffixes.length +
        normalizedIpCidrs.length +
        activeCustomRuleSets.length;
  }

  SplitTunnelRuleGroup copyWith({
    List<String>? geositeTags,
    List<String>? geoipTags,
    List<String>? domainSuffixes,
    List<String>? ipCidrs,
    List<SplitTunnelCustomRuleSet>? customRuleSets,
  }) {
    return SplitTunnelRuleGroup(
      geositeTags: geositeTags ?? this.geositeTags,
      geoipTags: geoipTags ?? this.geoipTags,
      domainSuffixes: domainSuffixes ?? this.domainSuffixes,
      ipCidrs: ipCidrs ?? this.ipCidrs,
      customRuleSets: customRuleSets ?? this.customRuleSets,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'geositeTags': normalizedGeositeTags,
      'geoipTags': normalizedGeoipTags,
      'domainSuffixes': normalizedDomainSuffixes,
      'ipCidrs': normalizedIpCidrs,
      'customRuleSets': [
        for (final ruleSet in normalizedCustomRuleSets) ruleSet.toJson(),
      ],
    };
  }

  factory SplitTunnelRuleGroup.fromJson(Map<String, dynamic> json) {
    final rawCustomRuleSets = json['customRuleSets'];
    return SplitTunnelRuleGroup(
      geositeTags: _readStringList(json['geositeTags']),
      geoipTags: _readStringList(json['geoipTags']),
      domainSuffixes: _readStringList(json['domainSuffixes']),
      ipCidrs: _readStringList(json['ipCidrs']),
      customRuleSets: rawCustomRuleSets is List
          ? [
              for (final rawRuleSet in rawCustomRuleSets)
                if (rawRuleSet is Map)
                  SplitTunnelCustomRuleSet.fromJson(
                    Map<String, dynamic>.from(
                      rawRuleSet.cast<String, dynamic>(),
                    ),
                  ),
            ]
          : const [],
    );
  }

  @override
  bool operator ==(Object other) {
    return other is SplitTunnelRuleGroup &&
        _listsEqual(other.normalizedGeositeTags, normalizedGeositeTags) &&
        _listsEqual(other.normalizedGeoipTags, normalizedGeoipTags) &&
        _listsEqual(other.normalizedDomainSuffixes, normalizedDomainSuffixes) &&
        _listsEqual(other.normalizedIpCidrs, normalizedIpCidrs) &&
        _listsEqual(other.normalizedCustomRuleSets, normalizedCustomRuleSets);
  }

  @override
  int get hashCode => Object.hash(
    Object.hashAll(normalizedGeositeTags),
    Object.hashAll(normalizedGeoipTags),
    Object.hashAll(normalizedDomainSuffixes),
    Object.hashAll(normalizedIpCidrs),
    Object.hashAll(normalizedCustomRuleSets),
  );
}

class SplitTunnelSettings {
  const SplitTunnelSettings({
    this.enabled = false,
    this.direct = const SplitTunnelRuleGroup(),
    this.block = const SplitTunnelRuleGroup(),
    this.proxy = const SplitTunnelRuleGroup(),
    this.remoteUpdateInterval = defaultSplitTunnelRemoteUpdateInterval,
    int remoteRevision = 0,
    DateTime? lastRemoteRefreshAt,
    int? geositeRemoteRevision,
    int? geoipRemoteRevision,
    DateTime? lastGeositeRefreshAt,
    DateTime? lastGeoipRefreshAt,
  }) : geositeRemoteRevision = geositeRemoteRevision ?? remoteRevision,
       geoipRemoteRevision = geoipRemoteRevision ?? remoteRevision,
       lastGeositeRefreshAt = lastGeositeRefreshAt ?? lastRemoteRefreshAt,
       lastGeoipRefreshAt = lastGeoipRefreshAt ?? lastRemoteRefreshAt;

  final bool enabled;
  final SplitTunnelRuleGroup direct;
  final SplitTunnelRuleGroup block;
  final SplitTunnelRuleGroup proxy;
  final String remoteUpdateInterval;
  final int geositeRemoteRevision;
  final int geoipRemoteRevision;
  final DateTime? lastGeositeRefreshAt;
  final DateTime? lastGeoipRefreshAt;

  int get remoteRevision {
    return geositeRemoteRevision >= geoipRemoteRevision
        ? geositeRemoteRevision
        : geoipRemoteRevision;
  }

  DateTime? get lastRemoteRefreshAt {
    return _latestDateTime(lastGeositeRefreshAt, lastGeoipRefreshAt);
  }

  String get normalizedRemoteUpdateInterval {
    return normalizeSplitTunnelUpdateInterval(remoteUpdateInterval);
  }

  bool get hasRules => direct.hasRules || block.hasRules || proxy.hasRules;

  bool get hasOverrides => enabled && hasRules;

  bool get hasManagedRemoteSources {
    return direct.hasManagedRemoteSources ||
        block.hasManagedRemoteSources ||
        proxy.hasManagedRemoteSources;
  }

  bool get hasManagedGeositeSources {
    return direct.hasManagedGeositeSources ||
        block.hasManagedGeositeSources ||
        proxy.hasManagedGeositeSources;
  }

  bool get hasManagedGeoipSources {
    return direct.hasManagedGeoipSources ||
        block.hasManagedGeoipSources ||
        proxy.hasManagedGeoipSources;
  }

  bool get hasRemoteSources {
    return direct.hasRemoteSources ||
        block.hasRemoteSources ||
        proxy.hasRemoteSources;
  }

  int get ruleCount => direct.ruleCount + block.ruleCount + proxy.ruleCount;

  int revisionForManagedSource(SplitTunnelManagedSourceKind sourceKind) {
    switch (sourceKind) {
      case SplitTunnelManagedSourceKind.geosite:
        return geositeRemoteRevision;
      case SplitTunnelManagedSourceKind.geoip:
        return geoipRemoteRevision;
    }
  }

  DateTime? lastRefreshAtForManagedSource(
    SplitTunnelManagedSourceKind sourceKind,
  ) {
    switch (sourceKind) {
      case SplitTunnelManagedSourceKind.geosite:
        return lastGeositeRefreshAt;
      case SplitTunnelManagedSourceKind.geoip:
        return lastGeoipRefreshAt;
    }
  }

  SplitTunnelRuleGroup groupFor(SplitTunnelAction action) {
    switch (action) {
      case SplitTunnelAction.direct:
        return direct;
      case SplitTunnelAction.block:
        return block;
      case SplitTunnelAction.proxy:
        return proxy;
    }
  }

  SplitTunnelSettings copyWith({
    bool? enabled,
    SplitTunnelRuleGroup? direct,
    SplitTunnelRuleGroup? block,
    SplitTunnelRuleGroup? proxy,
    String? remoteUpdateInterval,
    int? remoteRevision,
    int? geositeRemoteRevision,
    int? geoipRemoteRevision,
    DateTime? lastRemoteRefreshAt,
    DateTime? lastGeositeRefreshAt,
    DateTime? lastGeoipRefreshAt,
    bool clearLastRemoteRefreshAt = false,
    bool clearLastGeositeRefreshAt = false,
    bool clearLastGeoipRefreshAt = false,
  }) {
    final resolvedLastGeositeRefreshAt =
        clearLastRemoteRefreshAt || clearLastGeositeRefreshAt
        ? null
        : lastGeositeRefreshAt ??
              lastRemoteRefreshAt ??
              this.lastGeositeRefreshAt;
    final resolvedLastGeoipRefreshAt =
        clearLastRemoteRefreshAt || clearLastGeoipRefreshAt
        ? null
        : lastGeoipRefreshAt ?? lastRemoteRefreshAt ?? this.lastGeoipRefreshAt;

    return SplitTunnelSettings(
      enabled: enabled ?? this.enabled,
      direct: direct ?? this.direct,
      block: block ?? this.block,
      proxy: proxy ?? this.proxy,
      remoteUpdateInterval: remoteUpdateInterval ?? this.remoteUpdateInterval,
      geositeRemoteRevision:
          geositeRemoteRevision ?? remoteRevision ?? this.geositeRemoteRevision,
      geoipRemoteRevision:
          geoipRemoteRevision ?? remoteRevision ?? this.geoipRemoteRevision,
      lastGeositeRefreshAt: resolvedLastGeositeRefreshAt,
      lastGeoipRefreshAt: resolvedLastGeoipRefreshAt,
    );
  }

  SplitTunnelSettings copyWithGroup(
    SplitTunnelAction action,
    SplitTunnelRuleGroup group,
  ) {
    switch (action) {
      case SplitTunnelAction.direct:
        return copyWith(direct: group);
      case SplitTunnelAction.block:
        return copyWith(block: group);
      case SplitTunnelAction.proxy:
        return copyWith(proxy: group);
    }
  }

  SplitTunnelSettings bumpedRemoteRevision() {
    final now = DateTime.now();
    return copyWith(
      remoteRevision: now.microsecondsSinceEpoch,
      lastRemoteRefreshAt: now,
    );
  }

  SplitTunnelSettings bumpedManagedSourceRevision(
    SplitTunnelManagedSourceKind sourceKind,
  ) {
    final now = DateTime.now();
    switch (sourceKind) {
      case SplitTunnelManagedSourceKind.geosite:
        return copyWith(
          geositeRemoteRevision: now.microsecondsSinceEpoch,
          lastGeositeRefreshAt: now,
        );
      case SplitTunnelManagedSourceKind.geoip:
        return copyWith(
          geoipRemoteRevision: now.microsecondsSinceEpoch,
          lastGeoipRefreshAt: now,
        );
    }
  }

  Map<String, dynamic> toJson() {
    return {
      'enabled': enabled,
      'direct': direct.toJson(),
      'block': block.toJson(),
      'proxy': proxy.toJson(),
      'remoteUpdateInterval': normalizedRemoteUpdateInterval,
      'geositeRemoteRevision': geositeRemoteRevision,
      'geoipRemoteRevision': geoipRemoteRevision,
      'remoteRevision': remoteRevision,
      'lastGeositeRefreshAt': lastGeositeRefreshAt?.toIso8601String(),
      'lastGeoipRefreshAt': lastGeoipRefreshAt?.toIso8601String(),
      'lastRemoteRefreshAt': lastRemoteRefreshAt?.toIso8601String(),
    };
  }

  factory SplitTunnelSettings.fromJson(Map<String, dynamic> json) {
    final rawDirect = _readJsonMap(json['direct']);
    final rawBlock = _readJsonMap(json['block']);
    final rawProxy = _readJsonMap(json['proxy']);
    final legacyRemoteRevision = _tryParseInt(json['remoteRevision']) ?? 0;
    final legacyLastRemoteRefreshAt = _tryParseDateTime(
      json['lastRemoteRefreshAt'],
    );

    return SplitTunnelSettings(
      enabled: json['enabled'] as bool? ?? false,
      direct: rawDirect != null
          ? SplitTunnelRuleGroup.fromJson(rawDirect)
          : _readLegacyDirectGroup(json),
      block: rawBlock != null
          ? SplitTunnelRuleGroup.fromJson(rawBlock)
          : const SplitTunnelRuleGroup(),
      proxy: rawProxy != null
          ? SplitTunnelRuleGroup.fromJson(rawProxy)
          : const SplitTunnelRuleGroup(),
      remoteUpdateInterval:
          json['remoteUpdateInterval']?.toString().trim() ??
          defaultSplitTunnelRemoteUpdateInterval,
      geositeRemoteRevision:
          _tryParseInt(json['geositeRemoteRevision']) ?? legacyRemoteRevision,
      geoipRemoteRevision:
          _tryParseInt(json['geoipRemoteRevision']) ?? legacyRemoteRevision,
      lastGeositeRefreshAt:
          _tryParseDateTime(json['lastGeositeRefreshAt']) ??
          legacyLastRemoteRefreshAt,
      lastGeoipRefreshAt:
          _tryParseDateTime(json['lastGeoipRefreshAt']) ??
          legacyLastRemoteRefreshAt,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is SplitTunnelSettings &&
        other.enabled == enabled &&
        other.direct == direct &&
        other.block == block &&
        other.proxy == proxy &&
        other.normalizedRemoteUpdateInterval ==
            normalizedRemoteUpdateInterval &&
        other.geositeRemoteRevision == geositeRemoteRevision &&
        other.geoipRemoteRevision == geoipRemoteRevision &&
        other.lastGeositeRefreshAt?.toIso8601String() ==
            lastGeositeRefreshAt?.toIso8601String() &&
        other.lastGeoipRefreshAt?.toIso8601String() ==
            lastGeoipRefreshAt?.toIso8601String();
  }

  @override
  int get hashCode => Object.hash(
    enabled,
    direct,
    block,
    proxy,
    normalizedRemoteUpdateInterval,
    geositeRemoteRevision,
    geoipRemoteRevision,
    lastGeositeRefreshAt?.toIso8601String(),
    lastGeoipRefreshAt?.toIso8601String(),
  );
}

String normalizeSplitTunnelTag(String value) {
  return value.trim().toLowerCase().replaceAll(' ', '');
}

String normalizeSplitTunnelDomainSuffix(String value) {
  return value.trim().toLowerCase();
}

String normalizeSplitTunnelIpCidr(String value) {
  return value.trim();
}

String normalizeSplitTunnelRuleSetId(String value) {
  final normalized = value.trim().toLowerCase();
  return normalized.replaceAll(RegExp(r'[^a-z0-9._-]+'), '-');
}

String normalizeSplitTunnelUpdateInterval(String value) {
  final normalized = value.trim();
  return normalized.isEmpty
      ? defaultSplitTunnelRemoteUpdateInterval
      : normalized;
}

SplitTunnelRuleGroup _readLegacyDirectGroup(Map<String, dynamic> json) {
  final rawCustomRuleSets = json['customRuleSets'];
  return SplitTunnelRuleGroup(
    geositeTags: _readStringList(json['geositeTags']),
    geoipTags: _readStringList(json['geoipTags']),
    domainSuffixes: _readStringList(json['domainSuffixes']),
    ipCidrs: _readStringList(json['ipCidrs']),
    customRuleSets: rawCustomRuleSets is List
        ? [
            for (final rawRuleSet in rawCustomRuleSets)
              if (rawRuleSet is Map)
                SplitTunnelCustomRuleSet.fromJson(
                  Map<String, dynamic>.from(rawRuleSet.cast<String, dynamic>()),
                ),
          ]
        : const [],
  );
}

Map<String, dynamic>? _readJsonMap(dynamic value) {
  if (value is Map<String, dynamic>) {
    return Map<String, dynamic>.from(value);
  }
  if (value is Map) {
    return Map<String, dynamic>.from(value.cast<String, dynamic>());
  }
  return null;
}

List<String> _normalizeUniqueStrings(
  Iterable<String> values,
  String Function(String value) normalize,
) {
  final seen = <String>{};
  final result = <String>[];
  for (final value in values) {
    final normalized = normalize(value);
    if (normalized.isEmpty || !seen.add(normalized)) {
      continue;
    }
    result.add(normalized);
  }
  return result;
}

List<String> _readStringList(dynamic value) {
  if (value is! List) {
    return const [];
  }

  return [for (final item in value) item?.toString() ?? ''];
}

int? _tryParseInt(dynamic value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value?.toString() ?? '');
}

DateTime? _tryParseDateTime(dynamic value) {
  if (value == null) {
    return null;
  }
  return DateTime.tryParse(value.toString());
}

DateTime? _latestDateTime(DateTime? left, DateTime? right) {
  if (left == null) {
    return right;
  }
  if (right == null) {
    return left;
  }
  return left.isAfter(right) ? left : right;
}

bool _listsEqual<T>(List<T> left, List<T> right) {
  if (identical(left, right)) {
    return true;
  }
  if (left.length != right.length) {
    return false;
  }
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) {
      return false;
    }
  }
  return true;
}
