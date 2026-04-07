import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gorion_clean/features/auto_select/data/auto_select_preconnect_service.dart';
import 'package:gorion_clean/features/auto_select/data/auto_select_settings_repository.dart';
import 'package:gorion_clean/features/auto_select/data/auto_selector_service.dart';
import 'package:gorion_clean/features/home/application/dashboard_controller.dart';
import 'package:gorion_clean/features/profiles/data/profile_data_providers.dart';
import 'package:gorion_clean/features/profiles/data/profile_repository.dart';
import 'package:gorion_clean/features/profiles/model/profile_models.dart';
import 'package:gorion_clean/features/runtime/data/singbox_runtime_service.dart';
import 'package:gorion_clean/features/runtime/model/runtime_mode.dart';

void main() {
  test(
    'profile data source replays current profiles to late subscribers',
    () async {
      final controller = _TestDashboardController(
        initialState: DashboardState(
          bootstrapping: false,
          runtimeMode: RuntimeMode.mixed,
          storage: StoredProfilesState(
            activeProfileId: 'profile-1',
            profiles: [
              ProxyProfile(
                id: 'profile-1',
                name: 'Example',
                subscriptionUrl: 'https://example.com/sub',
                templateFileName: 'profile-1.json',
                createdAt: DateTime(2026, 4, 5),
                updatedAt: DateTime(2026, 4, 5),
                servers: const [
                  ServerEntry(
                    tag: 'server-a',
                    displayName: 'Server A',
                    type: 'vless',
                    host: 'a.example.com',
                    port: 443,
                  ),
                ],
              ),
            ],
          ),
        ),
      );
      final container = ProviderContainer(
        overrides: [
          dashboardControllerProvider.overrideWith((ref) => controller),
        ],
      );
      addTearDown(container.dispose);

      final dataSource = container.read(profileDataSourceProvider);

      final firstEntries = await dataSource.watchAll().first.timeout(
        const Duration(seconds: 1),
      );
      expect(firstEntries.map((entry) => entry.toEntity().id), ['profile-1']);

      final secondEntries = await dataSource.watchAll().first.timeout(
        const Duration(seconds: 1),
      );
      expect(secondEntries.map((entry) => entry.toEntity().id), ['profile-1']);
    },
  );
}

class _TestDashboardController extends DashboardController {
  _TestDashboardController({required DashboardState initialState})
    : super(
        repository: ProfileRepository(),
        runtimeService: SingboxRuntimeService(),
        autoSelectSettingsRepository: AutoSelectSettingsRepository(),
        autoSelectPreconnectService: AutoSelectPreconnectService(
          settingsRepository: AutoSelectSettingsRepository(),
        ),
        autoSelectorService: AutoSelectorService(),
        initialState: initialState,
        loadOnInit: false,
      );
}
