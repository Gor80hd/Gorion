import 'dart:convert';

import 'package:gorion_clean/features/auto_select/utils/auto_select_server_exclusion.dart';

const defaultAutoSelectDomainProbeUrl = 'https://www.gstatic.com/generate_204';
const defaultAutoSelectIpProbeUrl = 'http://1.1.1.1';
const defaultAutoSelectThroughputProbeUrl =
    'https://speed.cloudflare.com/__down?bytes=131072';
const defaultAutoSelectDomainProbeUrls = <String>[
  defaultAutoSelectDomainProbeUrl,
  'https://cp.cloudflare.com/generate_204',
  'https://www.msftconnecttest.com/connecttest.txt',
];
const defaultAutoSelectIpProbeUrls = <String>[
  defaultAutoSelectIpProbeUrl,
  'http://1.0.0.1',
  'http://1.1.1.1/cdn-cgi/trace',
];
const defaultAutoSelectThroughputProbeUrls = <String>[
  defaultAutoSelectThroughputProbeUrl,
  'https://httpbingo.org/bytes/131072',
  'https://httpbin.org/bytes/131072',
];
const defaultRecentAutoSelectedServerTtl = Duration(seconds: 75);
const defaultRecentSuccessfulAutoConnectTtl = Duration(seconds: 90);

List<String> resolveAutoSelectDomainProbeUrls(
  String configuredUrl, {
  required String rotationKey,
}) {
  return _resolveAutoSelectProbeUrls(
    configuredUrl: configuredUrl,
    defaultUrl: defaultAutoSelectDomainProbeUrl,
    defaultUrls: defaultAutoSelectDomainProbeUrls,
    rotationKey: rotationKey,
  );
}

List<String> resolveAutoSelectIpProbeUrls(
  String configuredUrl, {
  required String rotationKey,
}) {
  return _resolveAutoSelectProbeUrls(
    configuredUrl: configuredUrl,
    defaultUrl: defaultAutoSelectIpProbeUrl,
    defaultUrls: defaultAutoSelectIpProbeUrls,
    rotationKey: rotationKey,
  );
}

List<String> resolveAutoSelectThroughputProbeUrls(
  String configuredUrl, {
  required String rotationKey,
}) {
  return _resolveAutoSelectProbeUrls(
    configuredUrl: configuredUrl,
    defaultUrl: defaultAutoSelectThroughputProbeUrl,
    defaultUrls: defaultAutoSelectThroughputProbeUrls,
    rotationKey: rotationKey,
  );
}

String resolveAutoSelectUrlTestUrl(
  String configuredUrl, {
  required String rotationKey,
}) {
  return resolveAutoSelectDomainProbeUrls(
    configuredUrl,
    rotationKey: rotationKey,
  ).first;
}

List<String> _resolveAutoSelectProbeUrls({
  required String configuredUrl,
  required String defaultUrl,
  required List<String> defaultUrls,
  required String rotationKey,
}) {
  final normalizedUrl = configuredUrl.trim().isEmpty ? defaultUrl : configuredUrl.trim();
  final baseUrls = normalizedUrl == defaultUrl ? defaultUrls : <String>[normalizedUrl];
  final dedupedUrls = <String>[];
  final seenUrls = <String>{};
  for (final candidate in baseUrls) {
    final normalizedCandidate = candidate.trim();
    if (normalizedCandidate.isEmpty || !seenUrls.add(normalizedCandidate)) {
      continue;
    }
    dedupedUrls.add(normalizedCandidate);
  }

  if (dedupedUrls.length <= 1) {
    return dedupedUrls;
  }

  final startIndex = _stableProbeRotationIndex(rotationKey, dedupedUrls.length);
  return [
    for (var offset = 0; offset < dedupedUrls.length; offset += 1)
      dedupedUrls[(startIndex + offset) % dedupedUrls.length],
  ];
}

int _stableProbeRotationIndex(String key, int length) {
  if (length <= 1) {
    return 0;
  }

  var hash = 0x811C9DC5;
  for (final codeUnit in key.codeUnits) {
    hash ^= codeUnit;
    hash = (hash * 0x01000193) & 0x7fffffff;
  }
  return hash % length;
}

class AutoSelectProgressEvent {
  const AutoSelectProgressEvent({
    required this.message,
    this.completedSteps,
    this.totalSteps,
  });

