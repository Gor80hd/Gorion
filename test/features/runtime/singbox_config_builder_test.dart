import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gorion_clean/features/runtime/data/singbox_config_builder.dart';
import 'package:gorion_clean/features/runtime/model/runtime_mode.dart';

void main() {
  group('SingboxConfigBuilder', () {
    test(
      'injects managed selector, urltest, inbound and clash api settings',
      () {
        final template = jsonEncode({
          'log': {'level': 'warn'},
          'outbounds': [
            {
              'type': 'vless',
              'tag': 'server-a',
              'server': 'a.example.com',
              'server_port': 443,
            },
            {
              'type': 'trojan',
              'tag': 'server-b',
              'server': 'b.example.com',
              'server_port': 8443,
            },
          ],
        });

        final built = SingboxConfigBuilder.build(
          templateConfig: template,
          mode: RuntimeMode.mixed,
          mixedPort: 2080,
          controllerPort: 9090,
          controllerSecret: 'secret-value',
          urlTestUrl: 'https://www.gstatic.com/generate_204',
          selectedServerTag: 'server-b',
        );

        final config = jsonDecode(built.configJson) as Map<String, dynamic>;
        final outbounds = (config['outbounds'] as List).cast<Map>();
        final selector = outbounds.firstWhere(
          (item) => item['tag'] == managedManualSelectorTag,
        );
        final urltest = outbounds.firstWhere(
          (item) => item['tag'] == managedAutoUrlTestTag,
        );
        final inbounds = (config['inbounds'] as List).cast<Map>();
        final experimental = config['experimental'] as Map<String, dynamic>;
        final route = config['route'] as Map<String, dynamic>;

        expect(selector['type'], 'selector');
        expect(selector['default'], 'server-b');
        expect(selector['outbounds'], ['server-a', 'server-b']);

        expect(urltest['type'], 'urltest');
        expect(urltest['url'], 'https://www.gstatic.com/generate_204');

        expect(inbounds.single['type'], 'mixed');
        expect(inbounds.single['listen_port'], 2080);

        expect(route['final'], managedManualSelectorTag);
        expect(route['auto_detect_interface'], true);

        expect(experimental['clash_api'], isA<Map>());
        expect(experimental.containsKey('cache_file'), isFalse);
        expect(
          (experimental['clash_api']
              as Map<String, dynamic>)['external_controller'],
          '127.0.0.1:9090',
        );
        expect(
          (experimental['clash_api'] as Map<String, dynamic>)['secret'],
          'secret-value',
        );
      },
    );

    test('adds a managed tun inbound when tun mode is selected', () {
      final template = jsonEncode({
        'outbounds': [
          {
            'type': 'vless',
            'tag': 'server-a',
            'server': 'a.example.com',
            'server_port': 443,
          },
        ],
      });

      final built = SingboxConfigBuilder.build(
        templateConfig: template,
        mode: RuntimeMode.tun,
        mixedPort: 2080,
        controllerPort: 9090,
        controllerSecret: 'secret-value',
        urlTestUrl: 'https://www.gstatic.com/generate_204',
      );

      final config = jsonDecode(built.configJson) as Map<String, dynamic>;
      final inbounds = (config['inbounds'] as List).cast<Map>();
      final tunInbound = inbounds.firstWhere(
        (item) => item['tag'] == managedTunInboundTag,
      );

      expect(inbounds.length, 2);
      expect(tunInbound['type'], 'tun');
      expect(tunInbound['interface_name'], managedTunInterfaceName);
      expect(tunInbound['auto_route'], true);
      expect(tunInbound['strict_route'], true);
      expect(tunInbound['stack'], 'system');
      expect(tunInbound['address'], const [
        '172.19.0.1/30',
        'fdfe:dcba:9876::1/126',
      ]);
    });
  });
}
