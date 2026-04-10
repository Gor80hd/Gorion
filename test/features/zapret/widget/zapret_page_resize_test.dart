import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gorion_clean/app/theme.dart';
import 'package:gorion_clean/app/theme_settings.dart';
import 'package:gorion_clean/features/settings/application/desktop_settings_controller.dart';
import 'package:gorion_clean/features/settings/data/desktop_settings_repository.dart';
import 'package:gorion_clean/features/settings/data/launch_at_startup_service.dart';
import 'package:gorion_clean/features/zapret/application/zapret_controller.dart';
import 'package:gorion_clean/features/zapret/data/zapret_runtime_service.dart';
import 'package:gorion_clean/features/zapret/data/zapret_settings_repository.dart';
import 'package:gorion_clean/features/zapret/model/zapret_models.dart';
import 'package:gorion_clean/features/zapret/model/zapret_settings.dart';
import 'package:gorion_clean/features/zapret/widget/zapret_page.dart';

void main() {
  testWidgets(
    'zapret page keeps the bento layout without page scroll during resize',
    (WidgetTester tester) async {
      final zapretController = ZapretController(
        repository: _FakeZapretSettingsRepository(),
        runtimeService: _FakeZapretRuntimeService(),
        initialState: ZapretState(
          bootstrapping: false,
          settings: ZapretSettings(
            installDirectory: r'E:\Tools\zapret2',
            configFileName: 'general (ALT10).conf',
            gameFilterMode: ZapretGameFilterMode.tcp,
            startOnAppLaunch: true,
          ),
          availableConfigs: const [
            ZapretConfigOption(
              fileName: 'general.conf',
              path: r'E:\Tools\zapret2\profiles\general.conf',
            ),
            ZapretConfigOption(
              fileName: 'general (ALT10).conf',
              path: r'E:\Tools\zapret2\profiles\general (ALT10).conf',
            ),
          ],
          stage: ZapretStage.running,
          runtimeSession: ZapretRuntimeSession(
            executablePath: r'E:\Tools\zapret2\bin\winws.exe',
            workingDirectory: r'E:\Tools\zapret2\bin',
            processId: 17240,
            startedAt: DateTime(2026, 4, 8, 13, 45),
            arguments: const ['--wf-tcp=80,443,1024-65535'],
            commandPreview:
                'winws.exe --wf-tcp=80,443,1024-65535 --wf-udp=443,12',
          ),
          generatedConfigPreview:
              'winws.exe --wf-tcp=80,443,1024-65535 --wf-udp=443,12',
          generatedConfigSummary: 'general (ALT10)',
          statusMessage: 'zapret запущен с выбранным конфигом.',
          logs: const [
            '[13:45:02] Starting winws',
            '[13:45:03] DNS filter applied',
            '[13:45:05] QUIC profile active',
            '[13:45:07] Process is healthy',
          ],
        ),
        loadOnInit: false,
      );
      final desktopController = DesktopSettingsController(
        repository: _FakeDesktopSettingsRepository(),
        launchAtStartupService: const NoopLaunchAtStartupService(),
        initialState: const DesktopSettingsState(launchAtStartupEnabled: true),
      );
      final container = ProviderContainer(
        overrides: [
          zapretControllerProvider.overrideWith((ref) => zapretController),
          desktopSettingsControllerProvider.overrideWith(
            (ref) => desktopController,
          ),
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
              home: const Scaffold(body: ZapretPage(animateOnMount: false)),
            ),
          ),
        );
        await tester.pump();

        expect(tester.takeException(), isNull);
        expect(
          find.byKey(const ValueKey('zapret-bento-dashboard')),
          findsOneWidget,
        );
        expect(find.byType(SingleChildScrollView), findsNothing);
        expect(find.text('Каталог и генерация'), findsOneWidget);
        expect(find.text('Конфиг и фильтр'), findsOneWidget);
        expect(find.text('Процесс и лента'), findsOneWidget);
        expect(find.text('Пресет'), findsNothing);
      }

      await pumpAtSize(const Size(1440, 900));
      await pumpAtSize(const Size(1100, 760));
      await pumpAtSize(const Size(900, 560));
      await pumpAtSize(const Size(780, 520));
      await pumpAtSize(const Size(640, 420));
    },
  );

  testWidgets('zapret page shows Off block labels for disabled blocks', (
    WidgetTester tester,
  ) async {
    final zapretController = ZapretController(
      repository: _FakeZapretSettingsRepository(),
      runtimeService: _FakeZapretRuntimeService(),
      initialState: ZapretState(
        bootstrapping: false,
        settings: ZapretSettings(
          installDirectory: r'E:\Tools\zapret2',
          configFileName: 'general.conf',
          gameFilterMode: ZapretGameFilterMode.disabled,
        ),
        availableConfigs: const [
          ZapretConfigOption(
            fileName: 'general.conf',
            path: r'E:\Tools\zapret2\profiles\general.conf',
          ),
        ],
      ),
      loadOnInit: false,
    );
    final desktopController = DesktopSettingsController(
      repository: _FakeDesktopSettingsRepository(),
      launchAtStartupService: const NoopLaunchAtStartupService(),
      initialState: const DesktopSettingsState(launchAtStartupEnabled: true),
    );
    final container = ProviderContainer(
      overrides: [
        zapretControllerProvider.overrideWith((ref) => zapretController),
        desktopSettingsControllerProvider.overrideWith(
          (ref) => desktopController,
        ),
      ],
    );

    addTearDown(container.dispose);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildGorionTheme(
            brightness: Brightness.dark,
            palette: AppThemePalette.emerald,
          ),
          home: const Scaffold(body: ZapretPage(animateOnMount: false)),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Конфиг и фильтр'), findsOneWidget);
    expect(find.text('general'), findsWidgets);
    expect(find.text('Отключён'), findsWidgets);
  });
}

class _FakeZapretSettingsRepository extends ZapretSettingsRepository {}

class _FakeZapretRuntimeService extends ZapretRuntimeService {}

class _FakeDesktopSettingsRepository extends DesktopSettingsRepository {}
