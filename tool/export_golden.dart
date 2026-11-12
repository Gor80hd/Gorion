// Выгружает золотые фикстуры из Flutter-эталона для Rust-ядра.
//
//   dart run tool/export_golden.dart
//
// Пишет core/fixtures/*.json. Все ссылки, ключи и адреса — синтетические.
// Rust-тесты (core/crates/gorion-core/tests/golden.rs) обязаны воспроизвести
// эти результаты. Меняете поведение эталона — перегенерируйте фикстуры.

import 'dart:convert';
import 'dart:io';

import 'package:gorion/features/profiles/data/profile_parser.dart';
import 'package:gorion/features/runtime/data/singbox_config_builder.dart';
import 'package:gorion/features/runtime/model/runtime_mode.dart';
import 'package:gorion/features/settings/model/split_tunnel_settings.dart';
import 'package:gorion/utils/server_display_text.dart';

const _uuid = '11111111-2222-3333-4444-555555555555';

String _b64(String value) => base64.encode(utf8.encode(value));

final _linkCases = <String, String>{
  'vless_reality_vision':
      'vless://$_uuid@example.com:443?security=reality&sni=www.example.org&fp=chrome&pbk=PUBKEYexample123&sid=abcd&type=tcp&flow=xtls-rprx-vision#%F0%9F%87%B3%F0%9F%87%B1%20NL%20Amsterdam',
  'vless_ws_tls':
      'vless://$_uuid@203.0.113.10:8443?security=tls&type=ws&path=%2Fws%3Fed%3D2048&host=cdn.example.com&ed=2048&alpn=h2,http/1.1&allowInsecure=1#DE_Frankfurt',
  'vless_grpc':
      'vless://$_uuid@grpc.example.com:443?security=tls&type=grpc&serviceName=%2Fsvc&sni=grpc.example.com#US-1',
  'vless_http_header':
      'vless://$_uuid@example.com:80?type=tcp&headerType=http&host=a.example.com,b.example.com&path=%2F#[RU] Moscow',
  'vless_httpupgrade':
      'vless://$_uuid@example.com:80?type=httpupgrade&host=up.example.com&path=%2Fup&packetEncoding=xudp#fi helsinki',
  'vless_xhttp_rejected':
      'vless://$_uuid@example.com:443?security=tls&type=xhttp&path=%2Fx#XHTTP',
  'vless_reality_without_key':
      'vless://$_uuid@example.com:443?security=reality&sni=www.example.org#NoKey',
  'vless_no_fragment': 'vless://$_uuid@example.com:443?security=tls',
  'vless_ipv6': 'vless://$_uuid@[2001:db8::1]:443?security=tls#IPv6',
  'vmess_json': 'vmess://${_b64(jsonEncode({'v': '2', 'ps': 'JP Tokyo', 'add': 'vm.example.com', 'port': '443', 'id': _uuid, 'aid': '0', 'scy': 'auto', 'net': 'ws', 'type': 'none', 'host': 'vm.example.com', 'path': '/vm', 'tls': 'tls', 'sni': 'vm.example.com', 'alpn': 'h2', 'fp': 'firefox'}))}',
  'vmess_uri':
      'vmess://$_uuid@vm2.example.com:8080?encryption=aes-128-gcm&alterId=2&type=tcp#VMess plain',
  'trojan_basic':
      'trojan://p%40ss@example.org:443?sni=example.org&alpn=h2,http/1.1&fp=safari#Trojan%20Server',
  'trojan_ws':
      'trojan://secret@example.org:443?type=ws&path=%2Ftr&host=example.org#GB London',
  'ss_sip002':
      'ss://${_b64('aes-256-gcm:password')}@example.net:8388#SS%20one',
  'ss_legacy':
      'ss://${_b64('chacha20-ietf-poly1305:pw123@198.51.100.5:8389')}#SS legacy',
  'ss_plugin':
      'ss://${_b64('aes-128-gcm:pw')}@example.net:443?plugin=obfs-local%3Bobfs%3Dhttp%3Bobfs-host%3Dexample.com#SS plugin',
  'hysteria2_full':
      'hysteria2://hpass@hy.example.com:443?sni=hy.example.com&obfs=salamander&obfs-password=obfspw&mport=20000-30000,40000&insecure=1#HY2',
  'hy2_default_port': 'hy2://hpass@hy.example.com?sni=hy.example.com#HY2 short',
  'hysteria2_pin_rejected':
      'hysteria2://hpass@hy.example.com:443?pinSHA256=abcdef#HY2 pin',
  'hysteria2_bad_obfs':
      'hysteria2://hpass@hy.example.com:443?obfs=other#HY2 bad',
  'tuic_full':
      'tuic://$_uuid:tpass@tuic.example.com:443?congestion_control=bbr&udp_relay_mode=native&alpn=h3&zero_rtt_handshake=1&sni=tuic.example.com#TUIC',
  'anytls_basic':
      'anytls://apass@any.example.com:443?sni=any.example.com&fp=chrome#AnyTLS',
  'unknown_scheme': 'wireguard://abc@example.com:51820#WG',
};

