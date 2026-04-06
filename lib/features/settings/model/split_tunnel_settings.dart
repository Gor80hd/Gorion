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

class SplitTunnelSettings {
  const SplitTunnelSettings({
    this.enabled = false,
    this.geositeTags = const [],
    this.geoipTags = const [],
    this.domainSuffixes = const [],
    this.ipCidrs = const [],
    this.customRuleSets = const [],
    this.remoteUpdateInterval = defaultSplitTunnelRemoteUpdateInterval,
    this.remoteRevision = 0,
    this.lastRemoteRefreshAt,
  });

  final bool enabled;
  final List<String> geositeTags;
  final List<String> geoipTags;
  final List<String> domainSuffixes;
  final List<String> ipCidrs;
  final List<SplitTunnelCustomRuleSet> customRuleSets;
  final String remoteUpdateInterval;
  final int remoteRevision;
  final DateTime? lastRemoteRefreshAt;

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

  String get normalizedRemoteUpdateInterval {
    return normalizeSplitTunnelUpdateInterval(remoteUpdateInterval);
  }

  bool get hasRules {
    return normalizedGeositeTags.isNotEmpty ||
        normalizedGeoipTags.isNotEmpty ||
        normalizedDomainSuffixes.isNotEmpty ||
        normalizedIpCidrs.isNotEmpty ||
        activeCustomRuleSets.isNotEmpty;
  }

  bool get hasOverrides => enabled && hasRules;

  bool get hasManagedRemoteSources {
    return normalizedGeositeTags.isNotEmpty || normalizedGeoipTags.isNotEmpty;
  }

  bool get hasRemoteSources {
    return hasManagedRemoteSources ||
        activeCustomRuleSets.any((ruleSet) => ruleSet.isRemote);
  }

  SplitTunnelSettings copyWith({
    bool? enabled,
    List<String>? geositeTags,
    List<String>? geoipTags,
    List<String>? domainSuffixes,
    List<String>? ipCidrs,
    List<SplitTunnelCustomRuleSet>? customRuleSets,
    String? remoteUpdateInterval,
    int? remoteRevision,
    DateTime? lastRemoteRefreshAt,
    bool clearLastRemoteRefreshAt = false,
  }) {
    return SplitTunnelSettings(
      enabled: enabled ?? this.enabled,
      geositeTags: geositeTags ?? this.geositeTags,
      geoipTags: geoipTags ?? this.geoipTags,
      domainSuffixes: domainSuffixes ?? this.domainSuffixes,
      ipCidrs: ipCidrs ?? this.ipCidrs,
      customRuleSets: customRuleSets ?? this.customRuleSets,
      remoteUpdateInterval: remoteUpdateInterval ?? this.remoteUpdateInterval,
      remoteRevision: remoteRevision ?? this.remoteRevision,
      lastRemoteRefreshAt: clearLastRemoteRefreshAt
          ? null
          : lastRemoteRefreshAt ?? this.lastRemoteRefreshAt,
    );
  }

  SplitTunnelSettings bumpedRemoteRevision() {
    return copyWith(
      remoteRevision: DateTime.now().microsecondsSinceEpoch,
      lastRemoteRefreshAt: DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'enabled': enabled,
      'geositeTags': normalizedGeositeTags,
      'geoipTags': normalizedGeoipTags,
      'domainSuffixes': normalizedDomainSuffixes,
      'ipCidrs': normalizedIpCidrs,
      'customRuleSets': [
        for (final ruleSet in normalizedCustomRuleSets) ruleSet.toJson(),
      ],
      'remoteUpdateInterval': normalizedRemoteUpdateInterval,
      'remoteRevision': remoteRevision,
      'lastRemoteRefreshAt': lastRemoteRefreshAt?.toIso8601String(),
    };
  }

  factory SplitTunnelSettings.fromJson(Map<String, dynamic> json) {
    final rawCustomRuleSets = json['customRuleSets'];
    return SplitTunnelSettings(
      enabled: json['enabled'] as bool? ?? false,
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
      remoteUpdateInterval:
          json['remoteUpdateInterval']?.toString().trim() ??
          defaultSplitTunnelRemoteUpdateInterval,
      remoteRevision: _tryParseInt(json['remoteRevision']) ?? 0,
      lastRemoteRefreshAt: _tryParseDateTime(json['lastRemoteRefreshAt']),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is SplitTunnelSettings &&
        other.enabled == enabled &&
        _listsEqual(other.normalizedGeositeTags, normalizedGeositeTags) &&
        _listsEqual(other.normalizedGeoipTags, normalizedGeoipTags) &&
        _listsEqual(other.normalizedDomainSuffixes, normalizedDomainSuffixes) &&
        _listsEqual(other.normalizedIpCidrs, normalizedIpCidrs) &&
        _listsEqual(other.normalizedCustomRuleSets, normalizedCustomRuleSets) &&
        other.normalizedRemoteUpdateInterval ==
            normalizedRemoteUpdateInterval &&
        other.remoteRevision == remoteRevision &&
        other.lastRemoteRefreshAt?.toIso8601String() ==
            lastRemoteRefreshAt?.toIso8601String();
  }

  @override
  int get hashCode => Object.hash(
    enabled,
    Object.hashAll(normalizedGeositeTags),
    Object.hashAll(normalizedGeoipTags),
    Object.hashAll(normalizedDomainSuffixes),
    Object.hashAll(normalizedIpCidrs),
    Object.hashAll(normalizedCustomRuleSets),
    normalizedRemoteUpdateInterval,
    remoteRevision,
    lastRemoteRefreshAt?.toIso8601String(),
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
