import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:gorion/core/constants/singbox_assets.dart';
import 'package:gorion/features/runtime/data/singbox_config_builder.dart';
import 'package:gorion/features/runtime/model/runtime_mode.dart';
import 'package:gorion/features/settings/model/split_tunnel_settings.dart';

void main() {
  test(
    'bundled core accepts generated protocol configs in every desktop mode',
    () async {
      final dir = await Directory.systemTemp.createTemp('gorion-config-check-');
      addTearDown(() => dir.delete(recursive: true));
      final executable = await File(
        resolveSingboxAsset().assetPath,
      ).copy('${dir.path}/sing-box');
      await Process.run('/bin/chmod', ['700', executable.path]);
      final protocols = <Map<String, dynamic>>[
        {'type': 'vless', 'uuid': '00000000-0000-4000-8000-000000000001'},
        {
          'type': 'vmess',
          'uuid': '00000000-0000-4000-8000-000000000001',
          'security': 'auto',
        },
        {
          'type': 'trojan',
          'password': 'test',
          'tls': {'enabled': true},
        },
        {'type': 'shadowsocks', 'method': 'aes-128-gcm', 'password': 'test'},
        {
          'type': 'hysteria2',
          'password': 'test',
          'tls': {'enabled': true},
        },
        {
          'type': 'tuic',
          'uuid': '00000000-0000-4000-8000-000000000001',
          'password': 'test',
          'tls': {'enabled': true},
        },
        {'type': 'socks'},
      ];
      for (final protocol in protocols) {
        for (final mode in RuntimeMode.values) {
          final built = SingboxConfigBuilder.build(
            templateConfig: jsonEncode({
              'outbounds': [
                {
                  ...protocol,
                  'tag': 'test-server',
                  'server': '127.0.0.1',
                  'server_port': 443,
                },
              ],
            }),
            splitTunnelSettings: const SplitTunnelSettings(
              enabled: true,
              block: SplitTunnelRuleGroup(domainSuffixes: ['blocked.example']),
            ),
            mode: mode,
            mixedPort: 2080,
            controllerPort: 9090,
            controllerSecret: 'test',
            urlTestUrl: 'https://example.com',
          );
          final config = File('${dir.path}/config.json');
          await config.writeAsString(built.configJson);
          final result = await Process.run(executable.path, [
            'check',
            '-c',
            config.path,
          ]);
          expect(
            result.exitCode,
            0,
            reason: '${protocol['type']} ${mode.name}: ${result.stderr}',
          );
        }
      }
    },
    testOn: 'mac-os',
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
