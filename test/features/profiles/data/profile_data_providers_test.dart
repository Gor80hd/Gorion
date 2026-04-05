import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gorion_clean/features/home/application/dashboard_controller.dart';
import 'package:gorion_clean/features/profiles/data/profile_data_providers.dart';
import 'package:gorion_clean/features/profiles/model/profile_models.dart';
import 'package:gorion_clean/features/runtime/model/runtime_mode.dart';

void main() {
  test(
    'profile data source replays current profiles to late subscribers',
    () async {
      final controller = _FakeDashboardController(
        DashboardState(
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

class _FakeDashboardController extends StateNotifier<DashboardState> {
  _FakeDashboardController(super.state);
}