  final String message;
  final int? completedSteps;
  final int? totalSteps;
}

typedef AutoSelectProgressReporter =
    void Function(AutoSelectProgressEvent event);

class AutoSelectActivityState {
  const AutoSelectActivityState({
    this.active = false,
    this.label,
    this.message,
    this.completedSteps,
    this.totalSteps,
    this.logLines = const [],
  });

  final bool active;
  final String? label;
  final String? message;
  final int? completedSteps;
  final int? totalSteps;
  final List<String> logLines;

  bool get hasTrace =>
      label != null || message != null || logLines.isNotEmpty;

  double? get progressValue {
    final completed = completedSteps;
    final total = totalSteps;
    if (completed == null || total == null || total <= 0) {
      return null;
    }

    final boundedCompleted = completed < 0
        ? 0
        : (completed > total ? total : completed);
    return boundedCompleted / total;
  }

  String? get progressLabel {
    final completed = completedSteps;
    final total = totalSteps;
    if (completed == null || total == null || total <= 0) {
      return null;
    }

    final boundedCompleted = completed < 0
        ? 0
        : (completed > total ? total : completed);
    return '$boundedCompleted / $total';
  }

  AutoSelectActivityState copyWith({
    bool? active,
    String? label,
    bool clearLabel = false,
    String? message,
    bool clearMessage = false,
    int? completedSteps,
    bool clearCompletedSteps = false,
    int? totalSteps,
    bool clearTotalSteps = false,
    List<String>? logLines,
  }) {
    return AutoSelectActivityState(
      active: active ?? this.active,
      label: clearLabel ? null : label ?? this.label,
      message: clearMessage ? null : message ?? this.message,
      completedSteps: clearCompletedSteps
          ? null
          : completedSteps ?? this.completedSteps,
      totalSteps: clearTotalSteps ? null : totalSteps ?? this.totalSteps,
      logLines: logLines ?? this.logLines,
    );
  }
}

class AutoSelectSettings {
  const AutoSelectSettings({
    this.enabled = true,
    this.checkIp = true,
    this.domainProbeUrl = defaultAutoSelectDomainProbeUrl,
    this.ipProbeUrl = defaultAutoSelectIpProbeUrl,
    this.excludedServerKeys = const [],
  });

  final bool enabled;
  final bool checkIp;
  final String domainProbeUrl;
  final String ipProbeUrl;
  final List<String> excludedServerKeys;

  AutoSelectSettings copyWith({
    bool? enabled,
    bool? checkIp,
    String? domainProbeUrl,
    String? ipProbeUrl,
    List<String>? excludedServerKeys,
  }) {
    return AutoSelectSettings(
      enabled: enabled ?? this.enabled,
      checkIp: checkIp ?? this.checkIp,
      domainProbeUrl: domainProbeUrl ?? this.domainProbeUrl,
      ipProbeUrl: ipProbeUrl ?? this.ipProbeUrl,
      excludedServerKeys: excludedServerKeys ?? this.excludedServerKeys,
    );
  }

  bool isExcluded(String profileId, String serverTag) {
    return isAutoSelectServerExcluded(
      excludedServerKeys,
      profileId: profileId,
      serverTag: serverTag,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'enabled': enabled,
      'checkIp': checkIp,
      'domainProbeUrl': domainProbeUrl,
      'ipProbeUrl': ipProbeUrl,
      'excludedServerKeys': excludedServerKeys,
    };
  }

  factory AutoSelectSettings.fromJson(Map<String, dynamic> json) {
    final excludedServerKeys = (json['excludedServerKeys'] as List? ?? const [])
        .map((item) => item.toString())
        .where((item) => item.isNotEmpty)
        .toList(growable: false);

    return AutoSelectSettings(
      enabled: json['enabled'] as bool? ?? true,
      checkIp: json['checkIp'] as bool? ?? true,
      domainProbeUrl:
          json['domainProbeUrl']?.toString().trim().isNotEmpty == true
          ? json['domainProbeUrl'].toString().trim()
          : defaultAutoSelectDomainProbeUrl,
      ipProbeUrl: json['ipProbeUrl']?.toString().trim().isNotEmpty == true
          ? json['ipProbeUrl'].toString().trim()
          : defaultAutoSelectIpProbeUrl,
      excludedServerKeys: excludedServerKeys,
    );
  }
}

