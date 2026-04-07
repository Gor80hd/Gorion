import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gorion_clean/features/auto_select/data/auto_select_preconnect_service.dart';
import 'package:gorion_clean/features/auto_select/data/auto_select_settings_repository.dart';
import 'package:gorion_clean/features/auto_select/data/auto_selector_service.dart';
import 'package:gorion_clean/features/auto_select/model/auto_select_state.dart';
import 'package:gorion_clean/features/home/application/dashboard_controller.dart';
import 'package:gorion_clean/features/home/widget/selected_server_preview_provider.dart';
import 'package:gorion_clean/features/home/widget/servers_panel.dart';
import 'package:gorion_clean/features/profiles/data/profile_repository.dart';
import 'package:gorion_clean/features/profiles/model/profile_models.dart';
import 'package:gorion_clean/features/runtime/data/singbox_runtime_service.dart';
import 'package:gorion_clean/features/runtime/model/runtime_mode.dart';

void main() {
  testWidgets('selecting batch benchmark enters and exits the running state', (
    tester,
  ) async {
    final batchLoadGate = Completer<void>();
    final repository = _FakeProfileRepository(
      responses: [
        const _TemplateLoadResponse.immediate(''),
        _TemplateLoadResponse.waitFor(batchLoadGate, ''),
      ],
    );
    final settingsRepository = _FakeAutoSelectSettingsRepository();
    final controller = DashboardController(
      repository: repository,
      runtimeService: _FakeRuntimeService(),
      autoSelectSettingsRepository: settingsRepository,
      autoSelectPreconnectService: AutoSelectPreconnectService(
        settingsRepository: settingsRepository,
      ),
      autoSelectorService: AutoSelectorService(),
      initialState: _dashboardState(),
      loadOnInit: false,
    );
    final container = ProviderContainer(
      overrides: [
        dashboardControllerProvider.overrideWith((ref) => controller),
        profileRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(container.dispose);

    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: ServersPanelWidget())),
      ),
    );
    await tester.pump(const Duration(seconds: 1));

    final initialLoadCount = repository.loadTemplateConfigCallCount;
    expect(find.byTooltip('Параллельный тест серверов'), findsOneWidget);

    await tester.tap(find.byTooltip('Параллельный тест серверов'));
    await tester.pump();

    expect(repository.loadTemplateConfigCallCount, initialLoadCount + 1);
    expect(container.read(benchmarkActiveProvider), isTrue);
    expect(find.byTooltip('Остановить тест'), findsOneWidget);
    expect(find.text('Подготовка…'), findsOneWidget);

    batchLoadGate.complete();
    await tester.pump();
    await tester.pump();

    expect(container.read(benchmarkActiveProvider), isFalse);
    expect(find.byTooltip('Остановить тест'), findsNothing);
    expect(find.byTooltip('Параллельный тест серверов'), findsOneWidget);
    expect(find.text('Подготовка…'), findsNothing);
  });

  testWidgets('batch benchmark loads only the active profile config', (
    tester,
  ) async {
    final repository = _FakeProfileRepository(
      responses: [
        const _TemplateLoadResponse.immediate(''),
        const _TemplateLoadResponse.immediate(''),
        const _TemplateLoadResponse.immediate(''),
      ],
    );
    final settingsRepository = _FakeAutoSelectSettingsRepository();
    final controller = DashboardController(
      repository: repository,
      runtimeService: _FakeRuntimeService(),
      autoSelectSettingsRepository: settingsRepository,
      autoSelectPreconnectService: AutoSelectPreconnectService(
        settingsRepository: settingsRepository,
      ),
      autoSelectorService: AutoSelectorService(),
      initialState: _dashboardState(
        activeProfileId: 'profile-2',
        profiles: [_buildProfile('profile-1'), _buildProfile('profile-2')],
      ),
      loadOnInit: false,
    );
    final container = ProviderContainer(
      overrides: [
        dashboardControllerProvider.overrideWith((ref) => controller),
        profileRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(container.dispose);

    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: ServersPanelWidget())),
      ),
    );
    await tester.pump(const Duration(seconds: 1));

    repository.loadedProfileIds.clear();

    await tester.tap(find.byTooltip('Параллельный тест серверов'));
    await tester.pumpAndSettle();

    expect(repository.loadedProfileIds, ['profile-2']);
  });

  testWidgets(
    'busy auto card still shows quick reconnect cache presence on RESET',
    (tester) async {
      final repository = _FakeProfileRepository(
        responses: [const _TemplateLoadResponse.immediate('')],
      );
      final settingsRepository = _FakeAutoSelectSettingsRepository();
      final recentSuccessfulAutoConnect = RecentSuccessfulAutoConnect(
        profileId: 'profile-1',
        tag: 'server-1',
        until: DateTime.now().add(const Duration(minutes: 1)),
      );
      final controller = DashboardController(
        repository: repository,
        runtimeService: _FakeRuntimeService(),
        autoSelectSettingsRepository: settingsRepository,
        autoSelectPreconnectService: AutoSelectPreconnectService(
          settingsRepository: settingsRepository,
        ),
        autoSelectorService: AutoSelectorService(),
        initialState: _dashboardState(
          busy: true,
          recentSuccessfulAutoConnect: recentSuccessfulAutoConnect,
        ),
        loadOnInit: false,
      );
      final container = ProviderContainer(
        overrides: [
          dashboardControllerProvider.overrideWith((ref) => controller),
          profileRepositoryProvider.overrideWithValue(repository),
        ],
      );
      addTearDown(container.dispose);

      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: Scaffold(body: ServersPanelWidget())),
        ),
      );
      await tester.pump(const Duration(seconds: 1));

      expect(find.text('RESET'), findsOneWidget);

      final resetTooltips = tester
          .widgetList<Tooltip>(find.byType(Tooltip))
          .where(
            (tooltip) =>
                tooltip.message?.contains('Быстрый кеш переподключения') ??
                false,
          )
          .toList();

      expect(resetTooltips, hasLength(1));
      expect(
        resetTooltips.single.message,
        'Быстрый кеш переподключения сохранён. Сброс будет доступен после завершения текущего действия.',
      );

      final resetButton = tester.widget<TextButton>(
        find.widgetWithText(TextButton, 'RESET'),
      );
      expect(resetButton.onPressed, isNull);
    },
  );
}

