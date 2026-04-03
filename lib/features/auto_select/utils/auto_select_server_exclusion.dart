import 'dart:convert';

typedef AutoSelectServerRef = ({String profileId, String serverTag});

String buildAutoSelectServerExclusionKey({
  required String profileId,
  required String serverTag,
}) {
  return jsonEncode({'profileId': profileId, 'serverTag': serverTag});
}

AutoSelectServerRef? parseAutoSelectServerExclusionKey(String value) {
  try {
    final decoded = jsonDecode(value);
    if (decoded is! Map) {
      return null;
    }

    final map = Map<String, dynamic>.from(decoded.cast<String, dynamic>());
    final profileId = map['profileId']?.toString().trim() ?? '';
    final serverTag = map['serverTag']?.toString().trim() ?? '';
    if (profileId.isEmpty || serverTag.isEmpty) {
      return null;
    }

    return (profileId: profileId, serverTag: serverTag);
  } catch (_) {
    return null;
  }
}

bool isAutoSelectServerExcluded(
  Iterable<String> exclusionKeys, {
  required String profileId,
  required String serverTag,
}) {
  final targetKey = buildAutoSelectServerExclusionKey(
    profileId: profileId,
    serverTag: serverTag,
  );
  for (final key in exclusionKeys) {
    if (key == targetKey) {
      return true;
    }
  }
  return false;
}
