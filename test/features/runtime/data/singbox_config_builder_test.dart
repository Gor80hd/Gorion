import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gorion_clean/features/runtime/data/singbox_config_builder.dart';
import 'package:gorion_clean/features/runtime/model/runtime_mode.dart';
import 'package:gorion_clean/features/settings/model/split_tunnel_settings.dart';

void main() {
  test('adds split tunneling rule sets and direct route rules', () {
    const templateConfig = '''
{
  "outbounds": [
    {
      "type": "socks",
      "tag": "proxy-1",
      "server": "example.com",
      "server_port": 1080
    },
    {
      "type": "direct",
      "tag": "custom-direct"
    }
  ],
  "route": {
    "rule_set": [
      {
        "type": "local",
        "tag": "existing-set",
        "path": "existing.srs",
        "format": "binary"
      }
    ],
    "rules": [
      {
        "domain_suffix": ["existing.example"],
        "action": "route",
        "outbound": "custom-direct"
      }
    ]
  }
}
''';

    final built = SingboxConfigBuilder.build(
      templateConfig: templateConfig,
      splitTunnelSettings: const SplitTunnelSettings(
        enabled: true,
        direct: SplitTunnelRuleGroup(
          geositeTags: ['cn'],
          geoipTags: ['private'],
          domainSuffixes: ['lan'],
          ipCidrs: ['10.0.0.0/8'],
          customRuleSets: [
            SplitTunnelCustomRuleSet(
              id: 'corp',
              label: 'Corp routes',
              source: SplitTunnelRuleSetSource.remote,
              url: 'https://example.com/corp.srs',
            ),
          ],
        ),
        remoteRevision: 42,
      ),
      mode: RuntimeMode.systemProxy,
      mixedPort: 2080,
      controllerPort: 9090,
      controllerSecret: 'secret',
      urlTestUrl: 'https://example.com/generate_204',
      selectedServerTag: 'proxy-1',
    );

    final config = jsonDecode(built.configJson) as Map<String, dynamic>;
    final route = Map<String, dynamic>.from(
      (config['route'] as Map).cast<String, dynamic>(),
    );
    final ruleSets = [
      for (final rawRuleSet in route['rule_set'] as List)
        Map<String, dynamic>.from((rawRuleSet as Map).cast<String, dynamic>()),
    ];
    final ruleSetTags = [for (final ruleSet in ruleSets) ruleSet['tag']];

    expect(route['final'], managedManualSelectorTag);
    expect(
      ruleSetTags,
      containsAll([
        'gorion-split-direct-geosite-cn',
        'gorion-split-direct-geoip-private',
        'gorion-split-inline-direct',
        'gorion-split-direct-custom-corp',
        'existing-set',
      ]),
    );

    final geositeRuleSet = ruleSets.firstWhere(
      (ruleSet) => ruleSet['tag'] == 'gorion-split-direct-geosite-cn',
    );
    expect(geositeRuleSet['type'], 'remote');
    expect(geositeRuleSet['format'], 'binary');
    expect(
      geositeRuleSet['url'],
      'https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/cn.srs?gorion_rev=42',
    );

    final inlineRuleSet = ruleSets.firstWhere(
      (ruleSet) => ruleSet['tag'] == 'gorion-split-inline-direct',
    );
    final inlineRules = [
      for (final rawRule in inlineRuleSet['rules'] as List)
        Map<String, dynamic>.from((rawRule as Map).cast<String, dynamic>()),
    ];
    expect(
      inlineRules.any(
        (rule) => (rule['domain_suffix'] as List?)?.contains('lan') ?? false,
      ),
      isTrue,
    );
    expect(
      inlineRules.any(
        (rule) => (rule['ip_cidr'] as List?)?.contains('10.0.0.0/8') ?? false,
      ),
      isTrue,
    );

    final routeRules = [
      for (final rawRule in route['rules'] as List)
        Map<String, dynamic>.from((rawRule as Map).cast<String, dynamic>()),
    ];
    expect(routeRules, hasLength(2));
    expect(routeRules.first['action'], 'route');
    expect(routeRules.first['outbound'], 'direct');
    expect(
      routeRules.first['rule_set'],
      containsAll([
        'gorion-split-direct-geosite-cn',
        'gorion-split-direct-geoip-private',
        'gorion-split-inline-direct',
        'gorion-split-direct-custom-corp',
      ]),
    );
  });
}