final _subscriptionCases = <String, String>{
  'plain_list_with_duplicates': [
    '# comment',
    'vless://$_uuid@a.example.com:443?security=tls#Same',
    'vless://$_uuid@b.example.com:443?security=tls#Same',
    '',
    'trojan://pw@c.example.com:443#Same',
    'garbage line',
  ].join('\n'),
  'base64_list': _b64(
    [
      'vless://$_uuid@a.example.com:443?security=tls#NL_1',
      'ss://${_b64('aes-256-gcm:pw')}@b.example.com:8388#DE-2',
    ].join('\r\n'),
  ),
  'singbox_json': jsonEncode({
    'log': {'level': 'debug', 'output': '/etc/evil.log', 'timestamp': true},
    'outbounds': [
      {'type': 'selector', 'tag': 'proxy', 'outbounds': ['a', 'b']},
      {
        'type': 'vless',
        'tag': 'a',
        'server': 'a.example.com',
        'server_port': 443,
        'uuid': _uuid,
      },
      {
        'type': 'shadowsocks',
        'tag': 'b',
        'server': 'b.example.com',
        'server_port': '8388',
        'method': 'aes-128-gcm',
        'password': 'x',
      },
      {
        'type': 'trojan',
        'tag': 'hidden §hide§',
        'server': 'h.example.com',
        'server_port': 443,
        'password': 'x',
      },
      {'type': 'direct', 'tag': 'direct'},
    ],
    'experimental': {
      'cache_file': {'enabled': true, 'path': '/tmp/evil.db', 'store_rdrc': true},
      'v2ray_api': {'listen': '0.0.0.0:1'},
    },
    'services': [{'type': 'derp'}],
  }),
  'json_with_bom_and_noise': '﻿  junk {"outbounds":[{"type":"trojan","tag":"t","server":"t.example.com","server_port":443,"password":"p"}]} tail',
  'empty': '   ',
  'only_garbage': 'hello world',
  'no_selectable': jsonEncode({
    'outbounds': [
      {'type': 'direct', 'tag': 'direct'},
    ],
  }),
};

final _headerCases = <String, ({String url, Map<String, String> headers})>{
  'profile_title_base64': (
    url: 'https://sub.example.com/api/sub/token123',
    headers: {
      'profile-title': 'base64:${_b64('Мой VPN')}',
      'subscription-userinfo':
          'upload=1024; download=2048; total=1073741824; expire=1893456000',
      'profile-web-page-url': 'https://example.com/account',
      'support-url': 'https://t.me/example',
    },
  ),
  'content_disposition_utf8': (
    url: 'https://sub.example.com/sub',
    headers: {
      'content-disposition': "attachment; filename*=UTF-8''%D0%9F%D1%80%D0%BE%D1%84%D0%B8%D0%BB%D1%8C.txt",
    },
  ),
  'content_disposition_plain': (
    url: 'https://sub.example.com/sub',
    headers: {'content-disposition': 'attachment; filename="Profile Name"'},
  ),
  'fragment_name': (url: 'https://sub.example.com/sub#My%20Sub', headers: {}),
  'path_name': (url: 'https://sub.example.com/files/servers.txt', headers: {}),
  'fallback_name': (url: 'https://sub.example.com', headers: {}),
};

