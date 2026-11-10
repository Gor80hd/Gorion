import 'dart:convert';

import 'package:gorion/features/auto_select/model/auto_select_state.dart';
import 'package:gorion/features/auto_select/utils/auto_select_server_config.dart';
import 'package:gorion/features/home/application/server_lookup.dart';
import 'package:gorion/features/profiles/data/profile_repository.dart';
import 'package:gorion/features/profiles/model/profile_models.dart';
import 'package:gorion/features/settings/data/connection_tuning_config_overrides.dart';
import 'package:gorion/features/settings/model/connection_tuning_settings.dart';

/// Works out which servers of a profile auto-select may consider.
///
/// Excluded servers are dropped and exact duplicates collapsed. Duplicate
/// detection needs a config fingerprint per server; when the stored profile
/// lacks them they are derived from the effective template config, which is
/// cached per profile and tuning settings.
class AutoSelectCandidateResolver {
  AutoSelectCandidateResolver(this._repository);

  final ProfileRepository _repository;
  final _effectiveTemplateConfigs = <String, String>{};
  final _fingerprints = <String, Map<String, String>>{};

  /// Drops cached configs for [profileId], or for every profile when null.
  void invalidate([String? profileId]) {
    if (profileId == null) {
      _effectiveTemplateConfigs.clear();
      _fingerprints.clear();
      return;
    }
    bool belongsToProfile(String key, Object? _) =>
        key.startsWith('$profileId::');
    _effectiveTemplateConfigs.removeWhere(belongsToProfile);
    _fingerprints.removeWhere(belongsToProfile);
  }

  /// Non-excluded servers, deduplicated with the fingerprints already stored.
  List<ServerEntry> eligible(
    ProxyProfile profile,
    AutoSelectSettings settings,
  ) {
    return deduplicateExactServers([
      for (final server in profile.servers)
        if (!settings.isExcluded(profile.id, server.tag)) server,
    ]);
  }

  /// Like [eligible], but fills in missing fingerprints from the effective
  /// template config first. Falls back to [eligible] if that config cannot
  /// be loaded.
  Future<List<ServerEntry>> resolveEligible(
    ProxyProfile profile, {
    required AutoSelectSettings settings,
    required ConnectionTuningSettings tuning,
    String? templateConfig,
  }) async {
    final eligibleServers = eligible(profile, settings);
    if (eligibleServers.length <= 1 ||
        eligibleServers.every(
          (server) => (server.configFingerprint ?? '').isNotEmpty,
        )) {
      return eligibleServers;
    }

    try {
      final cacheKey = _cacheKey(profile.id, tuning);
      final fingerprintByTag = _fingerprints[cacheKey] ??= {
        for (final candidate in extractAutoSelectConfigCandidates(
          templateConfig ?? await _effectiveTemplateConfig(profile, tuning),
        ))
          candidate.tag: candidate.configFingerprint,
      };
      if (fingerprintByTag.isEmpty) {
        return eligibleServers;
      }
      return deduplicateExactServers([
        for (final server in eligibleServers)
          if ((server.configFingerprint ?? '').isNotEmpty)
            server
          else
            ServerEntry(
              tag: server.tag,
              displayName: server.displayName,
              type: server.type,
              host: server.host,
              port: server.port,
              configFingerprint: fingerprintByTag[server.tag],
            ),
      ]);
    } on Object {
      return eligibleServers;
    }
  }

  Future<String> _effectiveTemplateConfig(
    ProxyProfile profile,
    ConnectionTuningSettings tuning,
  ) async {
    final cacheKey = _cacheKey(profile.id, tuning);
    final cached = _effectiveTemplateConfigs[cacheKey];
    if (cached != null) {
      return cached;
    }
    final resolved = applyConnectionTuningSettingsToTemplateConfig(
      templateConfig: await _repository.loadTemplateConfig(profile),
      settings: tuning,
    );
    _effectiveTemplateConfigs[cacheKey] = resolved;
    return resolved;
  }

  // A full JSON key: hashCode collisions would silently hand a profile the
  // wrong effective config.
  String _cacheKey(String profileId, ConnectionTuningSettings tuning) {
    return '$profileId::${jsonEncode(tuning.toJson())}';
  }
}
