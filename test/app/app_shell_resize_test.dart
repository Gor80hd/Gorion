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
import 'package:gorion_clean/features/zapret/application/zapret_controller.dart';
import 'package:gorion_clean/features/zapret/data/zapret_runtime_service.dart';
import 'package:gorion_clean/features/zapret/data/zapret_settings_repository.dart';

void main() {
  testWidgets('app shell remains stable across window resize', (
    WidgetTester tester,
  ) async {
    Future<void> pumpAtSize(Size size) async {
      await tester.binding.setSurfaceSize(size);
      await tester.pumpWidget(
        ProviderScope(
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
      await tester.pump(const Duration(milliseconds: 250));
      expect(tester.takeException(), isNull);
    }

    addTearDown(() => tester.binding.setSurfaceSize(null));

    await pumpAtSize(const Size(1440, 900));
    await pumpAtSize(const Size(1100, 760));
    await pumpAtSize(const Size(900, 560));
    await pumpAtSize(const Size(780, 520));
    await pumpAtSize(const Size(640, 420));
  });

  testWidgets(
    'settings and zapret pages stay stable inside app shell during resize',
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
      final zapretController = ZapretController(
        repository: _FakeZapretSettingsRepository(),
        runtimeService: _FakeZapretRuntimeService(),
        initialState: const ZapretState(bootstrapping: false),
        loadOnInit: false,
      );
      final container = ProviderContainer(
        overrides: [
          dashboardControllerProvider.overrideWith((ref) => controller),
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
              home: const AppShell(child: HomePage(animateOnMount: false)),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        expect(tester.takeException(), isNull);
      }

      await pumpAtSize(const Size(1440, 900));
      await tester.tap(find.byTooltip('Настройки'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('Настройки'), findsOneWidget);

      await tester.tap(find.byTooltip('Zapret 2'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('Gorion Boost'), findsOneWidget);

      await pumpAtSize(const Size(1100, 760));
      await pumpAtSize(const Size(900, 560));
      await pumpAtSize(const Size(780, 520));
      await pumpAtSize(const Size(640, 420));
    },
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
