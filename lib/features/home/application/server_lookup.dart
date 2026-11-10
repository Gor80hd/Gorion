import 'package:gorion_clean/features/auto_select/data/auto_selector_service.dart';
import 'package:gorion_clean/features/profiles/model/profile_models.dart';
import 'package:gorion_clean/utils/server_display_text.dart';

/// Drops servers whose outbound config is byte-for-byte identical to an
/// earlier one. Servers without a fingerprint are always kept.
List<ServerEntry> deduplicateExactServers(List<ServerEntry> servers) {
  final deduplicated = <ServerEntry>[];
  final seenFingerprints = <String>{};

  for (final server in servers) {
    final fingerprint = server.configFingerprint;
    if (fingerprint == null || fingerprint.isEmpty) {
      deduplicated.add(server);
      continue;
    }
    if (!seenFingerprints.add(fingerprint)) {
      continue;
    }
    deduplicated.add(server);
  }

  return deduplicated;
}

ServerEntry? findServerByTag(List<ServerEntry> servers, String? serverTag) {
  if (serverTag == null || serverTag.isEmpty) {
    return null;
  }

  for (final server in servers) {
    if (server.tag == serverTag) {
      return server;
    }
  }
  return null;
}

String serverNameForTag(List<ServerEntry> servers, String serverTag) {
  final server = findServerByTag(servers, serverTag);
  final raw = server?.displayName ?? serverTag;
  return normalizeServerDisplayText(raw);
}

AutoSelectProbeResult? probeByServerTag(
  List<AutoSelectProbeResult> probes,
  String? serverTag,
) {
  if (serverTag == null || serverTag.isEmpty) {
    return null;
  }

  for (final probe in probes) {
    if (probe.serverTag == serverTag) {
      return probe;
    }
  }
  return null;
}
