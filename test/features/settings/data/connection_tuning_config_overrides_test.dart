import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gorion_clean/features/settings/data/connection_tuning_config_overrides.dart';
import 'package:gorion_clean/features/settings/model/connection_tuning_settings.dart';

void main() {
  group('applyConnectionTuningSettingsToTemplateConfig', () {
    test(
      'applies VLESS and TLS overrides while preserving unrelated outbounds',
      () {
        final template = jsonEncode({
          'outbounds': [
            {
              'type': 'vless',
              'tag': 'server-a',
              'server': 'a.example.com',
              'server_port': 443,
              'tls': {'enabled': true, 'server_name': 'origin.example.com'},
            },
            {
              'type': 'trojan',
              'tag': 'server-b',
              'server': 'b.example.com',
              'server_port': 443,
              'tls': {'enabled': true},
            },
            {'type': 'direct', 'tag': 'direct'},
          ],
        });

        const settings = ConnectionTuningSettings(
          forceChromeUtls: true,
          sniDonor: 'cdn.example.com',
          forceVisionFlow: true,
          forceXudpPacketEncoding: true,
          enableMultiplex: true,
          enableTlsRecordFragment: true,
        );

        final applied = applyConnectionTuningSettingsToTemplateConfig(
          templateConfig: template,
          settings: settings,
        );
        final config = jsonDecode(applied) as Map<String, dynamic>;
        final outbounds = (config['outbounds'] as List).cast<Map>();
        final vless = Map<String, dynamic>.from(
          outbounds[0].cast<String, dynamic>(),
        );
        final trojan = Map<String, dynamic>.from(
          outbounds[1].cast<String, dynamic>(),
        );
        final direct = Map<String, dynamic>.from(
          outbounds[2].cast<String, dynamic>(),
        );

        expect(vless['flow'], 'xtls-rprx-vision');
        expect(vless['packet_encoding'], 'xudp');
        expect((vless['multiplex'] as Map<String, dynamic>)['enabled'], isTrue);
        expect(
          (vless['tls'] as Map<String, dynamic>)['server_name'],
          'cdn.example.com',
        );
        expect(
          ((vless['tls'] as Map<String, dynamic>)['utls']
              as Map<String, dynamic>)['fingerprint'],
          'chrome',
        );
        expect(
          (vless['tls'] as Map<String, dynamic>)['record_fragment'],
          isTrue,
        );

        expect(trojan.containsKey('flow'), isFalse);
        expect(trojan.containsKey('packet_encoding'), isFalse);
        expect(trojan.containsKey('multiplex'), isFalse);
        expect(
          (trojan['tls'] as Map<String, dynamic>)['server_name'],
          'cdn.example.com',
        );
        expect(
          ((trojan['tls'] as Map<String, dynamic>)['utls']
              as Map<String, dynamic>)['fingerprint'],
          'chrome',
        );
        expect(
          (trojan['tls'] as Map<String, dynamic>)['record_fragment'],
          isTrue,
        );

        expect(direct, {'type': 'direct', 'tag': 'direct'});
      },
    );

    test('skips vision flow for websocket VLESS and reports it in diagnostics', () {
      final originalTemplate = jsonEncode({
        'outbounds': [
          {
            'type': 'vless',
            'tag': 'server-ws',
            'server': 'ws.example.com',
            'server_port': 443,
            'tls': {'enabled': true, 'server_name': 'origin.example.com'},
            'transport': {'type': 'ws', 'path': '/ws'},
          },
        ],
      });

      const settings = ConnectionTuningSettings(
        forceChromeUtls: true,
        sniDonor: 'cdn.example.com',
        forceVisionFlow: true,
        forceXudpPacketEncoding: true,
        enableMultiplex: true,
        enableTlsRecordFragment: true,
      );

      final effectiveTemplate = applyConnectionTuningSettingsToTemplateConfig(
        templateConfig: originalTemplate,
        settings: settings,
      );
      final effectiveConfig =
          jsonDecode(effectiveTemplate) as Map<String, dynamic>;
      final outbound =
          (effectiveConfig['outbounds'] as List).single as Map<String, dynamic>;
      final diagnostics = describeConnectionTuningDiagnostics(
        originalTemplateConfig: originalTemplate,
        effectiveTemplateConfig: effectiveTemplate,
        settings: settings,
        selectedServerTag: 'server-ws',
      );

      expect(outbound.containsKey('flow'), isFalse);
      expect(
        diagnostics,
        contains(
          'Tuning note: flow xtls-rprx-vision was skipped for the selected outbound because transport=ws is incompatible with Vision.',
        ),
      );
      expect(
        diagnostics,
        contains(
          'Tuning effective: utls=chrome, server_name=cdn.example.com (was origin.example.com), packet_encoding=xudp, multiplex=enabled, tls.record_fragment=on.',
        ),
      );
    });

    test('returns the original template when no overrides are enabled', () {
      const template = '{"outbounds":[]}';

      final applied = applyConnectionTuningSettingsToTemplateConfig(
        templateConfig: template,
        settings: const ConnectionTuningSettings(),
      );

      expect(applied, template);
    });
  });
}
