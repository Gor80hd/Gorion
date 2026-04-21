import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gorion_clean/app/app_router.dart';
import 'package:gorion_clean/app/theme.dart';
import 'package:gorion_clean/app/theme_settings.dart';
import 'package:gorion_clean/core/router/app_modal_router.dart';
import 'package:gorion_clean/core/router/bottom_sheets/bottom_sheets_notifier.dart';
import 'package:gorion_clean/features/auto_select/data/auto_select_preconnect_service.dart';
import 'package:gorion_clean/features/auto_select/data/auto_select_settings_repository.dart';
import 'package:gorion_clean/features/auto_select/data/auto_selector_service.dart';
import 'package:gorion_clean/features/home/application/dashboard_controller.dart';
import 'package:gorion_clean/features/home/widget/home_page.dart';
import 'package:gorion_clean/features/home/widget/servers_panel.dart';
import 'package:gorion_clean/features/profiles/data/profile_repository.dart';
import 'package:gorion_clean/features/proxy/model/outbound_models.dart';
import 'package:gorion_clean/features/runtime/data/singbox_runtime_service.dart';
import 'package:gorion_clean/features/settings/widget/settings_page.dart';
import 'package:gorion_clean/features/zapret/application/zapret_controller.dart';
import 'package:gorion_clean/features/zapret/data/zapret_runtime_service.dart';
import 'package:gorion_clean/features/zapret/data/zapret_settings_repository.dart';
import 'package:gorion_clean/features/zapret/widget/zapret_page.dart';

void main() {
  testWidgets('app router switches between home, settings, and boost routes', (
    WidgetTester tester,
  ) async {
    final container = _buildContainer();
    addTearDown(container.dispose);

    final router = container.read(appRouterProvider);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          theme: buildGorionTheme(
            brightness: Brightness.dark,
            palette: AppThemePalette.emerald,
          ),
          routerConfig: router,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(HomePage), findsOneWidget);
    expect(find.byType(ServersPanelWidget), findsOneWidget);

    router.go(AppRoutePaths.settings);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(SettingsPage), findsOneWidget);

    router.go(AppRoutePaths.zapret);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(ZapretPage), findsOneWidget);
  });

  testWidgets('modal router opens route-backed dialogs without attachContext', (
    WidgetTester tester,
  ) async {
    final container = _buildContainer();
    addTearDown(container.dispose);

    final router = container.read(appRouterProvider);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          theme: buildGorionTheme(
            brightness: Brightness.dark,
            palette: AppThemePalette.emerald,
          ),
          routerConfig: router,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final addProfileFuture = container.read(appModalRouterProvider).showAddProfile();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(AddSubscriptionDialog), findsOneWidget);
    expect(find.text('URL подписки'), findsOneWidget);
    await tester.tap(find.text('Отмена'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await addProfileFuture;

    final profilesOverviewFuture = container
        .read(appModalRouterProvider)
        .showProfilesOverview();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(ProfilesOverviewDialog), findsOneWidget);
    await tester.tap(find.text('Закрыть'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await profilesOverviewFuture;

    final alertFuture = container.read(appModalRouterProvider).showCustomAlert(
      title: 'Проверка',
      message: 'Маршрут модального окна работает.',
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Проверка'), findsOneWidget);
    expect(find.text('Маршрут модального окна работает.'), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await alertFuture;

    final serverSettingsFuture = container.read(appModalRouterProvider).showServerSettings(
      server: OutboundInfo(
        tag: 'server-a',
        tagDisplay: '[NL] Amsterdam',
        type: 'vless',
        isVisible: true,
        isGroup: false,
        host: 'amsterdam.example.com',
        port: 443,
      ),
      outbound: <String, dynamic>{'tag': 'server-a', 'type': 'vless'},
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Сырые настройки сервера'), findsOneWidget);
    expect(find.text('server-a'), findsWidgets);
    await tester.tap(find.text('Закрыть'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await serverSettingsFuture;
  });
}

ProviderContainer _buildContainer() {
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

  return ProviderContainer(
    overrides: [
      dashboardControllerProvider.overrideWith((ref) => dashboardController),
      zapretControllerProvider.overrideWith((ref) => zapretController),
    ],
  );
}

class _FakeAutoSelectSettingsRepository extends AutoSelectSettingsRepository {}

class _FakeProfileRepository extends ProfileRepository {}

class _FakeRuntimeService extends SingboxRuntimeService {
  @override
  List<String> get logs => const <String>[];
}

class _FakeZapretSettingsRepository extends ZapretSettingsRepository {}

class _FakeZapretRuntimeService extends ZapretRuntimeService {}
