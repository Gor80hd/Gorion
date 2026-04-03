import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gorion_clean/features/profiles/data/profile_parser.dart';

void main() {
  group('ProfileParser', () {
    test('parseContent extracts profile name and servers from JSON config', () {
      final parser = ProfileParser();
      final config = jsonEncode({
        'outbounds': [
          {
            'type': 'vless',
            'tag': 'nl-edge-1',
            'server': 'edge-1.example.com',
            'server_port': 443,
          },
          {
            'type': 'trojan',
            'tag': 'de-core-2',
            'server': 'core-2.example.com',
            'server_port': 8443,
          },
        ],
      });

      final parsed = parser.parseContent(
        rawContent: config,
        source: Uri.parse(
          'https://example.com/subscription.json#fallback-name',
        ),
        headers: const {
          'profile-title': 'Q29yZSBUZXN0IFByb2ZpbGU=',
          'subscription-userinfo':
              'upload=10; download=20; total=1000; expire=2000000000',
        },
      );

      expect(parsed.name, 'Core Test Profile');
      expect(parsed.servers, hasLength(2));
      expect(parsed.servers.first.tag, 'nl-edge-1');
      expect(parsed.servers.first.host, 'edge-1.example.com');
      expect(parsed.subscriptionInfo?.upload, 10);
      expect(parsed.subscriptionInfo?.download, 20);
      expect(parsed.subscriptionInfo?.total, 1000);
      expect(parsed.subscriptionInfo?.expireAt, isNotNull);
    });

    test('parseContent accepts base64-encoded JSON body', () {
      final parser = ProfileParser();
      final config = base64Encode(
        utf8.encode(
          jsonEncode({
            'outbounds': [
              {
                'type': 'vmess',
                'tag': 'tokyo-fast',
                'server': 'tokyo.example.com',
                'server_port': 443,
              },
            ],
          }),
        ),
      );

      final parsed = parser.parseContent(
        rawContent: config,
        source: Uri.parse('https://example.com/remote-config'),
      );

      expect(parsed.name, 'remote-config');
      expect(parsed.servers.single.tag, 'tokyo-fast');
      expect(parsed.normalizedConfigJson, contains('tokyo-fast'));
    });

    test(
      'parseContent converts base64-encoded share-link subscriptions into sing-box JSON',
      () {
        final parser = ProfileParser();
        final config = base64Encode(
          utf8.encode(
            [
              'vless://11111111-1111-1111-1111-111111111111@edge.example.com:443?type=ws&security=tls&sni=cdn.example.com&host=ws.example.com&path=%2Fsocket&alpn=h2&fp=chrome#Amsterdam',
              'vless://22222222-2222-2222-2222-222222222222@198.51.100.25:443?type=tcp&security=reality&sni=www.example.com&fp=firefox&pbk=PUBLIC_KEY_VALUE&sid=abcdef12&flow=xtls-rprx-vision#Reality Node',
            ].join('\n'),
          ),
        );

        final parsed = parser.parseContent(
          rawContent: config,
          source: Uri.parse('https://example.com/s/abc123'),
          headers: const {'profile-title': 'base64:QmxhbmNWUE4='},
        );

        expect(parsed.name, 'BlancVPN');
        expect(parsed.servers, hasLength(2));
        expect(parsed.servers.first.tag, 'Amsterdam');
        expect(parsed.servers.first.host, 'edge.example.com');
        expect(parsed.servers.last.tag, 'Reality Node');
        expect(parsed.servers.last.host, '198.51.100.25');

        final generatedConfig =
            jsonDecode(parsed.normalizedConfigJson) as Map<String, dynamic>;
        final outbounds = generatedConfig['outbounds'] as List<dynamic>;
        expect(outbounds, hasLength(2));

        final first = outbounds.first as Map<String, dynamic>;
        expect(first['type'], 'vless');
        expect(first['server'], 'edge.example.com');
        expect(
          (first['tls'] as Map<String, dynamic>)['server_name'],
          'cdn.example.com',
        );
        expect(
          ((first['tls'] as Map<String, dynamic>)['utls']
              as Map<String, dynamic>)['fingerprint'],
          'chrome',
        );
        expect((first['transport'] as Map<String, dynamic>)['type'], 'ws');
        expect((first['transport'] as Map<String, dynamic>)['path'], '/socket');
        expect(
          ((first['transport'] as Map<String, dynamic>)['headers']
              as Map<String, dynamic>)['Host'],
          'ws.example.com',
        );

        final second = outbounds.last as Map<String, dynamic>;
        expect(second['flow'], 'xtls-rprx-vision');
        expect(
          (second['tls'] as Map<String, dynamic>)['server_name'],
          'www.example.com',
        );
        expect(
          ((second['tls'] as Map<String, dynamic>)['reality']
              as Map<String, dynamic>)['public_key'],
          'PUBLIC_KEY_VALUE',
        );
        expect(
          ((second['tls'] as Map<String, dynamic>)['reality']
              as Map<String, dynamic>)['short_id'],
          'abcdef12',
        );
      },
    );

    test('parseContent accepts vmess share links', () {
      final parser = ProfileParser();
      final vmessConfig = base64Encode(
        utf8.encode(
          jsonEncode({
            'v': '2',
            'ps': 'vmess edge',
            'add': 'vmess.example.com',
            'port': '443',
            'id': '33333333-3333-3333-3333-333333333333',
            'aid': '0',
            'scy': 'auto',
            'net': 'ws',
            'type': 'none',
            'host': 'cdn.vmess.example.com',
            'path': '/vmess',
            'tls': 'tls',
            'sni': 'cdn.vmess.example.com',
          }),
        ),
      );

      final parsed = parser.parseContent(
        rawContent: 'vmess://$vmessConfig',
        source: Uri.parse('https://example.com/subscription.txt'),
      );

      expect(parsed.servers, hasLength(1));
      expect(parsed.servers.single.tag, 'vmess edge');

      final generatedConfig =
          jsonDecode(parsed.normalizedConfigJson) as Map<String, dynamic>;
      final outbound =
          (generatedConfig['outbounds'] as List<dynamic>).single
              as Map<String, dynamic>;
      expect(outbound['type'], 'vmess');
      expect(outbound['security'], 'auto');
      expect((outbound['transport'] as Map<String, dynamic>)['type'], 'ws');
      expect(
        ((outbound['transport'] as Map<String, dynamic>)['headers']
            as Map<String, dynamic>)['Host'],
        'cdn.vmess.example.com',
      );
      expect(
        (outbound['tls'] as Map<String, dynamic>)['server_name'],
        'cdn.vmess.example.com',
      );
    });
  });
}