DashboardState _dashboardState({
  String activeProfileId = 'profile-1',
  List<ProxyProfile>? profiles,
  bool busy = false,
  RecentSuccessfulAutoConnect? recentSuccessfulAutoConnect,
}) {
  final now = DateTime(2026, 4, 5, 12);
  final resolvedProfiles = profiles ?? [_buildProfile('profile-1', now: now)];
  return DashboardState(
    bootstrapping: false,
    busy: busy,
    runtimeMode: RuntimeMode.mixed,
    storage: StoredProfilesState(
      activeProfileId: activeProfileId,
      profiles: resolvedProfiles,
    ),
    recentSuccessfulAutoConnect: recentSuccessfulAutoConnect,
  );
}

ProxyProfile _buildProfile(String id, {DateTime? now}) {
  final timestamp = now ?? DateTime(2026, 4, 5, 12);
  final suffix = id.split('-').last;
  return ProxyProfile(
    id: id,
    name: 'Example $suffix',
    subscriptionUrl: 'https://example.com/$id',
    templateFileName: '$id.json',
    createdAt: timestamp,
    updatedAt: timestamp,
    servers: [
      ServerEntry(
        tag: 'server-$suffix',
        displayName: 'Server $suffix',
        type: 'vless',
        host: '$id.example.com',
        port: 443,
      ),
    ],
    lastSelectedServerTag: 'server-$suffix',
    lastAutoSelectedServerTag: 'server-$suffix',
  );
}

class _TemplateLoadResponse {
  const _TemplateLoadResponse.immediate(this.content) : gate = null;

  const _TemplateLoadResponse.waitFor(this.gate, this.content);

  final Completer<void>? gate;
  final String content;
}

class _FakeProfileRepository extends ProfileRepository {
  _FakeProfileRepository({required List<_TemplateLoadResponse> responses})
    : _responses = Queue<_TemplateLoadResponse>.from(responses);

  final Queue<_TemplateLoadResponse> _responses;
  int loadTemplateConfigCallCount = 0;
  final List<String> loadedProfileIds = <String>[];

  @override
  Future<String> loadTemplateConfig(ProxyProfile profile) async {
    loadTemplateConfigCallCount += 1;
    loadedProfileIds.add(profile.id);
    final response = _responses.isNotEmpty
        ? _responses.removeFirst()
        : const _TemplateLoadResponse.immediate('');
    await response.gate?.future;
    return response.content;
  }
}

class _FakeAutoSelectSettingsRepository extends AutoSelectSettingsRepository {
  _FakeAutoSelectSettingsRepository()
    : _state = const StoredAutoSelectState(
        settings: AutoSelectSettings(enabled: false),
      );

  StoredAutoSelectState _state;

  @override
  Future<StoredAutoSelectState> clearExpiredCaches() async => _state;

  @override
  Future<StoredAutoSelectState> saveSettings(
    AutoSelectSettings settings,
  ) async {
    _state = _state.copyWith(settings: settings);
    return _state;
  }
}

class _FakeRuntimeService extends SingboxRuntimeService {
  @override
  List<String> get logs => const <String>[];
}