class RecentAutoSelectedServer {
  const RecentAutoSelectedServer({
    required this.profileId,
    required this.tag,
    required this.until,
  });

  final String profileId;
  final String tag;
  final DateTime until;

  bool get isActive => until.isAfter(DateTime.now());

  bool matchesProfile(String targetProfileId) {
    return profileId == targetProfileId && isActive;
  }

  Map<String, dynamic> toJson() {
    return {
      'profileId': profileId,
      'tag': tag,
      'until': until.toIso8601String(),
    };
  }

  factory RecentAutoSelectedServer.fromJson(Map<String, dynamic> json) {
    return RecentAutoSelectedServer(
      profileId: json['profileId']?.toString() ?? '',
      tag: json['tag']?.toString() ?? '',
      until:
          DateTime.tryParse(json['until']?.toString() ?? '') ?? DateTime.now(),
    );
  }
}

class RecentSuccessfulAutoConnect {
  const RecentSuccessfulAutoConnect({
    required this.profileId,
    required this.tag,
    required this.until,
  });

  final String profileId;
  final String tag;
  final DateTime until;

  bool get isActive => until.isAfter(DateTime.now());

  bool matchesProfile(String targetProfileId) {
    return profileId == targetProfileId && isActive;
  }

  Map<String, dynamic> toJson() {
    return {
      'profileId': profileId,
      'tag': tag,
      'until': until.toIso8601String(),
    };
  }

  factory RecentSuccessfulAutoConnect.fromJson(Map<String, dynamic> json) {
    return RecentSuccessfulAutoConnect(
      profileId: json['profileId']?.toString() ?? '',
      tag: json['tag']?.toString() ?? '',
      until:
          DateTime.tryParse(json['until']?.toString() ?? '') ?? DateTime.now(),
    );
  }
}

class StoredAutoSelectState {
  const StoredAutoSelectState({
    this.settings = const AutoSelectSettings(),
    this.recentAutoSelectedServer,
    this.recentSuccessfulAutoConnect,
  });

  final AutoSelectSettings settings;
  final RecentAutoSelectedServer? recentAutoSelectedServer;
  final RecentSuccessfulAutoConnect? recentSuccessfulAutoConnect;

  StoredAutoSelectState copyWith({
    AutoSelectSettings? settings,
    RecentAutoSelectedServer? recentAutoSelectedServer,
    bool clearRecentAutoSelectedServer = false,
    RecentSuccessfulAutoConnect? recentSuccessfulAutoConnect,
    bool clearRecentSuccessfulAutoConnect = false,
  }) {
    return StoredAutoSelectState(
      settings: settings ?? this.settings,
      recentAutoSelectedServer: clearRecentAutoSelectedServer
          ? null
          : recentAutoSelectedServer ?? this.recentAutoSelectedServer,
      recentSuccessfulAutoConnect: clearRecentSuccessfulAutoConnect
          ? null
          : recentSuccessfulAutoConnect ?? this.recentSuccessfulAutoConnect,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'settings': settings.toJson(),
      'recentAutoSelectedServer': recentAutoSelectedServer?.toJson(),
      'recentSuccessfulAutoConnect': recentSuccessfulAutoConnect?.toJson(),
    };
  }

  factory StoredAutoSelectState.fromJson(Map<String, dynamic> json) {
    return StoredAutoSelectState(
      settings: json['settings'] is Map
          ? AutoSelectSettings.fromJson(
              Map<String, dynamic>.from(
                (json['settings'] as Map).cast<String, dynamic>(),
              ),
            )
          : const AutoSelectSettings(),
      recentAutoSelectedServer: json['recentAutoSelectedServer'] is Map
          ? RecentAutoSelectedServer.fromJson(
              Map<String, dynamic>.from(
                (json['recentAutoSelectedServer'] as Map)
                    .cast<String, dynamic>(),
              ),
            )
          : null,
      recentSuccessfulAutoConnect: json['recentSuccessfulAutoConnect'] is Map
          ? RecentSuccessfulAutoConnect.fromJson(
              Map<String, dynamic>.from(
                (json['recentSuccessfulAutoConnect'] as Map)
                    .cast<String, dynamic>(),
              ),
            )
          : null,
    );
  }

  @override
  String toString() => jsonEncode(toJson());
}
