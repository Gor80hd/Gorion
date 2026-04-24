part of 'servers_panel.dart';

bool _isLeafServer(OutboundInfo item) {
  final type = item.type.trim().toLowerCase();
  return item.isVisible && !item.isGroup && _proxySchemes.contains(type);
}

List<OutboundInfo> _visibleServers(OutboundGroup group) =>
    group.items.where(_isLeafServer).toList();

String _flagEmoji(String code) {
  if (code.length != 2) return '';
  const base = 0x1F1E6 - 0x41;
  final upper = code.toUpperCase();
  return String.fromCharCodes(upper.codeUnits.map((c) => base + c));
}

String? _extractCountryCode(String tag) {
  final bracketMatch = RegExp(r'^\[([A-Za-z]{2})\]').firstMatch(tag);
  if (bracketMatch != null) {
    return bracketMatch.group(1)!.toUpperCase();
  }

  final runes = tag.runes.toList(growable: false);
  for (var i = 0; i < runes.length - 1; i++) {
    final first = runes[i];
    final second = runes[i + 1];
    if (first >= 0x1F1E6 &&
        first <= 0x1F1FF &&
        second >= 0x1F1E6 &&
        second <= 0x1F1FF) {
      return String.fromCharCodes([
        0x41 + first - 0x1F1E6,
        0x41 + second - 0x1F1E6,
      ]);
    }
  }

  return null;
}

String _stripCountryPrefix(String name) {
  final stripped = name.replaceFirst(RegExp(r'^\[[A-Za-z]{2}\]\s*'), '');
  if (stripped != name) return stripped;

  final runes = name.runes.toList(growable: false);
  if (runes.length >= 2 &&
      runes[0] >= 0x1F1E6 &&
      runes[0] <= 0x1F1FF &&
      runes[1] >= 0x1F1E6 &&
      runes[1] <= 0x1F1FF) {
    var skip = 2;
    while (skip < runes.length && runes[skip] == 0x20) {
      skip++;
    }
    return String.fromCharCodes(runes.skip(skip));
  }

  return name;
}

String _displayName(OutboundInfo info) {
  final raw = info.tagDisplay.isNotEmpty ? info.tagDisplay : info.tag;
  return normalizeServerDisplayText(raw);
}

Color _typeColor(String type, Color primary) {
  return switch (type.toLowerCase()) {
    'auto' => primary,
    'vless' => primary,
    'vmess' => const Color(0xFF6366F1),
    'trojan' => const Color(0xFFF59E0B),
    'shadowsocks' || 'ss' => const Color(0xFF3B82F6),
    'hysteria' || 'hysteria2' => const Color(0xFFEC4899),
    'tuic' => const Color(0xFF8B5CF6),
    _ => const Color(0xFF6B7280),
  };
}

Color _pingColor(int ms) {
  if (ms <= 0) return const Color(0xFF6B7280);
  if (ms < 100) return const Color(0xFF22C55E);
  if (ms < 300) return const Color(0xFFF59E0B);
  return const Color(0xFFEF4444);
}

Color _softAccentSurface(ThemeData theme, {double emphasis = 1.0}) {
  final mix = theme.brightness == Brightness.dark ? 0.26 : 0.12;
  return Color.lerp(
    theme.colorScheme.surface,
    theme.brandAccent,
    (mix * emphasis).clamp(0.0, 1.0).toDouble(),
  )!;
}

Color _softAccentFill(ThemeData theme, {double emphasis = 1.0}) {
  final alpha = theme.brightness == Brightness.dark ? 0.18 : 0.08;
  return theme.brandAccent.withValues(
    alpha: (alpha * emphasis).clamp(0.0, 1.0).toDouble(),
  );
}

Color _softAccentBorder(ThemeData theme, {double emphasis = 1.0}) {
  final alpha = theme.brightness == Brightness.dark ? 0.28 : 0.14;
  return theme.brandAccent.withValues(
    alpha: (alpha * emphasis).clamp(0.0, 1.0).toDouble(),
  );
}

