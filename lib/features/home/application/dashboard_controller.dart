import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gorion/core/logging/gorion_console_log.dart';
import 'package:gorion/core/privileged_helper/macos_helper_installer.dart';
import 'package:gorion/core/windows/elevation_relaunch_prompt_service.dart';
import 'package:gorion/core/windows/windows_elevation_service.dart';
import 'package:gorion/features/auto_select/data/auto_select_preconnect_service.dart';
import 'package:gorion/features/auto_select/data/auto_select_settings_repository.dart';
import 'package:gorion/features/auto_select/data/auto_selector_service.dart';
import 'package:gorion/features/auto_select/model/auto_select_state.dart';
import 'package:gorion/features/home/application/auto_select_candidate_resolver.dart';
import 'package:gorion/features/home/application/dashboard_messages.dart';
import 'package:gorion/features/home/application/dashboard_state.dart';
import 'package:gorion/features/home/application/server_lookup.dart';
import 'package:gorion/features/home/application/tun_privilege_gate.dart';
import 'package:gorion/features/profiles/data/profile_repository.dart';
import 'package:gorion/features/profiles/model/profile_models.dart';
import 'package:gorion/features/runtime/data/adaptive_runtime_engine.dart';
import 'package:gorion/features/runtime/data/clash_api_client.dart';
import 'package:gorion/features/runtime/data/runtime_engine.dart';
import 'package:gorion/features/runtime/model/runtime_mode.dart';
import 'package:gorion/features/runtime/model/runtime_models.dart';
import 'package:gorion/features/settings/data/connection_tuning_config_overrides.dart';
import 'package:gorion/features/settings/data/connection_tuning_settings_repository.dart';
import 'package:gorion/features/settings/model/connection_tuning_settings.dart';
import 'package:gorion/features/settings/model/split_tunnel_settings.dart';

part 'dashboard_auto_select.dart';
part 'dashboard_connection.dart';
part 'dashboard_profiles.dart';

const _preConnectAutoSelectLabel = 'Автовыбор перед подключением';
const _manualAutoSelectLabel = 'Ручной автовыбор';
const _automaticMaintenanceLabel = 'Фоновая проверка';

final profileRepositoryProvider = Provider<ProfileRepository>(
  (ref) => ProfileRepository(),
);

final runtimeEngineProvider = Provider<RuntimeEngine>((ref) {
  final service = buildRuntimeEngine();
  ref.onDispose(service.dispose);
  return service;
});

final autoSelectSettingsRepositoryProvider =
    Provider<AutoSelectSettingsRepository>(
      (ref) => AutoSelectSettingsRepository(),
    );

final connectionTuningSettingsRepositoryProvider =
    Provider<ConnectionTuningSettingsRepository>(
      (ref) => ConnectionTuningSettingsRepository(),
    );

final autoSelectPreconnectServiceProvider =
    Provider<AutoSelectPreconnectService>(
      (ref) => AutoSelectPreconnectService(
        settingsRepository: ref.read(autoSelectSettingsRepositoryProvider),
      ),
    );

final autoSelectorServiceProvider = Provider<AutoSelectorService>(
  (ref) => AutoSelectorService(),
);

typedef ClashApiClientFactory = ClashApiClient Function(RuntimeSession session);

class _CancelledConnectOperation implements Exception {
  const _CancelledConnectOperation([
    this.message = 'Попытка подключения отменена.',
  ]);

  final String message;

  @override
  String toString() => message;
}

final dashboardControllerProvider =
    StateNotifierProvider<DashboardController, DashboardState>((ref) {
      return DashboardController(
        repository: ref.read(profileRepositoryProvider),
        runtimeService: ref.read(runtimeEngineProvider),
        autoSelectSettingsRepository: ref.read(
          autoSelectSettingsRepositoryProvider,
        ),
        connectionTuningSettingsRepository: ref.read(
          connectionTuningSettingsRepositoryProvider,
        ),
        autoSelectPreconnectService: ref.read(
          autoSelectPreconnectServiceProvider,
        ),
        autoSelectorService: ref.read(autoSelectorServiceProvider),
        elevationService: ref.read(windowsElevationServiceProvider),
        elevationPromptService: ref.read(
          elevationRelaunchPromptServiceProvider,
        ),
      );
    });
const _maxAutoSelectTraceLines = 20;
const _bestServerCheckLabels = <String>{
  _preConnectAutoSelectLabel,
  _manualAutoSelectLabel,
  _automaticMaintenanceLabel,
};

