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
          settings: const ZapretSettings(
            installDirectory: r'E:\Tools\zapret2',
            customProfile: ZapretCustomProfile(
              youtubeVariant: ZapretFlowsealVariant.multisplit,
              discordVariant: ZapretFlowsealVariant.hostfakesplit,
              genericVariant: ZapretFlowsealVariant.multidisorder,
            ),
            startOnAppLaunch: true,
          ),
          stage: ZapretStage.running,
          runtimeSession: ZapretRuntimeSession(
            executablePath: r'E:\Tools\zapret2\winws2.exe',
            workingDirectory: r'E:\Tools\zapret2',
            processId: 17240,
            startedAt: DateTime(2026, 4, 8, 13, 45),
            arguments: const ['--wf-tcp=80,443'],
            commandPreview:
                'winws2.exe --wf-tcp=80,443 --filter-udp=443 --dpi-desync=fake --dpi-desync-split-pos=1',
          ),
          generatedConfigPreview:
              'winws2.exe --wf-tcp=80,443 --filter-udp=443 --dpi-desync=fake --dpi-desync-split-pos=1',
          generatedConfigSummary: 'YouTube + Discord + HTTPS fallback',
          statusMessage: 'zapret2 работает с Flowseal-профилем.',
          logs: const [
            '[13:45:02] Starting winws2',
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
        expect(find.text('Flowseal-профиль'), findsOneWidget);
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
}

class _FakeZapretSettingsRepository extends ZapretSettingsRepository {}

class _FakeZapretRuntimeService extends ZapretRuntimeService {}

class _FakeDesktopSettingsRepository extends DesktopSettingsRepository {}