Color _softAccentForeground(ThemeData theme, {double emphasis = 1.0}) {
  final alpha = theme.brightness == Brightness.dark ? 0.96 : 0.92;
  return theme.colorScheme.onSurface.withValues(
    alpha: (alpha * emphasis).clamp(0.0, 1.0).toDouble(),
  );
}

String _formatBytesCompact(int bytes) {
  if (bytes <= 0) return '0 B';

  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var size = bytes.toDouble();
  var unitIndex = 0;

  while (size >= 1024 && unitIndex < units.length - 1) {
    size /= 1024;
    unitIndex++;
  }

  final decimals = switch (unitIndex) {
    0 => 0,
    1 => 0,
    2 => 1,
    _ => 2,
  };
  return '${size.toStringAsFixed(decimals)} ${units[unitIndex]}';
}

String _formatRate(int bytesPerSecond) =>
    '${_formatBytesCompact(bytesPerSecond)}/s';

String _formatElapsed(Duration value) {
  String two(int n) => n.toString().padLeft(2, '0');
  final hours = value.inHours;
  final minutes = value.inMinutes.remainder(60);
  final seconds = value.inSeconds.remainder(60);
  if (hours > 0) {
    return '${two(hours)}:${two(minutes)}:${two(seconds)}';
  }
  return '${two(minutes)}:${two(seconds)}';
}

String _formatBestServerCheckIntervalBadge(int minutes) {
  final hours = minutes ~/ 60;
  final remainingMinutes = minutes % 60;
  if (hours <= 0) {
    return '$minutesм';
  }
  if (remainingMinutes == 0) {
    return '$hoursч';
  }
  return '$hoursч $remainingMinutesм';
}

const _groupTypes = {'selector', 'urltest', 'url-test'};
const _proxySchemes = {
  'http',
  'hysteria',
  'hysteria2',
  'hy',
  'hy2',
  'mieru',
  'naive',
  'shadowtls',
  'shadowsocks',
  'shadowsocksr',
  'socks',
  'ss',
  'ssh',
  'trojan',
  'tuic',
  'vless',
  'vmess',
  'warp',
  'wg',
  'wireguard',
};

class _ParsedOfflineGroup {
  const _ParsedOfflineGroup({
    required this.tag,
    required this.selectedTag,
    required this.items,
  });

  final String tag;
  final String? selectedTag;
  final List<OutboundInfo> items;
}

String _benchmarkKey(String profileId, String serverTag) =>
    buildServerBenchmarkKey(profileId, serverTag);

_ParsedOfflineGroup? _parseOfflineGroup(
  String rawConfig, {
  required String fallbackGroupName,
}) {
  final decoded = safeDecodeBase64(rawConfig).trim();
  if (decoded.isEmpty) return null;

  return _parseJsonOfflineGroup(
        decoded,
        fallbackGroupName: fallbackGroupName,
      ) ??
      _parseLinkOfflineGroup(decoded, fallbackGroupName: fallbackGroupName);
}

