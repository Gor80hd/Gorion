import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gorion_clean/app/theme.dart';
import 'package:gorion_clean/app/theme_settings.dart';
import 'package:gorion_clean/features/zapret/application/zapret_controller.dart';
import 'package:gorion_clean/features/zapret/data/zapret_runtime_service.dart';
import 'package:gorion_clean/features/zapret/data/zapret_settings_repository.dart';
import 'package:gorion_clean/features/zapret/model/zapret_models.dart';
import 'package:gorion_clean/features/zapret/model/zapret_settings.dart';
import 'package:gorion_clean/features/zapret/widget/zapret_page.dart';

void main() {
  testWidgets(
    'zapret page keeps the boost layout without page scroll during resize',
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
          statusMessage: 'Gorion Boost запущен с выбранным конфигом.',
          logs: const [
            '[13:45:02] Starting winws',
            '[13:45:03] DNS filter applied',
            '[13:45:05] QUIC profile active',
            '[13:45:07] Process is healthy',
          ],
        ),
        loadOnInit: false,
      );
      final container = ProviderContainer(
        overrides: [
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
              home: const Scaffold(body: ZapretPage(animateOnMount: false)),
            ),
          ),
        );
        await tester.pump();

        expect(tester.takeException(), isNull);
        expect(
          find.byKey(const ValueKey('zapret-boost-scene')),
          findsOneWidget,
        );
        expect(find.byType(SingleChildScrollView), findsNothing);
        expect(find.text('Gorion Boost'), findsOneWidget);
        expect(find.text('Подключение Boost'), findsOneWidget);
        expect(find.text('Выбранный конфиг'), findsOneWidget);
        expect(find.text('GameFilter'), findsNothing);
        expect(find.text('Подобрать рекомендуемый'), findsOneWidget);
        expect(find.byTooltip('Обновить конфиги'), findsOneWidget);
        expect(find.byTooltip('Открыть папку конфигов'), findsOneWidget);
        expect(find.byTooltip('Подробный отчёт'), findsNothing);
        expect(find.text('Статус работы'), findsNothing);
        expect(find.text('Boost активен'), findsNothing);
        expect(find.text('Стандартный тест конфигов'), findsNothing);
        expect(
          find.text('Gorion Boost запущен с выбранным конфигом.'),
          findsNothing,
        );
      }

      await pumpAtSize(const Size(1440, 900));
      await pumpAtSize(const Size(1100, 760));
      await pumpAtSize(const Size(900, 560));
      await pumpAtSize(const Size(780, 520));
      await pumpAtSize(const Size(640, 420));
    },
  );

  testWidgets('zapret page keeps config controls when GameFilter is disabled', (
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
    final container = ProviderContainer(
      overrides: [
        zapretControllerProvider.overrideWith((ref) => zapretController),
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

    expect(find.text('Gorion Boost'), findsOneWidget);
    expect(find.text('Выбранный конфиг'), findsOneWidget);
    expect(find.text('general'), findsWidgets);
    expect(find.text('GameFilter'), findsNothing);
  });

  testWidgets(
    'zapret recommendation CTA shows report only after tests and keeps progress compact',
    (WidgetTester tester) async {
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.binding.setSurfaceSize(const Size(1280, 800));

      final inProgressController = ZapretController(
        repository: _FakeZapretSettingsRepository(),
        runtimeService: _FakeZapretRuntimeService(),
        initialState: _buildState(
          configTestInProgress: true,
          configTestCompleted: 1,
          configTestTotal: 3,
          configTestCurrentConfigLabel: 'general',
        ),
        loadOnInit: false,
      );

      await _pumpZapretPage(tester, inProgressController);
      expect(find.text('Подбираем рекомендуемый'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.textContaining('Проверяем general'), findsOneWidget);
      expect(find.byTooltip('Подробный отчёт'), findsNothing);

      final completedController = ZapretController(
        repository: _FakeZapretSettingsRepository(),
        runtimeService: _FakeZapretRuntimeService(),
        initialState: _buildState(
          configTestSuite: _buildSuccessfulSuite(),
          statusMessage:
              'Лучший конфиг: general. Выбран автоматически: general.',
        ),
        loadOnInit: false,
      );

      await _pumpZapretPage(tester, completedController);
      expect(find.text('Подобрать рекомендуемый'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.byTooltip('Подробный отчёт'), findsOneWidget);
      expect(find.textContaining('Выбран: general'), findsOneWidget);
    },
  );
}

Future<void> _pumpZapretPage(
  WidgetTester tester,
  ZapretController zapretController,
) async {
  final container = ProviderContainer(
    overrides: [
      zapretControllerProvider.overrideWith((ref) => zapretController),
    ],
  );

  addTearDown(container.dispose);

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
}

ZapretState _buildState({
  bool configTestInProgress = false,
  int configTestCompleted = 0,
  int configTestTotal = 0,
  String? configTestCurrentConfigLabel,
  ZapretConfigTestSuite? configTestSuite,
  String? statusMessage,
}) {
  return ZapretState(
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
      ZapretConfigOption(
        fileName: 'general (ALT10).conf',
        path: r'E:\Tools\zapret2\profiles\general (ALT10).conf',
      ),
    ],
    configTestInProgress: configTestInProgress,
    configTestCompleted: configTestCompleted,
    configTestTotal: configTestTotal,
    configTestCurrentConfigLabel: configTestCurrentConfigLabel,
    configTestSuite: configTestSuite,
    statusMessage: statusMessage,
  );
}

ZapretConfigTestSuite _buildSuccessfulSuite() {
  const target = ZapretProbeTarget(
    id: 'youtube-http11',
    label: 'YouTube HTTP/1.1',
    kind: ZapretProbeKind.http11,
    address: 'https://youtube.com',
  );
  const config = ZapretConfigOption(
    fileName: 'general.conf',
    path: r'E:\Tools\zapret2\profiles\general.conf',
  );
  const result = ZapretConfigTestResult(
    config: config,
    report: ZapretProbeReport(
      results: [
        ZapretProbeResult(target: target, success: true, latencyMs: 128),
      ],
    ),
  );

  return const ZapretConfigTestSuite(
    targets: [target],
    results: [result],
    targetsPath: r'E:\Tools\zapret2\files\targets.txt',
  );
}

class _FakeZapretSettingsRepository extends ZapretSettingsRepository {}

class _FakeZapretRuntimeService extends ZapretRuntimeService {}
