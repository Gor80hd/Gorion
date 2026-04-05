import 'dart:convert';

import 'package:gorion_clean/features/auto_select/utils/auto_select_server_config.dart';
import 'package:gorion_clean/features/settings/model/connection_tuning_settings.dart';

String applyConnectionTuningSettingsToTemplateConfig({
  required String templateConfig,
  required ConnectionTuningSettings settings,
}) {
  if (!settings.hasOverrides) {
    return templateConfig;
  }

  final decoded = jsonDecode(templateConfig);
  if (decoded is! Map) {
    throw const FormatException(
      'The saved subscription config is not valid JSON.',
    );
  }

  final config = Map<String, dynamic>.from(decoded.cast<String, dynamic>());
  final rawOutbounds = config['outbounds'];
  if (rawOutbounds is! List) {
    return templateConfig;
  }

  config['outbounds'] = [
    for (final rawOutbound in rawOutbounds)
      if (rawOutbound is Map)
        _applyOverridesToOutbound(
          Map<String, dynamic>.from(rawOutbound.cast<String, dynamic>()),
          settings,
        )
      else
        rawOutbound,
  ];

  return const JsonEncoder.withIndent('  ').convert(config);
}

Map<String, dynamic> _applyOverridesToOutbound(
  Map<String, dynamic> outbound,
  ConnectionTuningSettings settings,
) {
  final type = outbound['type']?.toString().trim().toLowerCase() ?? '';

  if (type == 'vless') {
    if (settings.forceVisionFlow && _supportsVisionFlow(outbound)) {
      outbound['flow'] = 'xtls-rprx-vision';
    }
    if (settings.forceXudpPacketEncoding) {
      outbound['packet_encoding'] = 'xudp';
    }
    if (settings.enableMultiplex) {
      final multiplex = _cloneMap(outbound['multiplex']);
      multiplex['enabled'] = true;
      outbound['multiplex'] = multiplex;
    }
  }

  if (settings.forceChromeUtls ||
      settings.normalizedSniDonor.isNotEmpty ||
      settings.enableTlsRecordFragment) {
    final tlsValue = outbound['tls'];
    if (tlsValue is Map) {
      final tls = Map<String, dynamic>.from(tlsValue.cast<String, dynamic>());
      tls.putIfAbsent('enabled', () => true);
      if (settings.forceChromeUtls) {
        final utls = _cloneMap(tls['utls']);
        utls['enabled'] = true;
        utls['fingerprint'] = 'chrome';
        tls['utls'] = utls;
      }
      if (settings.normalizedSniDonor.isNotEmpty) {
        tls['server_name'] = settings.normalizedSniDonor;
      }
      if (settings.enableTlsRecordFragment) {
        tls['record_fragment'] = true;
      }
      outbound['tls'] = tls;
    }
  }

  return outbound;
}

List<String> describeConnectionTuningDiagnostics({
  required String originalTemplateConfig,
  required String effectiveTemplateConfig,
  required ConnectionTuningSettings settings,
  String? selectedServerTag,
}) {
  if (!settings.hasOverrides) {
    return const [];
  }

  final lines = <String>[];
  final requestedParts = <String>[
    if (settings.forceChromeUtls) 'utls=chrome',
    if (settings.normalizedSniDonor.isNotEmpty)
      'server_name=${settings.normalizedSniDonor}',
    if (settings.forceVisionFlow) 'flow=xtls-rprx-vision',
    if (settings.forceXudpPacketEncoding) 'packet_encoding=xudp',
    if (settings.enableMultiplex) 'multiplex=enabled',
    if (settings.enableTlsRecordFragment) 'tls.record_fragment=on',
  ];
  lines.add('Tuning request: ${requestedParts.join(', ')}.');

  final effectiveCandidates = extractAutoSelectConfigCandidates(
    effectiveTemplateConfig,
  );
  if (effectiveCandidates.isEmpty) {
    lines.add(
      'Tuning selected outbound: no selectable outbounds in runtime template.',
    );
    return lines;
  }

  final effectiveSelectedTag =
      selectedServerTag != null && selectedServerTag.trim().isNotEmpty
      ? selectedServerTag.trim()
      : effectiveCandidates.first.tag;
  final effectiveOutbound = extractAutoSelectConfigOutbound(
    effectiveTemplateConfig,
    effectiveSelectedTag,
  );
  if (effectiveOutbound == null) {
    lines.add(
      'Tuning selected outbound: tag=$effectiveSelectedTag not found in runtime template.',
    );
    return lines;
  }

  final originalOutbound = extractAutoSelectConfigOutbound(
    originalTemplateConfig,
    effectiveSelectedTag,
  );
  final type =
      effectiveOutbound['type']?.toString().trim().toLowerCase() ?? 'unknown';
  final transportType = _transportType(effectiveOutbound);
  lines.add(
    'Tuning selected outbound: tag=$effectiveSelectedTag type=$type transport=$transportType.',
  );

  final effectiveParts = <String>[];
  final notes = <String>[];
  final effectiveTls = _tlsMap(effectiveOutbound);
  final originalTls = _tlsMap(originalOutbound);

  if (settings.forceChromeUtls) {
    final fingerprint = _utlsFingerprint(effectiveTls);
    if (fingerprint == 'chrome') {
      effectiveParts.add('utls=chrome');
    } else {
      notes.add(
        'uTLS chrome was requested, but the selected outbound does not expose tls.utls=chrome.',
      );
    }
  }

  if (settings.normalizedSniDonor.isNotEmpty) {
    final effectiveServerName = _serverName(effectiveTls);
    final originalServerName = _serverName(originalTls);
    if (effectiveServerName != null) {
      final serverNameSummary =
          originalServerName != null &&
              originalServerName.isNotEmpty &&
              originalServerName != effectiveServerName
          ? '$effectiveServerName (was $originalServerName)'
          : effectiveServerName;
      effectiveParts.add('server_name=$serverNameSummary');
      notes.add(
        'Forced SNI applies to every TLS outbound and can trigger "remote rejected SNI" if a node expects a different name.',
      );
    } else {
      notes.add(
        'SNI donor was requested, but the selected outbound has no TLS block.',
      );
    }
  }

  if (settings.forceVisionFlow) {
    final effectiveFlow = effectiveOutbound['flow']?.toString().trim();
    if (effectiveFlow == 'xtls-rprx-vision') {
      effectiveParts.add('flow=xtls-rprx-vision');
    } else {
      notes.add(
        'flow xtls-rprx-vision was skipped for the selected outbound because ${_visionSkipReason(effectiveOutbound)}.',
      );
    }
  }

  if (settings.forceXudpPacketEncoding) {
    final packetEncoding = effectiveOutbound['packet_encoding']
        ?.toString()
        .trim();
    if (packetEncoding == 'xudp') {
      effectiveParts.add('packet_encoding=xudp');
    } else {
      notes.add(
        'packet_encoding=xudp was requested, but the selected outbound did not keep it.',
      );
    }
  }

  if (settings.enableMultiplex) {
    final multiplexEnabled = _isMultiplexEnabled(effectiveOutbound);
    if (multiplexEnabled) {
      effectiveParts.add('multiplex=enabled');
    } else {
      notes.add(
        'multiplex=enabled was requested, but the selected outbound did not keep it.',
      );
    }
  }

  if (settings.enableTlsRecordFragment) {
    final recordFragment = effectiveTls?['record_fragment'] == true;
    if (recordFragment) {
      effectiveParts.add('tls.record_fragment=on');
    } else {
      notes.add(
        'tls.record_fragment was requested, but the selected outbound has no TLS record fragmentation enabled.',
      );
    }
  }

  if (effectiveParts.isNotEmpty) {
    lines.add('Tuning effective: ${effectiveParts.join(', ')}.');
  }
  for (final note in notes) {
    lines.add('Tuning note: $note');
  }

  return lines;
}