/// State owner and shared collaborators of the dashboard. The behaviour
/// lives in the mixins below, one per area: profiles, connection lifecycle
/// and auto-select.
abstract class _DashboardCore extends StateNotifier<DashboardState> {
  _DashboardCore({
    required ProfileRepository repository,
    required RuntimeEngine runtimeService,
    required AutoSelectSettingsRepository autoSelectSettingsRepository,
    ConnectionTuningSettingsRepository? connectionTuningSettingsRepository,
    required AutoSelectPreconnectService autoSelectPreconnectService,
    required AutoSelectorService autoSelectorService,
    WindowsElevationService? elevationService,
    ElevationRelaunchPromptService? elevationPromptService,
    MacosPrivilegedHelperInstaller? macosHelperInstaller,
    ClashApiClientFactory? clashApiClientFactory,
    Timer Function(Duration duration, void Function() callback)? createTimer,
    DashboardState? initialState,
  }) : _repository = repository,
       _runtimeService = runtimeService,
       _autoSelectSettingsRepository = autoSelectSettingsRepository,
       _connectionTuningSettingsRepository =
           connectionTuningSettingsRepository ??
           ConnectionTuningSettingsRepository(),
       _autoSelectPreconnectService = autoSelectPreconnectService,
       _autoSelectorService = autoSelectorService,
       _candidates = AutoSelectCandidateResolver(repository),
       _tunPrivilegeGate = TunPrivilegeGate(
         engine: runtimeService,
         elevationService:
             elevationService ?? const NoopWindowsElevationService(),
         promptService:
             elevationPromptService ??
             const NoopElevationRelaunchPromptService(),
         macosHelperInstaller:
             macosHelperInstaller ?? const MacosPrivilegedHelperInstaller(),
       ),
       _createClashApiClient =
           clashApiClientFactory ?? ClashApiClient.fromSession,
       _createTimer = createTimer ?? _defaultCreateTimer,
       super(
         // copyWith normalizes the runtime mode for this platform.
         (initialState ?? DashboardState(runtimeMode: defaultRuntimeMode()))
             .copyWith(),
       );

  ProxyProfile? _profileById(String profileId) {
    for (final profile in state.storage.profiles) {
      if (profile.id == profileId) {
        return profile;
      }
    }
    return null;
  }

  final ProfileRepository _repository;
  final RuntimeEngine _runtimeService;
  final AutoSelectSettingsRepository _autoSelectSettingsRepository;
  final ConnectionTuningSettingsRepository _connectionTuningSettingsRepository;
  final AutoSelectPreconnectService _autoSelectPreconnectService;
  final AutoSelectorService _autoSelectorService;
  final TunPrivilegeGate _tunPrivilegeGate;
  final ClashApiClientFactory _createClashApiClient;
  final Timer Function(Duration duration, void Function() callback)
  _createTimer;
  Timer? _autoSelectionTimer;
  bool _autoSelectionInFlight = false;
  int _connectOperationId = 0;
  final AutoSelectCandidateResolver _candidates;

  List<ServerEntry> _eligibleAutoSelectServers(
    ProxyProfile profile, {
    AutoSelectSettings? settings,
  }) {
    return _candidates.eligible(profile, settings ?? state.autoSelectSettings);
  }

  Future<List<ServerEntry>> _resolveEligibleAutoSelectServers(
    ProxyProfile profile, {
    AutoSelectSettings? settings,
    String? templateConfig,
  }) {
    return _candidates.resolveEligible(
      profile,
      settings: settings ?? state.autoSelectSettings,
      tuning: state.connectionTuningSettings,
      templateConfig: templateConfig,
    );
  }

  String _applyConnectionTuningSettings(String templateConfig) {
    return applyConnectionTuningSettingsToTemplateConfig(
      templateConfig: templateConfig,
      settings: state.connectionTuningSettings,
    );
  }

  Duration get _currentAutoSelectionInterval =>
      state.autoSelectSettings.bestServerCheckInterval;

  bool _isCurrentConnectedSession(RuntimeSession session, String profileId) {
    return state.connectionStage == ConnectionStage.connected &&
        identical(state.runtimeSession, session) &&
        state.activeProfile?.id == profileId;
  }

  static Timer _defaultCreateTimer(
    Duration duration,
    void Function() callback,
  ) {
    return Timer(duration, callback);
  }
}

