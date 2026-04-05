import 'dart:convert';

const autoSelectServerTag = 'gorion-auto-selector';
const autoSelectServerEntry = ServerEntry(
  tag: autoSelectServerTag,
  displayName: 'Auto-select best',
  type: 'auto',
);

bool isAutoSelectServerTag(String? tag) => tag == autoSelectServerTag;

List<ServerEntry> buildSelectableServerEntries(List<ServerEntry> servers) {
  if (servers.isEmpty) {
    return const <ServerEntry>[];
  }

  return [autoSelectServerEntry, ...servers];
}

class SubscriptionInfo {
  const SubscriptionInfo({
    required this.upload,
    required this.download,
    required this.total,
    this.expireAt,
    this.webPageUrl,
    this.supportUrl,
  });

  final int upload;
  final int download;
  final int total;
  final DateTime? expireAt;
  final String? webPageUrl;
  final String? supportUrl;

  int get consumed => upload + download;
  int? get remaining => total > 0 ? total - consumed : null;

  Map<String, dynamic> toJson() {
    return {
      'upload': upload,
      'download': download,
      'total': total,
      'expireAt': expireAt?.toIso8601String(),
      'webPageUrl': webPageUrl,
      'supportUrl': supportUrl,
    };
  }

  factory SubscriptionInfo.fromJson(Map<String, dynamic> json) {
    return SubscriptionInfo(
      upload: (json['upload'] as num?)?.toInt() ?? 0,
      download: (json['download'] as num?)?.toInt() ?? 0,
      total: (json['total'] as num?)?.toInt() ?? 0,
      expireAt: json['expireAt'] == null
          ? null
          : DateTime.tryParse(json['expireAt'].toString()),
      webPageUrl: json['webPageUrl']?.toString(),
      supportUrl: json['supportUrl']?.toString(),
    );
  }
}

class ServerEntry {
  const ServerEntry({
    required this.tag,
    required this.displayName,
    required this.type,
    this.host,
    this.port,
    this.configFingerprint,
  });

  final String tag;
  final String displayName;
  final String type;
  final String? host;
  final int? port;
  final String? configFingerprint;

  Map<String, dynamic> toJson() {
    return {
      'tag': tag,
      'displayName': displayName,
      'type': type,
      'host': host,
      'port': port,
      'configFingerprint': configFingerprint,
    };
  }

  factory ServerEntry.fromJson(Map<String, dynamic> json) {
    return ServerEntry(
      tag: json['tag']?.toString() ?? '',
      displayName: json['displayName']?.toString() ?? '',
      type: json['type']?.toString() ?? '',
      host: json['host']?.toString(),
      port: (json['port'] as num?)?.toInt(),
      configFingerprint: json['configFingerprint']?.toString(),
    );
  }
}

class ProxyProfile {
  const ProxyProfile({
    required this.id,
    required this.name,
    required this.subscriptionUrl,
    required this.templateFileName,
    required this.createdAt,
    required this.updatedAt,
    required this.servers,
    this.subscriptionInfo,
    this.lastSelectedServerTag,
    this.lastAutoSelectedServerTag,
  });

  final String id;
  final String name;
  final String subscriptionUrl;
  final String templateFileName;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<ServerEntry> servers;
  final SubscriptionInfo? subscriptionInfo;
  final String? lastSelectedServerTag;
  final String? lastAutoSelectedServerTag;

  String? get selectedServerTag {
    if (isAutoSelectServerTag(lastSelectedServerTag)) {
      return autoSelectServerTag;
    }
    if (_containsServerTag(lastSelectedServerTag)) {
      return lastSelectedServerTag;
    }
    if (servers.isEmpty) {
      return null;
    }
    return servers.first.tag;
  }

  bool get prefersAutoSelection => isAutoSelectServerTag(selectedServerTag);

  String? get resolvedAutoSelectedServerTag {
    if (_containsServerTag(lastAutoSelectedServerTag)) {
      return lastAutoSelectedServerTag;
    }
    return null;
  }

  String? get startupServerTag {
    if (servers.isEmpty) {
      return null;
    }

    if (prefersAutoSelection) {
      return resolvedAutoSelectedServerTag ?? servers.first.tag;
    }

    return selectedServerTag;
  }

  bool _containsServerTag(String? serverTag) {
    if (serverTag == null || serverTag.isEmpty) {
      return false;
    }

    for (final server in servers) {
      if (server.tag == serverTag) {
        return true;
      }
    }
    return false;
  }