const _displayCases = [
  '🇳🇱 NL Amsterdam',
  '[DE] Frankfurt',
  'US-1',
  'us server',
  'fi helsinki',
  'Fi Helsinki',
  'GB London',
  'RU_Moscow_Premium',
  'nl:node',
  'XX Unknown',
  'Server §hide§',
  'plain name',
  '🇯🇵Tokyo',
  'JP',
  '  spaced  ',
];

Map<String, Object?> _parse(String raw, {String url = 'https://sub.example.com/sub', Map<String, String> headers = const {}}) {
  try {
    final parsed = ProfileParser().parseContent(
      rawContent: raw,
      source: Uri.parse(url),
      headers: headers,
    );
    return {
      'ok': {
        'name': parsed.name,
        'config': jsonDecode(parsed.normalizedConfigJson),
        'servers': [
          for (final s in parsed.servers) s.toJson(),
        ],
        'subscriptionInfo': parsed.subscriptionInfo == null
            ? null
            : {
                'upload': parsed.subscriptionInfo!.upload,
                'download': parsed.subscriptionInfo!.download,
                'total': parsed.subscriptionInfo!.total,
                'expireAtEpochSeconds':
                    parsed.subscriptionInfo!.expireAt == null
                    ? null
                    : parsed.subscriptionInfo!.expireAt!
                              .millisecondsSinceEpoch ~/
                          1000,
                'webPageUrl': parsed.subscriptionInfo!.webPageUrl,
                'supportUrl': parsed.subscriptionInfo!.supportUrl,
              },
      },
    };
  } on Object catch (error) {
    return {'error': error.toString()};
  }
}

void main() {
  final out = Directory('core/fixtures')..createSync(recursive: true);
  const encoder = JsonEncoder.withIndent('  ');

  final parser = <Map<String, Object?>>[];
  _linkCases.forEach((name, link) {
    parser.add({'name': 'link_$name', 'input': link, ..._parse(link)});
  });
  _subscriptionCases.forEach((name, raw) {
    parser.add({'name': 'sub_$name', 'input': raw, ..._parse(raw)});
  });
  _headerCases.forEach((name, value) {
    const body = 'vless://$_uuid@a.example.com:443?security=tls#Fallback_Name';
    parser.add({
      'name': 'headers_$name',
      'input': body,
      'url': value.url,
      'headers': value.headers,
      ..._parse(body, url: value.url, headers: value.headers),
    });
  });
  File('${out.path}/parser.json').writeAsStringSync(encoder.convert(parser));

  final display = [
    for (final value in _displayCases)
      {
        'input': value,
        'normalized': normalizeServerDisplayText(value, replaceUnderscores: true),
        'countryCode': extractCountryCodeFromDisplayText(value),
      },
  ];
  File('${out.path}/display.json').writeAsStringSync(encoder.convert(display));

  final template = jsonEncode(
    (_parse(_subscriptionCases['singbox_json']!)['ok'] as Map)['config'],
  );
  final builder = <Map<String, Object?>>[];
  for (final mode in RuntimeMode.values) {
    for (final selected in [null, 'b', 'missing']) {
      final built = SingboxConfigBuilder.build(
        templateConfig: template,
        splitTunnelSettings: const SplitTunnelSettings(),
        mode: mode,
        mixedPort: 2080,
        controllerPort: 9090,
        controllerSecret: 'secret',
        urlTestUrl: 'https://www.gstatic.com/generate_204',
        selectedServerTag: selected,
      );
      builder.add({
        'name': '${mode.name}_${selected ?? 'default'}',
        'template': jsonDecode(template),
        'mode': mode.name,
        'selected': selected,
        'output': jsonDecode(built.configJson),
      });
    }
  }
  File('${out.path}/config_builder.json')
      .writeAsStringSync(encoder.convert(builder));
  stdout.writeln(
    'parser=${parser.length} display=${display.length} builder=${builder.length}',
  );
}
