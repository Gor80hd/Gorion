import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gorion/core/constants/singbox_assets.dart';
import 'package:gorion/features/profiles/data/profile_parser.dart';
import 'package:gorion/features/runtime/data/singbox_config_builder.dart';
import 'package:gorion/features/runtime/model/runtime_mode.dart';
import 'package:gorion/features/settings/model/split_tunnel_settings.dart';

Map<String, dynamic> parse(String link) {
  final result = ProfileParser().parseContent(
    rawContent: link,
    source: Uri.parse('https://example.com/sub'),
  );
  return jsonDecode(result.normalizedConfigJson) as Map<String, dynamic>;
}

void main() {
  const links = [
    'hy2://test%3Apass@127.0.0.1?sni=example.com&obfs=salamander&obfs-password=secret#HY2',
    'hysteria2://test@127.0.0.1:443?mport=443,8443-8450',
    'tuic://00000000-0000-4000-8000-000000000001:pass%3Aword@127.0.0.1:443?congestion_control=bbr&udp_relay_mode=native&alpn=h3',
    'anytls://test@127.0.0.1:443?sni=example.com',
  ];

  test('imports modern protocols with credentials, TLS and options intact', () {
    final hy2 =
        (parse(links[0])['outbounds'] as List).single as Map<String, dynamic>;
    expect(hy2['password'], 'test:pass');
    expect(hy2['server_port'], 443);
    expect((hy2['tls'] as Map<String, dynamic>)['server_name'], 'example.com');
    expect((hy2['tls'] as Map<String, dynamic>)['insecure'], isNull);
    expect(hy2['obfs'], {'type': 'salamander', 'password': 'secret'});
    final hopping =
        (parse(links[1])['outbounds'] as List).single as Map<String, dynamic>;
    expect(hopping['server_ports'], ['443:443', '8443:8450']);
    final tuic =
        (parse(links[2])['outbounds'] as List).single as Map<String, dynamic>;
    expect(tuic['password'], 'pass:word');
    expect(tuic['congestion_control'], 'bbr');
    expect((tuic['tls'] as Map<String, dynamic>)['alpn'], ['h3']);
    expect(
      ((parse(links[3])['outbounds'] as List).single
          as Map<String, dynamic>)['type'],
      'anytls',
    );
  });

  test(
    'rejects invalid options and unsupported pinning without losing security',
    () {
      for (final query in [
        'obfs=unknown&obfs-password=x',
        'obfs=salamander',
        'mport=9000-8000',
        'mport=0',
        'pinSHA256=abc',
        'security=reality',
      ]) {
        expect(
          () => parse('hy2://test@example.com:443?$query'),
          throwsA(isA<FormatException>()),
        );
      }
    },
  );

  test('bundled binary accepts imported links in all desktop modes', () async {
    final dir = await Directory.systemTemp.createTemp('gorion-import-check-');
    addTearDown(() => dir.delete(recursive: true));
    final binary = await File(
      resolveSingboxAsset().assetPath,
    ).copy('${dir.path}/sing-box');
    await Process.run('/bin/chmod', ['700', binary.path]);
    for (final link in links) {
      for (final mode in RuntimeMode.values) {
        final built = SingboxConfigBuilder.build(
          templateConfig: jsonEncode(parse(link)),
          splitTunnelSettings: const SplitTunnelSettings(),
          mode: mode,
          mixedPort: 2080,
          controllerPort: 9090,
          controllerSecret: 'test',
          urlTestUrl: 'https://example.com',
        );
        final config = File('${dir.path}/config.json');
        await config.writeAsString(built.configJson);
        final result = await Process.run(binary.path, [
          'check',
          '-c',
          config.path,
        ]);
        expect(result.exitCode, 0, reason: '${mode.name}: ${result.stderr}');
      }
    }
  }, testOn: 'mac-os');
}