Map<String, dynamic> _cloneMap(dynamic value) {
  if (value is Map<String, dynamic>) {
    return Map<String, dynamic>.from(value);
  }
  if (value is Map) {
    return Map<String, dynamic>.from(value.cast<String, dynamic>());
  }
  return <String, dynamic>{};
}

bool _supportsVisionFlow(Map<String, dynamic> outbound) {
  if (outbound['type']?.toString().trim().toLowerCase() != 'vless') {
    return false;
  }

  final tls = _tlsMap(outbound);
  if (tls == null || tls['enabled'] != true) {
    return false;
  }

  final transportType = _transportType(outbound);
  return transportType == 'tcp';
}

String _visionSkipReason(Map<String, dynamic> outbound) {
  final tls = _tlsMap(outbound);
  if (tls == null || tls['enabled'] != true) {
    return 'it does not have TLS enabled';
  }

  final transportType = _transportType(outbound);
  if (transportType != 'tcp') {
    return 'transport=$transportType is incompatible with Vision';
  }

  return 'the outbound is incompatible with Vision';
}

Map<String, dynamic>? _tlsMap(Map<String, dynamic>? outbound) {
  if (outbound == null) {
    return null;
  }

  final tls = outbound['tls'];
  if (tls is Map<String, dynamic>) {
    return tls;
  }
  if (tls is Map) {
    return Map<String, dynamic>.from(tls.cast<String, dynamic>());
  }
  return null;
}

String? _serverName(Map<String, dynamic>? tls) {
  final value = tls?['server_name']?.toString().trim();
  if (value == null || value.isEmpty) {
    return null;
  }
  return value;
}

String? _utlsFingerprint(Map<String, dynamic>? tls) {
  final utls = tls?['utls'];
  if (utls is Map<String, dynamic>) {
    final value = utls['fingerprint']?.toString().trim();
    if (value == null || value.isEmpty) {
      return null;
    }
    return value;
  }
  if (utls is Map) {
    final value = utls['fingerprint']?.toString().trim();
    if (value == null || value.isEmpty) {
      return null;
    }
    return value;
  }
  return null;
}

bool _isMultiplexEnabled(Map<String, dynamic> outbound) {
  final multiplex = outbound['multiplex'];
  if (multiplex is Map<String, dynamic>) {
    return multiplex['enabled'] == true;
  }
  if (multiplex is Map) {
    return multiplex['enabled'] == true;
  }
  return false;
}

String _transportType(Map<String, dynamic> outbound) {
  final transport = outbound['transport'];
  if (transport is Map<String, dynamic>) {
    final value = transport['type']?.toString().trim().toLowerCase();
    if (value != null && value.isNotEmpty) {
      return value;
    }
  }
  if (transport is Map) {
    final value = transport['type']?.toString().trim().toLowerCase();
    if (value != null && value.isNotEmpty) {
      return value;
    }
  }
  return 'tcp';
}