_ParsedOfflineGroup? _parseJsonOfflineGroup(
  String content, {
  required String fallbackGroupName,
}) {
  final jsonText = _extractJsonPayload(content);
  if (jsonText == null) return null;

  try {
    final decoded = jsonDecode(jsonText);
    final groups =
        <
          ({String tag, String type, String? selected, List<String> outbounds})
        >[];
    final proxies = <String, OutboundInfo>{};

    void visit(dynamic node) {
      if (node is List) {
        for (final item in node) {
          visit(item);
        }
        return;
      }
      if (node is! Map) return;

      final map = Map<String, dynamic>.from(node.cast<String, dynamic>());
      final tag = map['tag']?.toString().trim();
      final type = (map['type'] ?? map['protocol'])
          ?.toString()
          .trim()
          .toLowerCase();
      final outbounds = map['outbounds'];

      if (tag != null && tag.isNotEmpty && type != null && type.isNotEmpty) {
        if (_groupTypes.contains(type) && outbounds is List) {
          final tags = outbounds
              .map((entry) => entry?.toString().trim())
              .whereType<String>()
              .where((entry) => entry.isNotEmpty)
              .toList();
          if (tags.isNotEmpty) {
            groups.add((
              tag: tag,
              type: type,
              selected: map['selected']?.toString(),
              outbounds: tags,
            ));
          }
        } else if (_proxySchemes.contains(type)) {
          final serverHost = map['server']?.toString().trim() ?? '';
          final serverPort =
              int.tryParse(map['server_port']?.toString() ?? '') ?? 0;
          proxies[tag] = OutboundInfo(
            tag: tag,
            tagDisplay: tag,
            type: _normalizeType(type),
            isVisible: true,
            isGroup: false,
            host: serverHost,
            port: serverPort,
          );
        }
      }

      for (final value in map.values) {
        visit(value);
      }
    }

    visit(decoded);

    for (final group in groups) {
      final items = group.outbounds
          .map((tag) => proxies[tag])
          .whereType<OutboundInfo>()
          .toList();
      if (items.isNotEmpty) {
        return _ParsedOfflineGroup(
          tag: group.tag,
          selectedTag: group.selected,
          items: items,
        );
      }
    }

    if (proxies.isEmpty) return null;
    return _ParsedOfflineGroup(
      tag: fallbackGroupName,
      selectedTag: null,
      items: proxies.values.toList(),
    );
  } catch (_) {
    return null;
  }
}

_ParsedOfflineGroup? _parseLinkOfflineGroup(
  String content, {
  required String fallbackGroupName,
}) {
  final lines = safeDecodeBase64(content)
      .split(RegExp(r'\r?\n'))
      .map((line) => line.trim())
      .where(
        (line) =>
            line.isNotEmpty && !line.startsWith('#') && !line.startsWith('//'),
      );

  final items = <OutboundInfo>[];
  for (final line in lines) {
    final uri = Uri.tryParse(line);
    if (uri == null || !_proxySchemes.contains(uri.scheme.toLowerCase())) {
      continue;
    }

    final name = uri.hasFragment
        ? Uri.decodeComponent(uri.fragment.split(' -> ').first).trim()
        : '';
    final displayName = name.isNotEmpty ? name : uri.scheme.toUpperCase();
    items.add(
      OutboundInfo(
        tag: displayName,
        tagDisplay: displayName,
        type: _normalizeType(uri.scheme),
        isVisible: true,
        isGroup: false,
        host: uri.host,
        port: uri.port,
      ),
    );
  }

  if (items.isEmpty) return null;
  return _ParsedOfflineGroup(
    tag: fallbackGroupName,
    selectedTag: null,
    items: items,
  );
}

String? _extractJsonPayload(String content) {
  final startIndex = content.indexOf('{');
  if (startIndex == -1) return null;

  final endIndex = content.lastIndexOf('}');
  if (endIndex <= startIndex) return null;

  return content.substring(startIndex, endIndex + 1);
}

String _normalizeType(String type) {
  return switch (type.toLowerCase()) {
    'hy' => 'hysteria',
    'hy2' => 'hysteria2',
    'ss' => 'shadowsocks',
    'wg' => 'wireguard',
    _ => type.toLowerCase(),
  };
}

OutboundGroup? _toOutboundGroup(_ParsedOfflineGroup? group) {
  if (group == null || group.items.isEmpty) return null;

  return OutboundGroup(
    tag: group.tag,
    type: 'selector',
    selected: group.selectedTag ?? '',
    items: [
      for (final item in group.items)
        item.clone()
          ..isSelected =
              group.selectedTag != null && item.tag == group.selectedTag
          ..isVisible = true
          ..isGroup = false,
    ],
  );
}