  ProxyProfile copyWith({
    String? id,
    String? name,
    String? subscriptionUrl,
    String? templateFileName,
    DateTime? createdAt,
    DateTime? updatedAt,
    List<ServerEntry>? servers,
    SubscriptionInfo? subscriptionInfo,
    bool clearSubscriptionInfo = false,
    String? lastSelectedServerTag,
    bool clearLastSelectedServerTag = false,
    String? lastAutoSelectedServerTag,
    bool clearLastAutoSelectedServerTag = false,
  }) {
    return ProxyProfile(
      id: id ?? this.id,
      name: name ?? this.name,
      subscriptionUrl: subscriptionUrl ?? this.subscriptionUrl,
      templateFileName: templateFileName ?? this.templateFileName,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      servers: servers ?? this.servers,
      subscriptionInfo: clearSubscriptionInfo
          ? null
          : subscriptionInfo ?? this.subscriptionInfo,
      lastSelectedServerTag: clearLastSelectedServerTag
          ? null
          : lastSelectedServerTag ?? this.lastSelectedServerTag,
      lastAutoSelectedServerTag: clearLastAutoSelectedServerTag
          ? null
          : lastAutoSelectedServerTag ?? this.lastAutoSelectedServerTag,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'subscriptionUrl': subscriptionUrl,
      'templateFileName': templateFileName,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'servers': servers.map((server) => server.toJson()).toList(),
      'subscriptionInfo': subscriptionInfo?.toJson(),
      'lastSelectedServerTag': lastSelectedServerTag,
      'lastAutoSelectedServerTag': lastAutoSelectedServerTag,
    };
  }

  factory ProxyProfile.fromJson(Map<String, dynamic> json) {
    final servers = (json['servers'] as List? ?? const [])
        .whereType<Map>()
        .map(
          (item) => ServerEntry.fromJson(
            Map<String, dynamic>.from(item.cast<String, dynamic>()),
          ),
        )
        .toList(growable: false);

    return ProxyProfile(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      subscriptionUrl: json['subscriptionUrl']?.toString() ?? '',
      templateFileName: json['templateFileName']?.toString() ?? '',
      createdAt:
          DateTime.tryParse(json['createdAt']?.toString() ?? '') ??
          DateTime.now(),
      updatedAt:
          DateTime.tryParse(json['updatedAt']?.toString() ?? '') ??
          DateTime.now(),
      servers: servers,
      subscriptionInfo: json['subscriptionInfo'] is Map
          ? SubscriptionInfo.fromJson(
              Map<String, dynamic>.from(
                (json['subscriptionInfo'] as Map).cast<String, dynamic>(),
              ),
            )
          : null,
      lastSelectedServerTag: json['lastSelectedServerTag']?.toString(),
      lastAutoSelectedServerTag: json['lastAutoSelectedServerTag']?.toString(),
    );
  }
}

class ParsedSubscription {
  const ParsedSubscription({
    required this.name,
    required this.normalizedConfigJson,
    required this.servers,
    this.subscriptionInfo,
  });

  final String name;
  final String normalizedConfigJson;
  final List<ServerEntry> servers;
  final SubscriptionInfo? subscriptionInfo;
}

class StoredProfilesState {
  const StoredProfilesState({this.activeProfileId, this.profiles = const []});

  final String? activeProfileId;
  final List<ProxyProfile> profiles;

  ProxyProfile? get activeProfile {
    final targetId = activeProfileId;
    if (targetId == null || targetId.isEmpty) {
      return null;
    }
    for (final profile in profiles) {
      if (profile.id == targetId) {
        return profile;
      }
    }
    return null;
  }

  StoredProfilesState copyWith({
    String? activeProfileId,
    bool clearActiveProfileId = false,
    List<ProxyProfile>? profiles,
  }) {
    return StoredProfilesState(
      activeProfileId: clearActiveProfileId
          ? null
          : activeProfileId ?? this.activeProfileId,
      profiles: profiles ?? this.profiles,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'activeProfileId': activeProfileId,
      'profiles': profiles.map((profile) => profile.toJson()).toList(),
    };
  }

  factory StoredProfilesState.fromJson(Map<String, dynamic> json) {
    final profiles = (json['profiles'] as List? ?? const [])
        .whereType<Map>()
        .map(
          (item) => ProxyProfile.fromJson(
            Map<String, dynamic>.from(item.cast<String, dynamic>()),
          ),
        )
        .toList(growable: false);

    return StoredProfilesState(
      activeProfileId: json['activeProfileId']?.toString(),
      profiles: profiles,
    );
  }

  @override
  String toString() => jsonEncode(toJson());
}
