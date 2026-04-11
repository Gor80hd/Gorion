import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gorion_clean/app/theme.dart';
import 'package:gorion_clean/app/theme_settings.dart';
import 'package:gorion_clean/features/auto_select/data/auto_select_preconnect_service.dart';
import 'package:gorion_clean/features/auto_select/data/auto_select_settings_repository.dart';
import 'package:gorion_clean/features/auto_select/data/auto_selector_service.dart';
import 'package:gorion_clean/features/home/application/dashboard_controller.dart';
import 'package:gorion_clean/features/profiles/data/profile_repository.dart';
import 'package:gorion_clean/features/runtime/data/singbox_runtime_service.dart';
import 'package:gorion_clean/features/settings/application/desktop_settings_controller.dart';
import 'package:gorion_clean/features/settings/data/desktop_settings_repository.dart';
import 'package:gorion_clean/features/settings/data/launch_at_startup_service.dart';
import 'package:gorion_clean/features/settings/widget/settings_page.dart';
import 'package:gorion_clean/features/zapret/application/zapret_controller.dart';
import 'package:gorion_clean/features/zapret/data/zapret_runtime_service.dart';
import 'package:gorion_clean/features/zapret/data/zapret_settings_repository.dart';
import 'package:gorion_clean/features/zapret/model/zapret_settings.dart';

void main() {
  testWidgets('settings page remains stable across window resize', (
    WidgetTester tester,
  ) async {
    final controller = DashboardController(
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
    final desktopController = DesktopSettingsController(
      repository: _FakeDesktopSettingsRepository(),
      launchAtStartupService: const NoopLaunchAtStartupService(),
      initialState: const DesktopSettingsState(launchAtStartupEnabled: true),
    );
    final zapretController = ZapretController(
      repository: _FakeZapretSettingsRepository(),
      runtimeService: _FakeZapretRuntimeService(),
      initialState: const ZapretState(
        bootstrapping: false,
        settings: ZapretSettings(startOnAppLaunch: true),
      ),
      loadOnInit: false,
    );
    final container = ProviderContainer(
      overrides: [
        dashboardControllerProvider.overrideWith((ref) => controller),
        desktopSettingsControllerProvider.overrideWith(
          (ref) => desktopController,
        ),
        zapretControllerProvider.overrideWith((ref) => zapretController),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    Future<void> pumpAtSize(Size size) async {
      await tester.binding.setSurfaceSize(size);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildGorionTheme(
              brightness: Brightness.dark,
              palette: AppThemePalette.emerald,
            ),
            home: const Scaffold(body: SettingsPage(animateOnMount: false)),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(tester.takeException(), isNull);
    }

    await pumpAtSize(const Size(1440, 900));
    await tester.tap(find.text('Тема приложения').first);
    await tester.pumpAndSettle();

    await pumpAtSize(const Size(1100, 760));
    await pumpAtSize(const Size(900, 560));
    await pumpAtSize(const Size(780, 520));
    await pumpAtSize(const Size(640, 420));
  });

  testWidgets(
    'settings page shows compact reset all settings action at the bottom',
    (WidgetTester tester) async {
      final controller = DashboardController(
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
      final desktopController = DesktopSettingsController(
        repository: _FakeDesktopSettingsRepository(),
        launchAtStartupService: const NoopLaunchAtStartupService(),
        initialState: const DesktopSettingsState(),
      );
      final zapretController = ZapretController(
        repository: _FakeZapretSettingsRepository(),
        runtimeService: _FakeZapretRuntimeService(),
        initialState: const ZapretState(bootstrapping: false),
        loadOnInit: false,
      );
      final container = ProviderContainer(
        overrides: [
          dashboardControllerProvider.overrideWith((ref) => controller),
          desktopSettingsControllerProvider.overrideWith(
            (ref) => desktopController,
          ),
          zapretControllerProvider.overrideWith((ref) => zapretController),
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
            home: const Scaffold(body: SettingsPage(animateOnMount: false)),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Стереть все настройки'), findsOneWidget);
      expect(
        find.text(
          'Сбросит тему, connection overrides, split tunneling, автовыбор, zapret и параметры запуска. Профили и подписки останутся на месте.',
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('desktop settings group contains Gorion and zapret startup', (
    WidgetTester tester,
  ) async {
    if (!Platform.isWindows) {
      return;
    }

    final controller = DashboardController(
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
    final desktopController = DesktopSettingsController(
      repository: _FakeDesktopSettingsRepository(),
      launchAtStartupService: const NoopLaunchAtStartupService(),
      initialState: const DesktopSettingsState(launchAtStartupEnabled: true),
    );
    final zapretController = ZapretController(
      repository: _FakeZapretSettingsRepository(),
      runtimeService: _FakeZapretRuntimeService(),
      initialState: const ZapretState(
        bootstrapping: false,
        settings: ZapretSettings(startOnAppLaunch: true),
      ),
      loadOnInit: false,
    );
    final container = ProviderContainer(
      overrides: [
        dashboardControllerProvider.overrideWith((ref) => controller),
        desktopSettingsControllerProvider.overrideWith(
          (ref) => desktopController,
        ),
        zapretControllerProvider.overrideWith((ref) => zapretController),
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
          home: const Scaffold(body: SettingsPage(animateOnMount: false)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Запуск и трей').first);
    await tester.tap(find.text('Запуск и трей').first);
    await tester.pumpAndSettle();

    expect(find.text('Gorion с Windows'), findsOneWidget);
    expect(find.text('Старт zapret'), findsOneWidget);
    expect(find.text('Стоп при TUN'), findsNothing);
  });
}

class _FakeAutoSelectSettingsRepository extends AutoSelectSettingsRepository {}

class _FakeDesktopSettingsRepository extends DesktopSettingsRepository {}

class _FakeProfileRepository extends ProfileRepository {}

class _FakeRuntimeService extends SingboxRuntimeService {
  @override
  List<String> get logs => const <String>[];
}

class _FakeZapretSettingsRepository extends ZapretSettingsRepository {}

class _FakeZapretRuntimeService extends ZapretRuntimeService {}
