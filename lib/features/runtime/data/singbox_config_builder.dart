import 'dart:convert';

import 'package:gorion_clean/features/auto_select/utils/auto_select_server_config.dart';
import 'package:gorion_clean/features/runtime/model/runtime_mode.dart';

const managedManualSelectorTag = 'gorion-manual';
const managedAutoUrlTestTag = 'gorion-auto';
const managedMixedInboundTag = 'gorion-mixed';
const managedTunInboundTag = 'gorion-tun';
const managedTunInterfaceName = 'gorion-tun';

class BuiltRuntimeConfig {
  const BuiltRuntimeConfig({
    required this.configJson,
    required this.manualSelectorTag,
    required this.autoGroupTag,
  });

  final String configJson;
  final String manualSelectorTag;
  final String autoGroupTag;
}

class SingboxConfigBuilder {
  static BuiltRuntimeConfig build({
    required String templateConfig,
    required RuntimeMode mode,
    required int mixedPort,
    required int controllerPort,
    required String controllerSecret,
    required String urlTestUrl,
    String? selectedServerTag,
    List<String>? selectableTagsOverride,
  }) {
    final config = _decodeMap(templateConfig);
    if (config == null) {
      throw const FormatException(
        'The saved subscription config is not valid JSON.',
      );
    }

    final candidates = extractAutoSelectConfigCandidates(templateConfig);
    if (candidates.isEmpty) {
      throw const FormatException(
        'The selected profile does not expose any selectable outbounds.',
      );
    }

    final extractedSelectableTags = [
      for (final candidate in candidates) candidate.tag,
    ];
    final selectableTags = selectableTagsOverride == null
        ? extractedSelectableTags
        : [
            for (final tag in selectableTagsOverride)
              if (extractedSelectableTags.contains(tag)) tag,
          ];
    if (selectableTags.isEmpty) {
      throw const FormatException(
        'The selected profile does not expose any selectable outbounds.',
      );
    }
    final selectedTag =
        selectedServerTag != null && selectableTags.contains(selectedServerTag)
        ? selectedServerTag
        : selectableTags.first;

    final outbounds = _cloneList(config['outbounds']);
    outbounds.removeWhere((outbound) {
      final tag = outbound['tag']?.toString();
      return tag == managedManualSelectorTag || tag == managedAutoUrlTestTag;
    });

    if (!_containsTag(outbounds, 'direct')) {
      outbounds.add({'type': 'direct', 'tag': 'direct'});
    }
    if (!_containsTag(outbounds, 'block')) {
      outbounds.add({'type': 'block', 'tag': 'block'});
    }

    outbounds.add({
      'type': 'selector',
      'tag': managedManualSelectorTag,
      'outbounds': selectableTags,
      'default': selectedTag,
      'interrupt_exist_connections': true,
    });
    outbounds.add({
      'type': 'urltest',
      'tag': managedAutoUrlTestTag,
      'outbounds': selectableTags,
      'url': urlTestUrl,
      'interval': '5m',
      'tolerance': 50,
      'interrupt_exist_connections': false,
    });
    config['outbounds'] = outbounds;

    config['inbounds'] = _buildInbounds(mode: mode, mixedPort: mixedPort);

    final route = _cloneMap(config['route']);
    route['auto_detect_interface'] = true;
    route['final'] = managedManualSelectorTag;
    config['route'] = route;

    final log = _cloneMap(config['log']);
    log.putIfAbsent('level', () => 'info');
    config['log'] = log;

    final experimental = _cloneMap(config['experimental']);
    experimental['clash_api'] = {
      'external_controller': '127.0.0.1:$controllerPort',
      'secret': controllerSecret,
      'default_mode': 'Rule',
      'access_control_allow_origin': const ['*'],
    };
    config['experimental'] = experimental;

    return BuiltRuntimeConfig(
      configJson: const JsonEncoder.withIndent('  ').convert(config),
      manualSelectorTag: managedManualSelectorTag,
      autoGroupTag: managedAutoUrlTestTag,
    );
  }

  static Map<String, dynamic>? _decodeMap(String content) {
    try {
      final decoded = jsonDecode(content);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded.cast<String, dynamic>());
      }
    } catch (_) {}
    return null;
  }

  static List<Map<String, dynamic>> _cloneList(dynamic value) {
    if (value is! List) {
      return <Map<String, dynamic>>[];
    }

    return value
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item.cast<String, dynamic>()))
        .toList();
  }

  static Map<String, dynamic> _cloneMap(dynamic value) {
    if (value is Map<String, dynamic>) {
      return Map<String, dynamic>.from(value);
    }
    if (value is Map) {
      return Map<String, dynamic>.from(value.cast<String, dynamic>());
    }
    return <String, dynamic>{};
  }

  static bool _containsTag(List<Map<String, dynamic>> outbounds, String tag) {
    return outbounds.any((outbound) => outbound['tag']?.toString() == tag);
  }

  static List<Map<String, Object>> _buildInbounds({
    required RuntimeMode mode,
    required int mixedPort,
  }) {
    final inbounds = <Map<String, Object>>[
      {
        'type': 'mixed',
        'tag': managedMixedInboundTag,
        'listen': '127.0.0.1',
        'listen_port': mixedPort,
      },
    ];

    if (mode.usesTun) {
      inbounds.add({
        'type': 'tun',
        'tag': managedTunInboundTag,
        'interface_name': managedTunInterfaceName,
        'address': const ['172.19.0.1/30', 'fdfe:dcba:9876::1/126'],
        'auto_route': true,
        'strict_route': true,
        'stack': 'system',
      });
    }

    return inbounds;
  }
}