class DashboardController extends _DashboardCore
    with _DashboardAutoSelect, _DashboardConnection, _DashboardProfiles {
  DashboardController({
    required super.repository,
    required super.runtimeService,
    required super.autoSelectSettingsRepository,
    super.connectionTuningSettingsRepository,
    required super.autoSelectPreconnectService,
    required super.autoSelectorService,
    super.elevationService,
    super.elevationPromptService,
    super.macosHelperInstaller,
    super.clashApiClientFactory,
    super.createTimer,
    super.initialState,
    bool loadOnInit = true,
  }) {
    if (loadOnInit) {
      unawaited(load());
    }
  }

  @override
  void dispose() {
    _stopAutoSelectionMonitoring();
    super.dispose();
  }

  Future<void> load() async {
    _candidates.invalidate();
    state = state.copyWith(
      bootstrapping: true,
      clearErrorMessage: true,
      clearStatusMessage: true,
      clearAutoSelectActivity: true,
      clearConnectedAt: true,
      clearLastBestServerCheckAt: true,
    );
    try {
      // Recover first: stop orphaned cores and restore a stale system proxy
      // left by a crashed session, and re-attach to a privileged-helper
      // runtime that survived an app restart. Serialized behind the service
      // lifecycle, so a queued auto-connect waits for it.
      await _runtimeService.recoverFromPreviousSession();

      final storageFuture = _repository.loadState();
      final autoSelectStateFuture = _autoSelectSettingsRepository
          .clearExpiredCaches();
      final connectionTuningSettingsFuture = _connectionTuningSettingsRepository
          .load();
      final storage = await storageFuture;
      final autoSelectState = await autoSelectStateFuture;
      final connectionTuningSettings = await connectionTuningSettingsFuture;
      _candidates.invalidate();

      // A live helper-side session means the tunnel is still up: reflect it
      // instead of showing a lying "disconnected" state.
      final adoptedSession = _runtimeService.session;
      state = state.copyWith(
        bootstrapping: false,
        autoSelectSettings: autoSelectState.settings,
        connectionTuningSettings: connectionTuningSettings,
        storage: storage,
        selectedServerTag: storage.activeProfile?.selectedServerTag,
        activeServerTag: storage.activeProfile?.startupServerTag,
        recentSuccessfulAutoConnect:
            autoSelectState.recentSuccessfulAutoConnect,
        autoSelectResults: const [],
        clearAutoSelectActivity: true,
        clearLastBestServerCheckAt: true,
        connectionStage: adoptedSession != null
            ? ConnectionStage.connected
            : ConnectionStage.disconnected,
        runtimeSession: adoptedSession,
        clearRuntimeSession: adoptedSession == null,
        connectedAt: adoptedSession != null ? DateTime.now() : null,
        clearConnectedAt: adoptedSession == null,
      );
      if (adoptedSession != null) {
        unawaited(refreshDelays(silent: true));
      }
    } on Object catch (error) {
      state = state.copyWith(
        bootstrapping: false,
        errorMessage: error.toString(),
      );
    }
  }

  Future<void> saveConnectionTuningSettings(
    ConnectionTuningSettings settings,
  ) async {
    final normalized = settings.copyWith();
    if (state.busy || state.connectionTuningSettings == normalized) {
      return;
    }

    final shouldReconnect = state.connectionStage == ConnectionStage.connected;
    state = state.copyWith(
      busy: true,
      clearErrorMessage: true,
      clearStatusMessage: true,
    );

    try {
      final stored = await _connectionTuningSettingsRepository.save(normalized);
      _candidates.invalidate();
      state = state.copyWith(
        busy: false,
        connectionTuningSettings: stored,
        statusMessage: shouldReconnect
            ? 'Connection settings saved. Reconnect to apply the new overrides.'
            : 'Connection settings saved. The overrides will apply on the next connect.',
      );
    } on Object catch (error) {
      state = state.copyWith(busy: false, errorMessage: error.toString());
    }
  }

  Future<void> refreshSplitTunnelSources([
    SplitTunnelManagedSourceKind? sourceKind,
  ]) async {
    final currentSettings = state.connectionTuningSettings;
    final splitTunnel = currentSettings.splitTunnel;
    if (state.busy) {
      return;
    }

    final hasEligibleSources = switch (sourceKind) {
      SplitTunnelManagedSourceKind.geosite =>
        splitTunnel.hasManagedGeositeSources,
      SplitTunnelManagedSourceKind.geoip => splitTunnel.hasManagedGeoipSources,
      null => splitTunnel.hasManagedRemoteSources,
    };

    if (!hasEligibleSources) {
      state = state.copyWith(
        clearErrorMessage: true,
        statusMessage: sourceKind == SplitTunnelManagedSourceKind.geosite
            ? 'No built-in geosite rule sets are enabled for refresh.'
            : sourceKind == SplitTunnelManagedSourceKind.geoip
            ? 'No built-in geoip rule sets are enabled for refresh.'
            : 'No built-in geosite or geoip rule sets are enabled for refresh.',
      );
      return;
    }

    state = state.copyWith(
      busy: true,
      clearErrorMessage: true,
      clearStatusMessage: true,
    );

    try {
      final nextSplitTunnel = sourceKind == null
          ? splitTunnel.bumpedRemoteRevision()
          : splitTunnel.bumpedManagedSourceRevision(sourceKind);
      final stored = await _connectionTuningSettingsRepository.save(
        currentSettings.copyWith(splitTunnel: nextSplitTunnel),
      );
      _candidates.invalidate();
      state = state.copyWith(
        busy: false,
        connectionTuningSettings: stored,
        statusMessage: _buildSplitTunnelRefreshStatusMessage(sourceKind),
      );
    } on Object catch (error) {
      state = state.copyWith(busy: false, errorMessage: error.toString());
    }
  }

  String _buildSplitTunnelRefreshStatusMessage(
    SplitTunnelManagedSourceKind? sourceKind,
  ) {
    final refreshLabel = switch (sourceKind) {
      SplitTunnelManagedSourceKind.geosite => 'geosite rule sets',
      SplitTunnelManagedSourceKind.geoip => 'geoip rule sets',
      null => 'split tunneling rule sets',
    };

    return state.connectionStage == ConnectionStage.connected
        ? '$refreshLabel were marked for refresh. Reconnect to fetch the latest sources.'
        : '$refreshLabel will refresh on the next connect.';
  }
}
