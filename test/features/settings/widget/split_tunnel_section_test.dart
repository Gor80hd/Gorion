import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gorion_clean/features/settings/data/split_tunnel_catalog.dart';
import 'package:gorion_clean/features/settings/model/split_tunnel_settings.dart';
import 'package:gorion_clean/features/settings/widget/split_tunnel_section.dart';

void main() {
  test('RU direct preset targets Russia rule sets', () {
    final directPresets = splitTunnelPresetsForAction(SplitTunnelAction.direct);
    final ruPreset = directPresets.firstWhere(
      (preset) => preset.id == 'ru-direct',
    );

    expect(directPresets.any((preset) => preset.id == 'cn-direct'), isFalse);
    expect(ruPreset.label, 'RU direct');
    expect(ruPreset.geositeTags, contains('category-ru'));
    expect(ruPreset.geoipTags, containsAll(['ru', 'private']));
  });

  test('OpenAI proxy preset targets ChatGPT and OpenAI domains', () {
    final proxyPresets = splitTunnelPresetsForAction(SplitTunnelAction.proxy);
    final openaiPreset = proxyPresets.firstWhere(
      (preset) => preset.id == 'openai-proxy',
    );

    expect(openaiPreset.label, 'OpenAI / ChatGPT proxy');
    expect(openaiPreset.geositeTags, contains('openai'));
    expect(
      openaiPreset.domainSuffixes,
      containsAll([
        'openai.com',
        'chatgpt.com',
        'oaistatic.com',
        'oaiusercontent.com',
      ]),
    );
  });

  testWidgets('geosite picker supports search and multi-select', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 2200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    var latestSettings = const SplitTunnelSettings(
      enabled: true,
      direct: SplitTunnelRuleGroup(geositeTags: ['apple']),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SplitTunnelSection(
              settings: latestSettings,
              busy: false,
              isConnected: false,
              onChanged: (value) => latestSettings = value,
              onRefreshRequested: (_) async {},
            ),
          ),
        ),
      ),
    );

    final geositeButton = find
        .widgetWithText(OutlinedButton, 'Выбрать geosite')
        .first;

    await tester.ensureVisible(geositeButton);
    await tester.tap(geositeButton);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).last, 'россия');
    await tester.pumpAndSettle();

    final categoryRuTile = find.ancestor(
      of: find.text('geosite:category-ru'),
      matching: find.byType(CheckboxListTile),
    );

    expect(categoryRuTile, findsOneWidget);

    await tester.tap(categoryRuTile);
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Применить'));
    await tester.pumpAndSettle();

    expect(
      latestSettings.direct.normalizedGeositeTags,
      containsAll(['apple', 'category-ru']),
    );
  });
}
