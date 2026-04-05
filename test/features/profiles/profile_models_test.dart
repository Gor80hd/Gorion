import 'package:flutter_test/flutter_test.dart';
import 'package:gorion_clean/features/profiles/model/profile_models.dart';

const _servers = [
  ServerEntry(
    tag: 'server-a',
    displayName: 'Server A',
    type: 'vless',
    host: 'a.example.com',
    port: 443,
    configFingerprint: 'fp-a',
  ),
  ServerEntry(
    tag: 'server-b',
    displayName: 'Server B',
    type: 'trojan',
    host: 'b.example.com',
    port: 8443,
    configFingerprint: 'fp-b',
  ),
];

void main() {
  group('ProxyProfile auto-select choice', () {
    test('buildSelectableServerEntries prepends the auto pseudo-server', () {
      final entries = buildSelectableServerEntries(_servers);

      expect(entries.first.tag, autoSelectServerTag);
      expect(entries.first.displayName, 'Auto-select best');
      expect(entries.skip(1).map((server) => server.tag), [
        'server-a',
        'server-b',
      ]);
    });

    test(
      'auto selection keeps the pseudo-tag and resolves a startup server',
      () {
        final profile = ProxyProfile(
          id: 'profile-1',
          name: 'Example',
          subscriptionUrl: 'https://example.com/sub',
          templateFileName: 'profile.json',
          createdAt: DateTime(2026, 4, 3),
          updatedAt: DateTime(2026, 4, 3),
          servers: _servers,
          lastSelectedServerTag: autoSelectServerTag,
          lastAutoSelectedServerTag: 'server-b',
        );

        expect(profile.selectedServerTag, autoSelectServerTag);
        expect(profile.prefersAutoSelection, isTrue);
        expect(profile.resolvedAutoSelectedServerTag, 'server-b');
        expect(profile.startupServerTag, 'server-b');
      },
    );

    test('falls back to the first real server when saved tags are stale', () {
      final profile = ProxyProfile(
        id: 'profile-1',
        name: 'Example',
        subscriptionUrl: 'https://example.com/sub',
        templateFileName: 'profile.json',
        createdAt: DateTime(2026, 4, 3),
        updatedAt: DateTime(2026, 4, 3),
        servers: _servers,
        lastSelectedServerTag: 'missing-server',
        lastAutoSelectedServerTag: 'missing-server',
      );

      expect(profile.selectedServerTag, 'server-a');
      expect(profile.prefersAutoSelection, isFalse);
      expect(profile.resolvedAutoSelectedServerTag, isNull);
      expect(profile.startupServerTag, 'server-a');
    });

    test('serializes last auto-selected server separately', () {
      final profile = ProxyProfile(
        id: 'profile-1',
        name: 'Example',
        subscriptionUrl: 'https://example.com/sub',
        templateFileName: 'profile.json',
        createdAt: DateTime(2026, 4, 3),
        updatedAt: DateTime(2026, 4, 3),
        servers: _servers,
        lastSelectedServerTag: autoSelectServerTag,
        lastAutoSelectedServerTag: 'server-b',
      );

      final decoded = ProxyProfile.fromJson(profile.toJson());

      expect(decoded.selectedServerTag, autoSelectServerTag);
      expect(decoded.lastAutoSelectedServerTag, 'server-b');
      expect(decoded.startupServerTag, 'server-b');
      expect(decoded.servers.first.configFingerprint, 'fp-a');
    });
  });
}
