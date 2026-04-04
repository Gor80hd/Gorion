import 'package:flutter_test/flutter_test.dart';
import 'package:gorion_clean/features/auto_select/model/auto_select_state.dart';
import 'package:gorion_clean/features/home/application/dashboard_controller.dart';
import 'package:gorion_clean/features/home/notifier/home_status_card_provider.dart';
import 'package:gorion_clean/features/profiles/model/profile_models.dart';

final _createdAt = DateTime(2026, 4, 4, 12);
final _profile = ProxyProfile(
  id: 'profile-1',
  name: 'Profile 1',
  subscriptionUrl: 'https://example.com/sub',
  templateFileName: 'profile-1.json',
  createdAt: _createdAt,
  updatedAt: _createdAt,
  servers: [
    ServerEntry(
      tag: 'server-a',
      displayName: 'Server A',
      type: 'vless',
      host: 'a.example.com',
      port: 443,
    ),
  ],
  lastSelectedServerTag: 'server-a',
  lastAutoSelectedServerTag: 'server-a',
);
final _storage = StoredProfilesState(
  activeProfileId: 'profile-1',
  profiles: [_profile],
);

void main() {
  group('buildHomeStatusCardModel', () {
    test('surfaces connection errors on the status card', () {
      final model = buildHomeStatusCardModel(
        state: DashboardState(
          bootstrapping: false,
          autoSelectSettings: AutoSelectSettings(enabled: false),
          storage: _storage,
          selectedServerTag: 'server-a',
          activeServerTag: 'server-a',
          delayByTag: {'server-a': 48},
          errorMessage: 'Подключение не удалось: Server A недоступен.',
        ),
        selectedPreview: null,
        pendingManualSelection: null,
        sourceIp: null,
        currentIp: null,
        autoStatus: null,
      );

      expect(model.title, 'Server A');
      expect(model.routeName, 'Server A');
      expect(
        model.alertText,
        'Подключение не удалось: Server A недоступен.',
      );
      expect(model.statusText, isNull);
    });

    test('avoids duplicating identical auto status and alert messages', () {
      const message = 'Подключение не удалось: server-a недоступен.';
      final model = buildHomeStatusCardModel(
        state: DashboardState(
          bootstrapping: false,
          autoSelectSettings: AutoSelectSettings(enabled: true),
          storage: _storage,
          selectedServerTag: autoSelectServerTag,
          activeServerTag: 'server-a',
          errorMessage: message,
        ),
        selectedPreview: null,
        pendingManualSelection: null,
        sourceIp: null,
        currentIp: null,
        autoStatus: message,
      );

      expect(model.alertText, message);
      expect(model.statusText, isNull);
    });

    test('normalizes the displayed server name with a flag', () {
      final flaggedProfile = _profile.copyWith(
        servers: const [
          ServerEntry(
            tag: 'server-a',
            displayName: '[NO] Норвегия, Осло',
            type: 'vless',
            host: 'oslo.example.com',
            port: 443,
          ),
        ],
      );
      final model = buildHomeStatusCardModel(
        state: DashboardState(
          bootstrapping: false,
          autoSelectSettings: AutoSelectSettings(enabled: false),
          storage: StoredProfilesState(
            activeProfileId: flaggedProfile.id,
            profiles: [flaggedProfile],
          ),
          selectedServerTag: 'server-a',
          activeServerTag: 'server-a',
        ),
        selectedPreview: null,
        pendingManualSelection: null,
        sourceIp: null,
        currentIp: null,
        autoStatus: null,
      );

      expect(model.title, '🇳🇴 Норвегия, Осло');
      expect(model.routeName, '🇳🇴 Норвегия, Осло');
    });
  });
}
