import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gorion_clean/app/shell.dart';
import 'package:gorion_clean/core/windows/windows_elevation_service.dart';
import 'package:gorion_clean/features/auto_select/data/auto_select_preconnect_service.dart';
import 'package:gorion_clean/features/auto_select/data/auto_select_settings_repository.dart';
import 'package:gorion_clean/features/auto_select/data/auto_selector_service.dart';
import 'package:gorion_clean/features/home/application/dashboard_controller.dart';
import 'package:gorion_clean/features/profiles/data/profile_repository.dart';
import 'package:gorion_clean/features/runtime/data/singbox_runtime_service.dart';
import 'package:gorion_clean/features/zapret/application/zapret_controller.dart';
import 'package:gorion_clean/features/zapret/data/zapret_runtime_service.dart';
import 'package:gorion_clean/features/zapret/data/zapret_settings_repository.dart';
import 'package:gorion_clean/features/zapret/model/zapret_models.dart';
import 'package:gorion_clean/features/zapret/model/zapret_settings.dart';

void main() {
  testWidgets('startup launch refreshes Boost state before auto-starting it', (
    WidgetTester tester,
  ) async {
    if (!Platform.isWindows) {
      return;
    }

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
    final repository = _CountingZapretSettingsRepository();
    final runtimeService = _CountingZapretRuntimeService();
    final zapretController = ZapretController(
      repository: repository,
      runtimeService: runtimeService,
      elevationService: const _ElevatedWindowsElevationService(),
      initialState: ZapretState(
        bootstrapping: false,
        settings: repository.stored,
        availableConfigs: runtimeService.availableProfiles,
      ),
      loadOnInit: false,
    );
    final container = ProviderContainer(
      overrides: [
        appLaunchRequestProvider.overrideWithValue(
          const AppLaunchRequest(launchedAtStartup: true),
        ),
        dashboardControllerProvider.overrideWith((ref) => dashboardController),
        zapretControllerProvider.overrideWith((ref) => zapretController),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: AppShell(child: SizedBox(key: Key('startup-home'))),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(repository.loadCalls, 1);
    expect(runtimeService.startCalls, 1);
    expect(
      runtimeService.lastStartedSettings?.effectiveConfigFileName,
      'general (ALT10).conf',
    );
  });
}

class _FakeAutoSelectSettingsRepository extends AutoSelectSettingsRepository {}

class _FakeProfileRepository extends ProfileRepository {}

class _FakeRuntimeService extends SingboxRuntimeService {
  @override
  List<String> get logs => const <String>[];
}

class _CountingZapretSettingsRepository extends ZapretSettingsRepository {
  _CountingZapretSettingsRepository() : super(storageRootLoader: null);

  int loadCalls = 0;
  ZapretSettings stored = const ZapretSettings(
    installDirectory: r'E:\Tools\zapret2',
    configFileName: 'general (ALT10).conf',
    startOnAppLaunch: true,
  );

  @override
  Future<ZapretSettings> load() async {
    loadCalls += 1;
    return stored;
  }
}

class _CountingZapretRuntimeService extends ZapretRuntimeService {
  int startCalls = 0;
  ZapretSettings? lastStartedSettings;

  final List<ZapretConfigOption> availableProfiles = const [
    ZapretConfigOption(
      fileName: 'general.conf',
      path: r'E:\Tools\zapret2\profiles\general.conf',
    ),
    ZapretConfigOption(
      fileName: 'general (ALT10).conf',
      path: r'E:\Tools\zapret2\profiles\general (ALT10).conf',
    ),
  ];

  @override
  List<String> get logs => const <String>[];

  @override
  Future<ZapretSettings> hydrateSettings(ZapretSettings settings) async {
    return settings;
  }

  @override
  List<ZapretConfigOption> listAvailableProfiles(String installDirectory) {
    return availableProfiles;
  }

  @override
  String resolveSelectedConfigFileName(
    String installDirectory,
    String preferredFileName,
  ) {
    return preferredFileName;
  }

  @override
  ZapretLaunchConfiguration buildPreview(ZapretSettings settings) {
    return ZapretLaunchConfiguration(
      executablePath: r'E:\Tools\zapret2\bin\winws.exe',
      workingDirectory: r'E:\Tools\zapret2\bin',
      arguments: const ['--wf-tcp=80,443,12'],
      requiredFiles: const [],
      preview: 'preview',
      summary: formatZapretConfigLabel(settings.effectiveConfigFileName),
    );
  }

  @override
  Future<ZapretRuntimeSession> start({
    required ZapretSettings settings,
    required void Function(int exitCode) onExit,
    bool preserveLogs = false,
  }) async {
    startCalls += 1;
    lastStartedSettings = settings;
    return ZapretRuntimeSession(
      executablePath: r'E:\Tools\zapret2\bin\winws.exe',
      workingDirectory: r'E:\Tools\zapret2\bin',
      processId: 4242,
      startedAt: DateTime(2026, 4, 20, 9),
      arguments: const ['--wf-tcp=80,443,12'],
      commandPreview: 'preview',
    );
  }
}

class _ElevatedWindowsElevationService implements WindowsElevationService {
  const _ElevatedWindowsElevationService();

  @override
  Future<bool> isElevated() async {
    return true;
  }

  @override
  Future<void> relaunchAsAdministrator({
    required PendingElevatedLaunchAction action,
  }) async {}
}
