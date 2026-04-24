import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gorion_clean/app/shell.dart';
import 'package:gorion_clean/app/theme.dart';
import 'package:gorion_clean/app/theme_settings.dart';
import 'package:gorion_clean/features/auto_select/data/auto_select_preconnect_service.dart';
import 'package:gorion_clean/features/auto_select/data/auto_select_settings_repository.dart';
import 'package:gorion_clean/features/auto_select/data/auto_selector_service.dart';
import 'package:gorion_clean/features/home/application/dashboard_controller.dart';
import 'package:gorion_clean/features/home/widget/home_page.dart';
import 'package:gorion_clean/features/profiles/data/profile_repository.dart';
import 'package:gorion_clean/features/runtime/data/singbox_runtime_service.dart';
import 'package:gorion_clean/features/update/application/app_update_controller.dart';
import 'package:gorion_clean/features/update/data/github_release_repository.dart';
import 'package:gorion_clean/features/update/model/app_update_state.dart';
import 'package:gorion_clean/features/zapret/application/zapret_controller.dart';
import 'package:gorion_clean/features/zapret/data/zapret_runtime_service.dart';
import 'package:gorion_clean/features/zapret/data/zapret_settings_repository.dart';

void main() {
  testWidgets('app shell shows update popup and settings badge', (
    WidgetTester tester,
  ) async {
    final dashboardController = DashboardController(
      repository: _FakeProfileRepository(),
      runtimeService: _FakeRuntimeService(),
      autoSelectSettingsRepository: _FakeAutoSelectSettingsRepository(),
      autoSelectPreconnectService: AutoSelectPreconnectService(
        settingsRepository: _FakeAutoSelectSettingsRepository(),
      ),
      autoSelectorService: AutoSelectorService(),
      initialState: const DashboardState(bootstrapping: false),
      loadOnInit: false,
    );
    final zapretController = ZapretController(
      repository: _FakeZapretSettingsRepository(),
      runtimeService: _FakeZapretRuntimeService(),
      initialState: const ZapretState(bootstrapping: false),
      loadOnInit: false,
    );
    final updateController = _TestAppUpdateController(
      const AppUpdateState(
        status: AppUpdateStatus.updateAvailable,
        currentVersion: '1.5.0',
        update: AppUpdateInfo(
          currentVersion: '1.5.0',
          latestVersion: '1.6.0',
          tagName: 'v1.6.0',
          releaseUrl: 'https://github.com/Gor80hd/Gorion/releases/tag/v1.6.0',
        ),
      ),
    );
    final container = ProviderContainer(
      overrides: [
        dashboardControllerProvider.overrideWith((ref) => dashboardController),
        zapretControllerProvider.overrideWith((ref) => zapretController),
        appUpdateControllerProvider.overrideWith((ref) => updateController),
      ],
    );

    addTearDown(container.dispose);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildGorionTheme(
            brightness: Brightness.dark,
            palette: AppThemePalette.emerald,
          ),
          home: const AppShell(child: HomePage(animateOnMount: false)),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Доступна новая версия 1.6.0'), findsOneWidget);
    expect(find.text('Открыть страницу релиза'), findsOneWidget);

    await tester.tap(find.byTooltip('Настройки'));
    await tester.pump();

    expect(find.text('Новая версия 1.6.0'), findsOneWidget);
    expect(find.text('Проверить обновления'), findsOneWidget);

    await tester.tap(find.text('Проверить обновления'));
    await tester.pump();

    expect(updateController.forcedUpdateChecks, 1);
  });
}

class _TestAppUpdateController extends AppUpdateController {
  _TestAppUpdateController(AppUpdateState initialState)
    : super(
        repository: const _FakeAppUpdateRepository(),
        currentVersionLoader: () async => '1.5.0',
      ) {
    state = initialState;
  }

  int forcedUpdateChecks = 0;

  @override
  Future<void> checkForUpdates({bool force = false}) async {
    if (force) {
      forcedUpdateChecks += 1;
    }
  }
}

class _FakeAppUpdateRepository implements AppUpdateRepository {
  const _FakeAppUpdateRepository();

  @override
  Future<GithubRelease> fetchLatestRelease() async {
    return const GithubRelease(tagName: 'v1.6.0');
  }
}

class _FakeAutoSelectSettingsRepository extends AutoSelectSettingsRepository {}

class _FakeProfileRepository extends ProfileRepository {}

class _FakeRuntimeService extends SingboxRuntimeService {
  @override
  List<String> get logs => const <String>[];
}

class _FakeZapretSettingsRepository extends ZapretSettingsRepository {}

class _FakeZapretRuntimeService extends ZapretRuntimeService {}
