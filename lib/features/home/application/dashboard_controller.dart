import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gorion_clean/core/windows/windows_elevation_service.dart';
import 'package:gorion_clean/core/windows/elevation_relaunch_prompt_service.dart';
import 'package:gorion_clean/core/logging/gorion_console_log.dart';
import 'package:gorion_clean/features/auto_select/data/auto_select_preconnect_service.dart';
import 'package:gorion_clean/features/auto_select/data/auto_select_settings_repository.dart';
import 'package:gorion_clean/features/auto_select/model/auto_select_state.dart';
import 'package:gorion_clean/features/auto_select/data/auto_selector_service.dart';
import 'package:gorion_clean/features/auto_select/utils/auto_select_server_config.dart';
import 'package:gorion_clean/features/profiles/data/profile_repository.dart';
import 'package:gorion_clean/features/profiles/model/profile_models.dart';
import 'package:gorion_clean/features/settings/data/connection_tuning_config_overrides.dart';
import 'package:gorion_clean/features/settings/data/connection_tuning_settings_repository.dart';
import 'package:gorion_clean/features/settings/model/connection_tuning_settings.dart';
import 'package:gorion_clean/features/settings/model/split_tunnel_settings.dart';
import 'package:gorion_clean/features/runtime/data/clash_api_client.dart';
import 'package:gorion_clean/features/runtime/model/runtime_mode.dart';
import 'package:gorion_clean/features/runtime/data/singbox_runtime_service.dart';
import 'package:gorion_clean/features/runtime/model/runtime_models.dart';
import 'package:gorion_clean/utils/server_display_text.dart';

const systemProxyStartupSettleDelay = Duration(milliseconds: 1500);

final profileRepositoryProvider = Provider<ProfileRepository>(
  (ref) => ProfileRepository(),
);

final singboxRuntimeServiceProvider = Provider<SingboxRuntimeService>((ref) {
  final service = buildSingboxRuntimeService();
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

RuntimeMode _defaultRuntimeMode() {
  if (Platform.isWindows) {
    return RuntimeMode.systemProxy;
  }
  return RuntimeMode.mixed;
}

RuntimeMode _normalizeRuntimeMode(RuntimeMode mode) {
  if (Platform.isWindows && mode == RuntimeMode.mixed) {
    return RuntimeMode.systemProxy;
  }
  return mode;
}

RuntimeMode _effectiveRuntimeMode(RuntimeMode mode) {
  return _normalizeRuntimeMode(mode);
}

String _describeAutoSelectBestServerCheckInterval(int minutes) {
  final hours = minutes ~/ 60;
  final remainingMinutes = minutes % 60;
  if (hours > 0 && remainingMinutes > 0) {
    return '$hours ${hours == 1 ? 'hour' : 'hours'} '
        '$remainingMinutes '
        '${remainingMinutes == 1 ? 'minute' : 'minutes'}';
  }
  if (hours > 0) {
    return '$hours ${hours == 1 ? 'hour' : 'hours'}';
  }
  return '$minutes ${minutes == 1 ? 'minute' : 'minutes'}';
}

class _CancelledConnectOperation implements Exception {
  const _CancelledConnectOperation([
    this.message = 'Connection attempt was cancelled.',
  ]);

  final String message;

  @override
  String toString() => message;
}

DashboardState _normalizeDashboardState(DashboardState state) {
  return state.copyWith(runtimeMode: _normalizeRuntimeMode(state.runtimeMode));
}

final dashboardControllerProvider =
    StateNotifierProvider<DashboardController, DashboardState>((ref) {
      return DashboardController(
        repository: ref.read(profileRepositoryProvider),
        runtimeService: ref.read(singboxRuntimeServiceProvider),
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
        systemProxyStartupSettleDelay: Platform.isWindows
            ? systemProxyStartupSettleDelay
            : Duration.zero,
      );
    });

class DashboardState {
  const DashboardState({
    this.bootstrapping = true,
    this.busy = false,
    this.refreshingDelays = false,
    this.runtimeMode = RuntimeMode.mixed,
    this.autoSelectSettings = const AutoSelectSettings(),
    this.connectionTuningSettings = const ConnectionTuningSettings(),
    this.storage = const StoredProfilesState(),
    this.connectionStage = ConnectionStage.disconnected,
    this.runtimeSession,
    this.connectedAt,
    this.delayByTag = const {},
    this.selectedServerTag,
    this.activeServerTag,
    this.recentSuccessfulAutoConnect,
    this.autoSelectResults = const [],
    this.autoSelectActivity = const AutoSelectActivityState(),
    this.lastBestServerCheckAt,
    this.statusMessage,
    this.errorMessage,
    this.logs = const [],
  });

  final bool bootstrapping;
  final bool busy;
  final bool refreshingDelays;
  final RuntimeMode runtimeMode;
  final AutoSelectSettings autoSelectSettings;
  final ConnectionTuningSettings connectionTuningSettings;
  final StoredProfilesState storage;
  final ConnectionStage connectionStage;
  final RuntimeSession? runtimeSession;
  final DateTime? connectedAt;
  final Map<String, int> delayByTag;
  final String? selectedServerTag;
  final String? activeServerTag;
  final RecentSuccessfulAutoConnect? recentSuccessfulAutoConnect;
  final List<AutoSelectProbeResult> autoSelectResults;
  final AutoSelectActivityState autoSelectActivity;
  final DateTime? lastBestServerCheckAt;
  final String? statusMessage;
  final String? errorMessage;
  final List<String> logs;

  ProxyProfile? get activeProfile => storage.activeProfile;

  bool get hasRecentSuccessfulAutoConnectForActiveProfile {
    final profileId = activeProfile?.id;
    if (profileId == null) {
      return false;
    }

    return recentSuccessfulAutoConnect?.matchesProfile(profileId) ?? false;
  }

  DashboardState copyWith({
    bool? bootstrapping,
    bool? busy,
    bool? refreshingDelays,
    RuntimeMode? runtimeMode,
    AutoSelectSettings? autoSelectSettings,
    ConnectionTuningSettings? connectionTuningSettings,
    StoredProfilesState? storage,
    ConnectionStage? connectionStage,
    RuntimeSession? runtimeSession,
    bool clearRuntimeSession = false,
    DateTime? connectedAt,
    bool clearConnectedAt = false,
    Map<String, int>? delayByTag,
    String? selectedServerTag,
    bool clearSelectedServerTag = false,
    String? activeServerTag,
    bool clearActiveServerTag = false,
    RecentSuccessfulAutoConnect? recentSuccessfulAutoConnect,
    bool clearRecentSuccessfulAutoConnect = false,
    List<AutoSelectProbeResult>? autoSelectResults,
    AutoSelectActivityState? autoSelectActivity,
    bool clearAutoSelectActivity = false,
    DateTime? lastBestServerCheckAt,
    bool clearLastBestServerCheckAt = false,
    String? statusMessage,
    bool clearStatusMessage = false,
    String? errorMessage,
    bool clearErrorMessage = false,
    List<String>? logs,
  }) {
    return DashboardState(
      bootstrapping: bootstrapping ?? this.bootstrapping,
      busy: busy ?? this.busy,
      refreshingDelays: refreshingDelays ?? this.refreshingDelays,
      runtimeMode: _normalizeRuntimeMode(runtimeMode ?? this.runtimeMode),
      autoSelectSettings: autoSelectSettings ?? this.autoSelectSettings,
      connectionTuningSettings:
          connectionTuningSettings ?? this.connectionTuningSettings,
      storage: storage ?? this.storage,
      connectionStage: connectionStage ?? this.connectionStage,
      runtimeSession: clearRuntimeSession
          ? null
          : runtimeSession ?? this.runtimeSession,
      connectedAt: clearConnectedAt ? null : connectedAt ?? this.connectedAt,
      delayByTag: delayByTag ?? this.delayByTag,
      selectedServerTag: clearSelectedServerTag
          ? null
          : selectedServerTag ?? this.selectedServerTag,
      activeServerTag: clearActiveServerTag
          ? null
          : activeServerTag ?? this.activeServerTag,
      recentSuccessfulAutoConnect: clearRecentSuccessfulAutoConnect
          ? null
          : recentSuccessfulAutoConnect ?? this.recentSuccessfulAutoConnect,
      autoSelectResults: autoSelectResults ?? this.autoSelectResults,
      autoSelectActivity: clearAutoSelectActivity
          ? const AutoSelectActivityState()
          : autoSelectActivity ?? this.autoSelectActivity,
      lastBestServerCheckAt: clearLastBestServerCheckAt
          ? null
          : lastBestServerCheckAt ?? this.lastBestServerCheckAt,
      statusMessage: clearStatusMessage
          ? null
          : statusMessage ?? this.statusMessage,
      errorMessage: clearErrorMessage
          ? null
          : errorMessage ?? this.errorMessage,
      logs: logs ?? this.logs,
    );
  }
}

class DashboardController extends StateNotifier<DashboardState> {
  static const _maxAutoSelectTraceLines = 20;
  static const _bestServerCheckLabels = <String>{
    'Pre-connect auto-select',
    'Manual auto-select',
    'Automatic maintenance',
  };

  DashboardController({
    required ProfileRepository repository,
    required SingboxRuntimeService runtimeService,
    required AutoSelectSettingsRepository autoSelectSettingsRepository,
    ConnectionTuningSettingsRepository? connectionTuningSettingsRepository,
    required AutoSelectPreconnectService autoSelectPreconnectService,
    required AutoSelectorService autoSelectorService,
    WindowsElevationService? elevationService,
    ElevationRelaunchPromptService? elevationPromptService,
    ClashApiClientFactory? clashApiClientFactory,
    Duration systemProxyStartupSettleDelay = Duration.zero,
    Timer Function(Duration duration, void Function() callback)? createTimer,
    Future<void> Function(Duration duration)? pause,
    DashboardState? initialState,
    bool loadOnInit = true,
  }) : _repository = repository,
       _runtimeService = runtimeService,
       _autoSelectSettingsRepository = autoSelectSettingsRepository,
       _connectionTuningSettingsRepository =
           connectionTuningSettingsRepository ??
           ConnectionTuningSettingsRepository(),
       _autoSelectPreconnectService = autoSelectPreconnectService,
       _autoSelectorService = autoSelectorService,
       _elevationService =
           elevationService ?? const NoopWindowsElevationService(),
       _elevationPromptService =
           elevationPromptService ?? const NoopElevationRelaunchPromptService(),
       _createClashApiClient =
           clashApiClientFactory ?? ClashApiClient.fromSession,
       _systemProxyStartupSettleDelay = systemProxyStartupSettleDelay,
       _createTimer = createTimer ?? _defaultCreateTimer,
       _pause = pause ?? _defaultPause,
       super(
         _normalizeDashboardState(
           initialState ?? DashboardState(runtimeMode: _defaultRuntimeMode()),
         ),
       ) {
    if (loadOnInit) {
      unawaited(load());
    }
  }

  ProxyProfile? _profileById(String profileId) {
    for (final profile in state.storage.profiles) {
      if (profile.id == profileId) {
        return profile;
      }
    }
    return null;
  }

  final ProfileRepository _repository;
  final SingboxRuntimeService _runtimeService;
  final AutoSelectSettingsRepository _autoSelectSettingsRepository;
  final ConnectionTuningSettingsRepository _connectionTuningSettingsRepository;
  final AutoSelectPreconnectService _autoSelectPreconnectService;
  final AutoSelectorService _autoSelectorService;
  final WindowsElevationService _elevationService;
  final ElevationRelaunchPromptService _elevationPromptService;
  final ClashApiClientFactory _createClashApiClient;
  final Duration _systemProxyStartupSettleDelay;
  final Timer Function(Duration duration, void Function() callback)
  _createTimer;
  final Future<void> Function(Duration duration) _pause;
  Timer? _autoSelectionTimer;
  bool _autoSelectionInFlight = false;
  int _connectOperationId = 0;

  Duration get _currentAutoSelectionInterval =>
      state.autoSelectSettings.bestServerCheckInterval;

  @override
  void dispose() {
    _stopAutoSelectionMonitoring();
    super.dispose();
  }

  void _startAutoSelectActivity(String label, {String? message}) {
    state = state.copyWith(
      autoSelectActivity: AutoSelectActivityState(
        active: true,
        label: label,
        message: message,
      ),
    );
    if (message != null && message.isNotEmpty) {
      _appendAutoSelectActivity(
        label,
        message,
        active: true,
        completedSteps: 0,
      );
    }
  }

  void _appendAutoSelectActivity(
    String label,
    String message, {
    required bool active,
    int? completedSteps,
    int? totalSteps,
    bool isError = false,
  }) {
    GorionConsoleLog.autoSelect(
      label: label,
      message: message,
      completedSteps: completedSteps,
      totalSteps: totalSteps,
      isError: isError,
    );
    final timestamped = '${_autoSelectTimestamp()} [$label] $message';
    final nextLogLines = [...state.autoSelectActivity.logLines, timestamped];
    if (nextLogLines.length > _maxAutoSelectTraceLines) {
      nextLogLines.removeRange(
        0,
        nextLogLines.length - _maxAutoSelectTraceLines,
      );
    }

    state = state.copyWith(
      autoSelectActivity: AutoSelectActivityState(
        active: active,
        label: label,
        message: message,
        completedSteps:
            completedSteps ?? state.autoSelectActivity.completedSteps,
        totalSteps: totalSteps ?? state.autoSelectActivity.totalSteps,
        logLines: nextLogLines,
      ),
    );
  }

  void _reportAutoSelectProgress(
    String label,
    AutoSelectProgressEvent event, {
    RuntimeSession? session,
    String? profileId,
  }) {
    if (session != null &&
        profileId != null &&
        !_isCurrentConnectedSession(session, profileId)) {
      return;
    }

    _appendAutoSelectActivity(
      label,
      event.message,
      active: true,
      completedSteps: event.completedSteps,
      totalSteps: event.totalSteps,
    );
  }

  void _finishAutoSelectActivity(
    String label, {
    String? message,
    int? completedSteps,
    int? totalSteps,
    RuntimeSession? session,
    String? profileId,
    bool isError = false,
  }) {
    if (session != null &&
        profileId != null &&
        !_isCurrentConnectedSession(session, profileId)) {
      return;
    }

    final completedAt = _bestServerCheckLabels.contains(label)
        ? DateTime.now()
        : null;

    if (message != null && message.isNotEmpty) {
      _appendAutoSelectActivity(
        label,
        message,
        active: false,
        completedSteps: completedSteps,
        totalSteps: totalSteps,
        isError: isError,
      );
      if (completedAt != null) {
        state = state.copyWith(lastBestServerCheckAt: completedAt);
      }
      return;
    }

    state = state.copyWith(
      autoSelectActivity: state.autoSelectActivity.copyWith(active: false),
      lastBestServerCheckAt: completedAt,
    );
  }

  String _autoSelectTimestamp() {
    final now = DateTime.now().toLocal();
    final hour = now.hour.toString().padLeft(2, '0');
    final minute = now.minute.toString().padLeft(2, '0');
    final second = now.second.toString().padLeft(2, '0');
    return '$hour:$minute:$second';
  }

  Future<void> load() async {
    state = state.copyWith(
      bootstrapping: true,
      clearErrorMessage: true,
      clearStatusMessage: true,
      clearAutoSelectActivity: true,
      clearConnectedAt: true,
      clearLastBestServerCheckAt: true,
    );
    try {
      final storageFuture = _repository.loadState();
      final autoSelectStateFuture = _autoSelectSettingsRepository
          .clearExpiredCaches();
      final connectionTuningSettingsFuture = _connectionTuningSettingsRepository
          .load();
      final storage = await storageFuture;
      final autoSelectState = await autoSelectStateFuture;
      final connectionTuningSettings = await connectionTuningSettingsFuture;
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
        clearConnectedAt: true,
        clearLastBestServerCheckAt: true,
      );
    } on Object catch (error) {
      state = state.copyWith(
        bootstrapping: false,
        errorMessage: error.toString(),
      );
    }
  }

  Future<void> addSubscription(String url) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) {
      state = state.copyWith(
        errorMessage: 'Paste a subscription URL first.',
        clearStatusMessage: true,
      );
      return;
    }

    state = state.copyWith(
      busy: true,
      clearErrorMessage: true,
      clearStatusMessage: true,
      clearAutoSelectActivity: true,
    );
    try {
      final storage = await _repository.addRemoteSubscription(trimmed);
      state = state.copyWith(
        busy: false,
        storage: storage,
        selectedServerTag: storage.activeProfile?.selectedServerTag,
        activeServerTag: storage.activeProfile?.startupServerTag,
        autoSelectResults: const [],
        statusMessage: 'Subscription saved. Servers are ready for connection.',
      );
    } on Object catch (error) {
      state = state.copyWith(busy: false, errorMessage: error.toString());
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

  Future<void> chooseProfile(String profileId) async {
    final previousProfileId = state.activeProfile?.id;
    _stopAutoSelectionMonitoring();

    if (state.connectionStage == ConnectionStage.connected ||
        state.connectionStage == ConnectionStage.starting) {
      await disconnect();
    }

    if (previousProfileId != null && previousProfileId != profileId) {
      _autoSelectorService.resetProfileState(previousProfileId);
    }

    state = state.copyWith(
      busy: true,
      clearErrorMessage: true,
      clearStatusMessage: true,
    );
    try {
      final storage = await _repository.setActiveProfile(profileId);
      state = state.copyWith(
        busy: false,
        storage: storage,
        selectedServerTag: storage.activeProfile?.selectedServerTag,
        activeServerTag: storage.activeProfile?.startupServerTag,
        delayByTag: const {},
        autoSelectResults: const [],
        clearAutoSelectActivity: true,
        clearConnectedAt: true,
        clearLastBestServerCheckAt: true,
      );
    } on Object catch (error) {
      state = state.copyWith(busy: false, errorMessage: error.toString());
    }
  }

  Future<void> setAutoSelectEnabled(bool enabled) async {
    final currentSettings = state.autoSelectSettings;
    if (state.busy || currentSettings.enabled == enabled) {
      return;
    }

    final profile = state.activeProfile;
    final shouldKickMonitor =
        enabled &&
        state.connectionStage == ConnectionStage.connected &&
        state.runtimeSession != null &&
        profile != null &&
        profile.prefersAutoSelection;

    state = state.copyWith(
      busy: true,
      clearErrorMessage: true,
      clearStatusMessage: true,
    );
    try {
      final stored = await _autoSelectSettingsRepository.saveSettings(
        currentSettings.copyWith(enabled: enabled),
      );
      state = state.copyWith(
        busy: false,
        autoSelectSettings: stored.settings,
        recentSuccessfulAutoConnect: stored.recentSuccessfulAutoConnect,
        clearLastBestServerCheckAt: !enabled,
        statusMessage: enabled
            ? 'Automatic server selection is enabled.'
            : 'Automatic server selection is disabled.',
      );

      if (!enabled) {
        _stopAutoSelectionMonitoring();
        return;
      }

      if (shouldKickMonitor) {
        _runAutomaticAutoSelectNow(
          allowSwitchDuringCooldown: true,
          surfaceFailures: true,
        );
      }
    } on Object catch (error) {
      state = state.copyWith(busy: false, errorMessage: error.toString());
    }
  }

  Future<void> setAutoSelectIpCheck(bool checkIp) async {
    final currentSettings = state.autoSelectSettings;
    if (state.busy || currentSettings.checkIp == checkIp) {
      return;
    }

    final profile = state.activeProfile;
    final shouldKickMonitor =
        currentSettings.enabled &&
        state.connectionStage == ConnectionStage.connected &&
        state.runtimeSession != null &&
        profile != null &&
        profile.prefersAutoSelection;

    state = state.copyWith(
      busy: true,
      clearErrorMessage: true,
      clearStatusMessage: true,
    );
    try {
      final stored = await _autoSelectSettingsRepository.saveSettings(
        currentSettings.copyWith(checkIp: checkIp),
      );
      state = state.copyWith(
        busy: false,
        autoSelectSettings: stored.settings,
        recentSuccessfulAutoConnect: stored.recentSuccessfulAutoConnect,
        statusMessage: checkIp
            ? 'IP-only probe is required during automatic selection.'
            : 'IP-only probe is optional during automatic selection.',
      );

      if (shouldKickMonitor) {
        _runAutomaticAutoSelectNow(
          allowSwitchDuringCooldown: true,
          surfaceFailures: true,
        );
      }
    } on Object catch (error) {
      state = state.copyWith(busy: false, errorMessage: error.toString());
    }
  }

  Future<void> setAutoSelectBestServerCheckIntervalMinutes(int minutes) async {
    final clampedMinutes = clampAutoSelectBestServerCheckIntervalMinutes(
      minutes,
    );
    final currentSettings = state.autoSelectSettings;
    if (state.busy ||
        currentSettings.bestServerCheckIntervalMinutes == clampedMinutes) {
      return;
    }

    final shouldRescheduleMonitor = _shouldMonitorAutoSelection();

    state = state.copyWith(
      busy: true,
      clearErrorMessage: true,
      clearStatusMessage: true,
    );
    try {
      final stored = await _autoSelectSettingsRepository.saveSettings(
        currentSettings.copyWith(
          bestServerCheckIntervalMinutes: clampedMinutes,
        ),
      );
      final updatedSettings = stored.settings;
      state = state.copyWith(
        busy: false,
        autoSelectSettings: updatedSettings,
        recentSuccessfulAutoConnect: stored.recentSuccessfulAutoConnect,
        statusMessage:
            'Automatic best-server checks now run every '
            '${_describeAutoSelectBestServerCheckInterval(updatedSettings.bestServerCheckIntervalMinutes)}.',
      );

      if (shouldRescheduleMonitor && !_autoSelectionInFlight) {
        _scheduleNextAutoSelectionPass();
      }
    } on Object catch (error) {
      state = state.copyWith(busy: false, errorMessage: error.toString());
    }
  }

  Future<void> setAutoSelectServerExcluded(
    String serverTag,
    bool excluded,
  ) async {
    final profile = state.activeProfile;
    if (profile == null || state.busy || isAutoSelectServerTag(serverTag)) {
      return;
    }

    final currentSettings = state.autoSelectSettings;
    final alreadyExcluded = currentSettings.isExcluded(profile.id, serverTag);
    if (alreadyExcluded == excluded) {
      return;
    }

    final shouldKickMonitor =
        currentSettings.enabled &&
        state.connectionStage == ConnectionStage.connected &&
        state.runtimeSession != null &&
        profile.prefersAutoSelection;

    state = state.copyWith(
      busy: true,
      clearErrorMessage: true,
      clearStatusMessage: true,
    );
    try {
      final stored = await _autoSelectSettingsRepository.updateExcludedServer(
        profileId: profile.id,
        serverTag: serverTag,
        excluded: excluded,
      );
      final updatedSettings = stored.settings;
      final eligibleServers = _eligibleAutoSelectServers(
        profile,
        settings: updatedSettings,
      );

      state = state.copyWith(
        busy: false,
        autoSelectSettings: updatedSettings,
        recentSuccessfulAutoConnect: stored.recentSuccessfulAutoConnect,
        statusMessage: excluded
            ? 'Server $serverTag was excluded from automatic selection.'
            : 'Server $serverTag was returned to automatic selection.',
      );

      if (shouldKickMonitor) {
        if (eligibleServers.isEmpty) {
          _stopAutoSelectionMonitoring();
          state = state.copyWith(
            statusMessage:
                'All servers for the active profile are excluded from automatic selection.',
          );
          return;
        }

        _runAutomaticAutoSelectNow(
          allowSwitchDuringCooldown: true,
          surfaceFailures: true,
        );
      }
    } on Object catch (error) {
      state = state.copyWith(busy: false, errorMessage: error.toString());
    }
  }

  Future<void> connect() async {
    final connectOperationId = _beginConnectOperation();
    final profile = state.activeProfile;
    if (profile == null) {
      state = state.copyWith(
        errorMessage: 'Add a subscription before connecting.',
        clearStatusMessage: true,
      );
      return;
    }

    if (await _maybeRelaunchForTunElevation()) {
      return;
    }

    _stopAutoSelectionMonitoring();

    state = state.copyWith(
      busy: true,
      connectionStage: ConnectionStage.starting,
      autoSelectResults: const [],
      clearErrorMessage: true,
      clearStatusMessage: true,
      clearAutoSelectActivity: true,
      clearConnectedAt: true,
      clearLastBestServerCheckAt: true,
    );

    try {
      final selectedMode = state.runtimeMode;
      final originalTemplateConfig = await _repository.loadTemplateConfig(
        profile,
      );
      _throwIfConnectOperationCancelled(connectOperationId);
      final templateConfig = _applyConnectionTuningSettings(
        originalTemplateConfig,
      );
      final autoSelectSettings = state.autoSelectSettings;
      PreparedAutoConnectSelection? preparedAutoSelection;
      var startupServerTag = profile.startupServerTag;
      if (profile.prefersAutoSelection && autoSelectSettings.enabled) {
        preparedAutoSelection = await _autoSelectPreconnectService
            .recentSuccessfulSelection(
              profile: profile,
              templateConfig: templateConfig,
            );
        _throwIfConnectOperationCancelled(connectOperationId);
        if (preparedAutoSelection?.reusedRecentSuccessfulSelection ?? false) {
          state = state.copyWith(
            autoSelectActivity: AutoSelectActivityState(
              label: 'Pre-connect auto-select',
              message: preparedAutoSelection!.summary,
            ),
          );
        } else {
          _startAutoSelectActivity(
            'Pre-connect auto-select',
            message:
                'Loading saved auto-select state and preparing candidate probes.',
          );
          preparedAutoSelection = await _autoSelectPreconnectService.prepare(
            profile: profile,
            templateConfig: templateConfig,
            abortReason: () => _connectOperationAbortReason(connectOperationId),
            onProgress: (event) {
              _reportAutoSelectProgress('Pre-connect auto-select', event);
            },
          );
          _throwIfConnectOperationCancelled(connectOperationId);
          _finishAutoSelectActivity('Pre-connect auto-select');
        }
        startupServerTag =
            preparedAutoSelection?.selectedServerTag ?? startupServerTag;
      }
      _throwIfConnectOperationCancelled(connectOperationId);
      final session = await _runtimeService.start(
        profileId: profile.id,
        templateConfig: templateConfig,
        originalTemplateConfig: originalTemplateConfig,
        connectionTuningSettings: state.connectionTuningSettings,
        urlTestUrl: resolveAutoSelectUrlTestUrl(
          autoSelectSettings.domainProbeUrl,
          rotationKey: '${profile.id}::runtime::urltest',
        ),
        mode: selectedMode,
        selectedServerTag: startupServerTag,
      );
      _throwIfConnectOperationCancelled(connectOperationId);
      await _waitForSystemProxyStartupSettle(mode: selectedMode);
      _throwIfConnectOperationCancelled(connectOperationId);
      final client = _createClashApiClient(session);
      final snapshot = await client.fetchSnapshot(
        selectorTag: session.manualSelectorTag,
      );
      _throwIfConnectOperationCancelled(connectOperationId);
      final delays = await _safeLoadDelays(client, session);
      _throwIfConnectOperationCancelled(connectOperationId);
      final connectedTag = snapshot.selectedTag ?? startupServerTag;
      var persistedStorage = snapshot.selectedTag == null
          ? state.storage
          : profile.prefersAutoSelection
          ? await _repository.updateAutoSelectedServer(
              profile.id,
              snapshot.selectedTag!,
            )
          : await _repository.updateSelectedServer(
              profile.id,
              snapshot.selectedTag!,
            );
      var effectiveDelayByTag = {
        ...preparedAutoSelection?.delayByTag ?? const <String, int>{},
        ...delays,
      };
      var effectiveActiveServerTag = connectedTag;
      var effectiveProbes =
          preparedAutoSelection?.probes ?? const <AutoSelectProbeResult>[];
      final shouldRunLightweightCurrentVerification =
          preparedAutoSelection?.reusedRecentSuccessfulSelection ?? false;
      final shouldVerifyPostConnectInternetAccess =
          preparedAutoSelection == null ||
          preparedAutoSelection.requiresImmediatePostConnectCheck ||
          shouldRunLightweightCurrentVerification;

      final verification = shouldVerifyPostConnectInternetAccess
          ? await _verifyPostConnectInternetAccess(
              profile: profile,
              session: session,
              storage: persistedStorage,
              activeServerTag: effectiveActiveServerTag,
              delayByTag: effectiveDelayByTag,
              templateConfig: templateConfig,
              forceCurrentServerOnly: shouldRunLightweightCurrentVerification,
            )
          : (
              storage: persistedStorage,
              activeServerTag: effectiveActiveServerTag,
              delayByTag: effectiveDelayByTag,
              probes: effectiveProbes,
              statusMessage: null,
              failureMessage: null,
            );
      _throwIfConnectOperationCancelled(connectOperationId);
      persistedStorage = verification.storage;
      effectiveDelayByTag = verification.delayByTag;
      effectiveActiveServerTag = verification.activeServerTag;
      effectiveProbes = verification.probes;

      if (verification.failureMessage case final failureMessage?) {
        if (profile.prefersAutoSelection && autoSelectSettings.enabled) {
          await _clearRecentSuccessfulAutoConnect(ignoreErrors: true);
        }
        await _runtimeService.stop();
        _autoSelectorService.resetProfileState(session.profileId);
        state = state.copyWith(
          busy: false,
          storage: persistedStorage,
          connectionStage: ConnectionStage.disconnected,
          clearRuntimeSession: true,
          clearConnectedAt: true,
          delayByTag: effectiveDelayByTag,
          selectedServerTag:
              persistedStorage.activeProfile?.selectedServerTag ??
              profile.selectedServerTag,
          activeServerTag:
              effectiveActiveServerTag ?? connectedTag ?? startupServerTag,
          autoSelectResults: effectiveProbes,
          clearLastBestServerCheckAt: true,
          clearStatusMessage: true,
          errorMessage: failureMessage,
          logs: _runtimeService.logs,
        );
        return;
      }

      if (profile.prefersAutoSelection &&
          autoSelectSettings.enabled &&
          effectiveActiveServerTag != null) {
        _throwIfConnectOperationCancelled(connectOperationId);
        final recentSuccessfulAutoConnect = await _updateRecentAutoSelectCaches(
          profileId: profile.id,
          serverTag: effectiveActiveServerTag,
        );
        _throwIfConnectOperationCancelled(connectOperationId);
        state = state.copyWith(
          recentSuccessfulAutoConnect: recentSuccessfulAutoConnect,
        );
      }

      final statusMessage = preparedAutoSelection == null
          ? _connectedStatus(session)
          : '${preparedAutoSelection.summary} ${_connectedStatus(session)}';
      final effectiveStatusMessage =
          verification.statusMessage ?? statusMessage;
      _throwIfConnectOperationCancelled(connectOperationId);

      state = state.copyWith(
        busy: false,
        storage: persistedStorage,
        connectionStage: ConnectionStage.connected,
        runtimeSession: session,
        connectedAt: DateTime.now(),
        delayByTag: effectiveDelayByTag,
        selectedServerTag:
            persistedStorage.activeProfile?.selectedServerTag ??
            profile.selectedServerTag,
        activeServerTag: effectiveActiveServerTag,
        autoSelectResults: effectiveProbes,
        statusMessage: effectiveStatusMessage,
        logs: _runtimeService.logs,
      );
      if (profile.prefersAutoSelection && autoSelectSettings.enabled) {
        _startAutoSelectionMonitoring();
      }
    } on Object catch (error) {
      if (error is _CancelledConnectOperation ||
          !_isConnectOperationCurrent(connectOperationId)) {
        return;
      }
      if (state.autoSelectActivity.active &&
          state.autoSelectActivity.label == 'Pre-connect auto-select') {
        _finishAutoSelectActivity(
          'Pre-connect auto-select',
          message: 'Pre-connect auto-select failed: $error',
          isError: true,
        );
      }
      state = state.copyWith(
        busy: false,
        connectionStage: ConnectionStage.failed,
        clearRuntimeSession: true,
        clearConnectedAt: true,
        clearLastBestServerCheckAt: true,
        errorMessage: _connectionError(error, state.runtimeMode),
        logs: _runtimeService.logs,
      );
    }
  }

  Future<void> shutdownForAppExit() async {
    _cancelPendingConnectOperation();
    _stopAutoSelectionMonitoring();
    try {
      await _runtimeService.stopForAppExit();
    } on Object {
      return;
    }
  }

  Future<void> disconnect() async {
    _cancelPendingConnectOperation();
    final previousSession = state.runtimeSession;
    final previousProfile = state.activeProfile;
    _stopAutoSelectionMonitoring();

    state = state.copyWith(
      busy: true,
      connectionStage: ConnectionStage.stopping,
      clearErrorMessage: true,
      clearStatusMessage: true,
    );

    try {
      await _runtimeService.stop();
      state = state.copyWith(
        busy: false,
        connectionStage: ConnectionStage.disconnected,
        clearRuntimeSession: true,
        clearConnectedAt: true,
        delayByTag: const {},
        activeServerTag: previousProfile?.startupServerTag,
        autoSelectResults: const [],
        clearAutoSelectActivity: true,
        clearLastBestServerCheckAt: true,
        statusMessage: _disconnectedStatus(previousSession),
        logs: _runtimeService.logs,
      );
      if (previousSession != null) {
        _autoSelectorService.resetProfileState(previousSession.profileId);
      }
    } on Object catch (error) {
      state = state.copyWith(
        busy: false,
        connectionStage: ConnectionStage.failed,
        errorMessage: error.toString(),
        logs: _runtimeService.logs,
      );
    }
  }

  Future<void> selectServer(String serverTag) async {
    final profile = state.activeProfile;
    if (profile == null) {
      return;
    }

    state = state.copyWith(
      busy: true,
      clearErrorMessage: true,
      clearStatusMessage: true,
    );
    try {
      if (isAutoSelectServerTag(serverTag)) {
        final storage = await _repository.updateSelectedServer(
          profile.id,
          autoSelectServerTag,
        );
        final updatedProfile = storage.activeProfile;

        state = state.copyWith(
          busy: false,
          storage: storage,
          selectedServerTag: updatedProfile?.selectedServerTag,
          activeServerTag: state.connectionStage == ConnectionStage.connected
              ? (state.activeServerTag ?? updatedProfile?.startupServerTag)
              : updatedProfile?.startupServerTag,
          autoSelectResults: const [],
          clearAutoSelectActivity: true,
          clearLastBestServerCheckAt: true,
          statusMessage: !state.autoSelectSettings.enabled
              ? 'Auto server saved, but automatic selection is disabled in settings.'
              : state.connectionStage == ConnectionStage.connected
              ? 'Auto server selected. The next automatic pass will choose and maintain a server.'
              : 'Auto server saved. It will choose and maintain a server on the next connection.',
          logs: _runtimeService.logs,
        );

        if (state.connectionStage == ConnectionStage.connected &&
            state.runtimeSession != null &&
            state.autoSelectSettings.enabled) {
          _startAutoSelectionMonitoring();
        }
        return;
      }

      _stopAutoSelectionMonitoring();
      StoredProfilesState storage = await _repository.updateSelectedServer(
        profile.id,
        serverTag,
      );
      if (state.connectionStage == ConnectionStage.connected &&
          state.runtimeSession != null) {
        final session = state.runtimeSession!;
        final client = ClashApiClient.fromSession(session);
        await client.selectProxy(
          selectorTag: session.manualSelectorTag,
          serverTag: serverTag,
        );
        final snapshot = await client.fetchSnapshot(
          selectorTag: session.manualSelectorTag,
        );
        final delays = await _safeLoadDelays(client, session);
        if (snapshot.selectedTag != null) {
          storage = await _repository.updateSelectedServer(
            profile.id,
            snapshot.selectedTag!,
          );
        }
        state = state.copyWith(
          busy: false,
          storage: storage,
          selectedServerTag:
              storage.activeProfile?.selectedServerTag ?? serverTag,
          activeServerTag: snapshot.selectedTag ?? serverTag,
          delayByTag: delays,
          autoSelectResults: const [],
          clearAutoSelectActivity: true,
          clearLastBestServerCheckAt: true,
          statusMessage: 'Server selection updated.',
          logs: _runtimeService.logs,
        );
        return;
      }

      state = state.copyWith(
        busy: false,
        storage: storage,
        selectedServerTag:
            storage.activeProfile?.selectedServerTag ?? serverTag,
        activeServerTag: storage.activeProfile?.startupServerTag,
        autoSelectResults: const [],
        clearAutoSelectActivity: true,
        clearLastBestServerCheckAt: true,
        statusMessage: 'Server saved. It will be used on the next connection.',
      );
    } on Object catch (error) {
      state = state.copyWith(
        busy: false,
        errorMessage: error.toString(),
        logs: _runtimeService.logs,
      );
    }
  }

  Future<void> refreshDelays() async {
    final session = state.runtimeSession;
    if (session == null) {
      return;
    }

    state = state.copyWith(
      refreshingDelays: true,
      clearErrorMessage: true,
      clearStatusMessage: true,
    );
    try {
      final client = ClashApiClient.fromSession(session);
      final snapshot = await client.fetchSnapshot(
        selectorTag: session.manualSelectorTag,
      );
      final delays = await _safeLoadDelays(client, session);
      state = state.copyWith(
        refreshingDelays: false,
        delayByTag: delays,
        activeServerTag: snapshot.selectedTag ?? state.activeServerTag,
        statusMessage: 'Delays refreshed through sing-box URLTest.',
        logs: _runtimeService.logs,
      );
    } on Object catch (error) {
      state = state.copyWith(
        refreshingDelays: false,
        errorMessage: error.toString(),
        logs: _runtimeService.logs,
      );
    }
  }

  Future<void> runAutoSelect() async {
    final session = state.runtimeSession;
    final profile = state.activeProfile;
    if (session == null || profile == null) {
      state = state.copyWith(
        errorMessage:
            'Connect first. The auto-selector needs a running local sing-box runtime.',
        clearStatusMessage: true,
      );
      return;
    }

    if (!profile.prefersAutoSelection) {
      state = state.copyWith(
        statusMessage: 'Select Auto-select best in the server list first.',
        clearErrorMessage: true,
      );
      return;
    }

    if (!state.autoSelectSettings.enabled) {
      state = state.copyWith(
        statusMessage:
            'Automatic selection is disabled in settings. Enable it before running an auto-select pass.',
        clearErrorMessage: true,
      );
      return;
    }

    if (_autoSelectionInFlight) {
      state = state.copyWith(
        statusMessage:
            'Auto-selector check is already running in the background.',
        clearErrorMessage: true,
      );
      return;
    }

    state = state.copyWith(
      busy: true,
      clearErrorMessage: true,
      clearStatusMessage: true,
      clearAutoSelectActivity: true,
    );

    try {
      final eligibleServers = await _resolveEligibleAutoSelectServers(profile);
      if (eligibleServers.isEmpty) {
        state = state.copyWith(
          busy: false,
          statusMessage:
              'All servers for the active profile are excluded from automatic selection.',
        );
        return;
      }

      _startAutoSelectActivity(
        'Manual auto-select',
        message: 'Refreshing URLTest delays and probing servers.',
      );

      final outcome = await _autoSelectorService.selectBestServer(
        session: session,
        servers: eligibleServers,
        domainProbeUrl: state.autoSelectSettings.domainProbeUrl,
        ipProbeUrl: state.autoSelectSettings.ipProbeUrl,
        checkIp: state.autoSelectSettings.checkIp,
        onProgress: (event) {
          _reportAutoSelectProgress('Manual auto-select', event);
        },
      );
      final updatedStorage = await _repository.updateAutoSelectedServer(
        profile.id,
        outcome.selectedServerTag,
      );
      final recentSuccessfulAutoConnect = state.recentSuccessfulAutoConnect;
      state = state.copyWith(
        busy: false,
        storage: updatedStorage,
        selectedServerTag:
            updatedStorage.activeProfile?.selectedServerTag ??
            profile.selectedServerTag,
        activeServerTag: outcome.selectedServerTag,
        delayByTag: {...state.delayByTag, ...outcome.delayByTag},
        recentSuccessfulAutoConnect: recentSuccessfulAutoConnect,
        autoSelectResults: outcome.probes,
        statusMessage: outcome.summary,
        logs: _runtimeService.logs,
      );
      _finishAutoSelectActivity('Manual auto-select');
      if (outcome.hasReachableCandidate) {
        state = state.copyWith(
          recentSuccessfulAutoConnect:
              await _updateRecentAutoSelectCachesAfterBestServerCompleted(
                profileId: profile.id,
                serverTag: outcome.selectedServerTag,
                currentRecentSuccessfulAutoConnect: recentSuccessfulAutoConnect,
              ),
        );
      }
    } on Object catch (error) {
      if (state.autoSelectActivity.active &&
          state.autoSelectActivity.label == 'Manual auto-select') {
        _finishAutoSelectActivity(
          'Manual auto-select',
          message: 'Manual auto-select failed: $error',
          isError: true,
        );
      }
      state = state.copyWith(
        busy: false,
        errorMessage: error.toString(),
        logs: _runtimeService.logs,
      );
    }
  }

  Future<void> reconnect() async {
    final profile = state.activeProfile;
    if (profile == null) {
      state = state.copyWith(
        errorMessage: 'Add a subscription before reconnecting.',
        clearStatusMessage: true,
      );
      return;
    }

    if (state.connectionStage == ConnectionStage.connected ||
        state.connectionStage == ConnectionStage.starting) {
      await disconnect();
    }
    await connect();
  }

  Future<void> resetRecentSuccessfulAutoConnect() async {
    final profile = state.activeProfile;
    if (profile == null || state.busy) {
      return;
    }
    if (!state.hasRecentSuccessfulAutoConnectForActiveProfile) {
      return;
    }

    final isConnected = state.connectionStage == ConnectionStage.connected;
    state = state.copyWith(
      busy: true,
      clearErrorMessage: true,
      clearStatusMessage: true,
    );

    try {
      await _clearRecentSuccessfulAutoConnect();
      state = state.copyWith(
        busy: false,
        activeServerTag: isConnected
            ? state.activeServerTag
            : profile.startupServerTag,
        autoSelectResults: isConnected ? state.autoSelectResults : const [],
        clearAutoSelectActivity: !isConnected,
        statusMessage: isConnected
            ? 'Auto-select quick reconnect cache cleared. The next reconnect will run pre-connect probing again.'
            : 'Auto-select quick reconnect cache cleared. The next connection will run pre-connect probing again.',
        logs: _runtimeService.logs,
      );
    } on Object catch (error) {
      state = state.copyWith(
        busy: false,
        errorMessage: error.toString(),
        logs: _runtimeService.logs,
      );
    }
  }

  Future<void> setRuntimeMode(RuntimeMode mode) async {
    final normalizedMode = _normalizeRuntimeMode(mode);
    if (state.busy ||
        state.refreshingDelays ||
        state.runtimeMode == normalizedMode) {
      return;
    }

    final shouldReconnect = state.connectionStage == ConnectionStage.connected;
    state = state.copyWith(
      runtimeMode: normalizedMode,
      clearErrorMessage: true,
      statusMessage: shouldReconnect
          ? 'Reconnecting with ${normalizedMode.label.toLowerCase()} mode.'
          : _modeSelectionStatus(normalizedMode),
    );

    if (shouldReconnect) {
      await reconnect();
    }
  }

  Future<void> refreshProfile(String profileId) async {
    final profile = _profileById(profileId);
    if (profile == null) {
      state = state.copyWith(
        errorMessage: 'Select a profile first.',
        clearStatusMessage: true,
      );
      return;
    }

    final isActiveProfile = state.activeProfile?.id == profile.id;
    final shouldReconnect =
        isActiveProfile && state.connectionStage == ConnectionStage.connected;
    final shouldDisconnect =
        isActiveProfile &&
        (state.connectionStage == ConnectionStage.connected ||
            state.connectionStage == ConnectionStage.starting);
    if (isActiveProfile) {
      _stopAutoSelectionMonitoring();
    }
    if (shouldDisconnect) {
      await disconnect();
    }

    state = state.copyWith(
      busy: true,
      clearErrorMessage: true,
      clearStatusMessage: true,
    );
    try {
      final storage = await _repository.refreshRemoteSubscription(profile.id);
      final activeProfile = storage.activeProfile;
      state = state.copyWith(
        busy: false,
        storage: storage,
        selectedServerTag: isActiveProfile
            ? activeProfile?.selectedServerTag
            : state.selectedServerTag,
        activeServerTag: isActiveProfile
            ? activeProfile?.startupServerTag
            : state.activeServerTag,
        clearConnectedAt: isActiveProfile,
        delayByTag: isActiveProfile ? const {} : state.delayByTag,
        autoSelectResults: isActiveProfile ? const [] : state.autoSelectResults,
        clearAutoSelectActivity: isActiveProfile,
        clearLastBestServerCheckAt: isActiveProfile,
        statusMessage: shouldReconnect
            ? 'Profile updated. Reconnecting with the refreshed config.'
            : isActiveProfile
            ? 'Profile updated from the remote subscription.'
            : 'Subscription updated from the remote source.',
      );
      if (shouldReconnect) {
        await connect();
      }
    } on Object catch (error) {
      state = state.copyWith(busy: false, errorMessage: error.toString());
    }
  }

  Future<void> refreshActiveProfile() async {
    final profile = state.activeProfile;
    if (profile == null) {
      state = state.copyWith(
        errorMessage: 'Select a profile first.',
        clearStatusMessage: true,
      );
      return;
    }

    await refreshProfile(profile.id);
  }

  Future<void> removeProfile(String profileId) async {
    final profile = _profileById(profileId);
    if (profile == null) {
      state = state.copyWith(
        errorMessage: 'Select a profile first.',
        clearStatusMessage: true,
      );
      return;
    }

    final shouldDisconnect =
        state.activeProfile?.id == profile.id &&
        (state.connectionStage == ConnectionStage.connected ||
            state.connectionStage == ConnectionStage.starting);
    final isActiveProfile = state.activeProfile?.id == profile.id;
    if (isActiveProfile) {
      _stopAutoSelectionMonitoring();
    }
    if (shouldDisconnect) {
      await disconnect();
    }

    state = state.copyWith(
      busy: true,
      clearErrorMessage: true,
      clearStatusMessage: true,
      clearAutoSelectActivity: true,
    );
    try {
      final storage = await _repository.removeProfile(profile.id);
      final activeProfile = storage.activeProfile;
      state = state.copyWith(
        busy: false,
        storage: storage,
        selectedServerTag: isActiveProfile
            ? activeProfile?.selectedServerTag
            : state.selectedServerTag,
        clearSelectedServerTag:
            isActiveProfile && activeProfile?.selectedServerTag == null,
        activeServerTag: isActiveProfile
            ? activeProfile?.startupServerTag
            : state.activeServerTag,
        clearActiveServerTag:
            isActiveProfile && activeProfile?.startupServerTag == null,
        clearConnectedAt: isActiveProfile,
        delayByTag: isActiveProfile ? const {} : state.delayByTag,
        autoSelectResults: isActiveProfile ? const [] : state.autoSelectResults,
        clearAutoSelectActivity: isActiveProfile,
        clearLastBestServerCheckAt: isActiveProfile,
        statusMessage: isActiveProfile
            ? 'Profile removed from local storage.'
            : 'Subscription removed from local storage.',
      );
      _autoSelectorService.resetProfileState(profile.id);
    } on Object catch (error) {
      state = state.copyWith(busy: false, errorMessage: error.toString());
    }
  }

  Future<void> removeActiveProfile() async {
    final profile = state.activeProfile;
    if (profile == null) {
      state = state.copyWith(
        errorMessage: 'Select a profile first.',
        clearStatusMessage: true,
      );
      return;
    }

    await removeProfile(profile.id);
  }

  Future<void> _clearRecentSuccessfulAutoConnect({
    bool ignoreErrors = false,
  }) async {
    if (!ignoreErrors) {
      await _autoSelectSettingsRepository.clearRecentSuccessfulAutoConnect();
      state = state.copyWith(clearRecentSuccessfulAutoConnect: true);
      return;
    }

    try {
      await _autoSelectSettingsRepository.clearRecentSuccessfulAutoConnect();
      state = state.copyWith(clearRecentSuccessfulAutoConnect: true);
    } on Object {
      return;
    }
  }

  Future<RecentSuccessfulAutoConnect?> _updateRecentAutoSelectCaches({
    required String profileId,
    required String serverTag,
  }) async {
    await _autoSelectSettingsRepository.setRecentAutoSelectedServer(
      profileId: profileId,
      serverTag: serverTag,
    );
    final autoSelectState = await _autoSelectSettingsRepository
        .setRecentSuccessfulAutoConnect(
          profileId: profileId,
          serverTag: serverTag,
        );
    return autoSelectState.recentSuccessfulAutoConnect;
  }

  Future<RecentSuccessfulAutoConnect?>
  _updateRecentAutoSelectCachesAfterBestServerCompleted({
    required String profileId,
    required String serverTag,
    required RecentSuccessfulAutoConnect? currentRecentSuccessfulAutoConnect,
  }) async {
    await _autoSelectSettingsRepository.setRecentAutoSelectedServer(
      profileId: profileId,
      serverTag: serverTag,
    );
    if (!_shouldRefreshRecentSuccessfulAutoConnect(
      profileId: profileId,
      serverTag: serverTag,
      currentRecentSuccessfulAutoConnect: currentRecentSuccessfulAutoConnect,
    )) {
      return currentRecentSuccessfulAutoConnect;
    }

    final autoSelectState = await _autoSelectSettingsRepository
        .setRecentSuccessfulAutoConnect(
          profileId: profileId,
          serverTag: serverTag,
        );
    return autoSelectState.recentSuccessfulAutoConnect;
  }

  bool _shouldRefreshRecentSuccessfulAutoConnect({
    required String profileId,
    required String serverTag,
    required RecentSuccessfulAutoConnect? currentRecentSuccessfulAutoConnect,
  }) {
    if (currentRecentSuccessfulAutoConnect == null ||
        !currentRecentSuccessfulAutoConnect.matchesProfile(profileId)) {
      return true;
    }

    return currentRecentSuccessfulAutoConnect.tag != serverTag;
  }

  void _startAutoSelectionMonitoring() {
    _scheduleNextAutoSelectionPass();
  }

  void _stopAutoSelectionMonitoring() {
    _autoSelectionTimer?.cancel();
    _autoSelectionTimer = null;
  }

  void _scheduleNextAutoSelectionPass({Duration? delay}) {
    if (!_shouldMonitorAutoSelection()) {
      _stopAutoSelectionMonitoring();
      return;
    }

    _autoSelectionTimer?.cancel();
    _autoSelectionTimer = _createTimer(
      delay ?? _currentAutoSelectionInterval,
      () {
        _autoSelectionTimer = null;
        unawaited(
          _runAutomaticAutoSelect(
            allowSwitchDuringCooldown: false,
            surfaceFailures: false,
            rescheduleOnCompletion: true,
          ),
        );
      },
    );
  }

  void _runAutomaticAutoSelectNow({
    required bool allowSwitchDuringCooldown,
    required bool surfaceFailures,
  }) {
    _stopAutoSelectionMonitoring();
    unawaited(
      _runAutomaticAutoSelect(
        allowSwitchDuringCooldown: allowSwitchDuringCooldown,
        surfaceFailures: surfaceFailures,
        rescheduleOnCompletion: true,
      ),
    );
  }

  bool _shouldMonitorAutoSelection() {
    final profile = state.activeProfile;
    if (state.connectionStage != ConnectionStage.connected ||
        state.runtimeSession == null ||
        profile == null ||
        !profile.prefersAutoSelection ||
        !state.autoSelectSettings.enabled) {
      return false;
    }

    return _eligibleAutoSelectServers(profile).isNotEmpty;
  }

  Future<void> _runAutomaticAutoSelect({
    required bool allowSwitchDuringCooldown,
    required bool surfaceFailures,
    bool rescheduleOnCompletion = false,
  }) async {
    if (_autoSelectionInFlight ||
        state.busy ||
        state.refreshingDelays ||
        state.connectionStage != ConnectionStage.connected) {
      if (rescheduleOnCompletion && !_autoSelectionInFlight) {
        _scheduleNextAutoSelectionPass();
      }
      return;
    }

    final session = state.runtimeSession;
    final profile = state.activeProfile;
    if (session == null || profile == null) {
      if (rescheduleOnCompletion) {
        _scheduleNextAutoSelectionPass();
      }
      return;
    }
    if (!profile.prefersAutoSelection || !state.autoSelectSettings.enabled) {
      _stopAutoSelectionMonitoring();
      return;
    }

    final eligibleServers = await _resolveEligibleAutoSelectServers(profile);
    if (eligibleServers.isEmpty) {
      _stopAutoSelectionMonitoring();
      if (surfaceFailures) {
        state = state.copyWith(
          statusMessage:
              'All servers for the active profile are excluded from automatic selection.',
        );
      }
      return;
    }

    _startAutoSelectActivity('Automatic maintenance');
    _autoSelectionInFlight = true;
    try {
      final outcome = await _autoSelectorService.maintainBestServer(
        session: session,
        servers: eligibleServers,
        domainProbeUrl: state.autoSelectSettings.domainProbeUrl,
        ipProbeUrl: state.autoSelectSettings.ipProbeUrl,
        checkIp: state.autoSelectSettings.checkIp,
        allowSwitchDuringCooldown: allowSwitchDuringCooldown,
        onProgress: (event) {
          _reportAutoSelectProgress(
            'Automatic maintenance',
            event,
            session: session,
            profileId: profile.id,
          );
        },
      );
      if (!_isCurrentConnectedSession(session, profile.id)) {
        return;
      }

      var storage = state.storage;
      if (profile.resolvedAutoSelectedServerTag != outcome.selectedServerTag) {
        storage = await _repository.updateAutoSelectedServer(
          profile.id,
          outcome.selectedServerTag,
        );
        if (!_isCurrentConnectedSession(session, profile.id)) {
          return;
        }
      }

      final recentSuccessfulAutoConnect = state.recentSuccessfulAutoConnect;
      if (!_isCurrentConnectedSession(session, profile.id)) {
        return;
      }

      final baseState = state.copyWith(
        storage: storage,
        selectedServerTag:
            storage.activeProfile?.selectedServerTag ??
            profile.selectedServerTag,
        activeServerTag: outcome.selectedServerTag,
        delayByTag: {...state.delayByTag, ...outcome.delayByTag},
        recentSuccessfulAutoConnect: recentSuccessfulAutoConnect,
        autoSelectResults: outcome.probes,
        logs: _runtimeService.logs,
      );

      if (outcome.didSwitch || !outcome.hasReachableCandidate) {
        state = baseState.copyWith(
          statusMessage: outcome.summary,
          clearErrorMessage: true,
        );
      } else {
        state = baseState;
      }
      _finishAutoSelectActivity(
        'Automatic maintenance',
        session: session,
        profileId: profile.id,
      );
      if (!outcome.hasReachableCandidate ||
          !_isCurrentConnectedSession(session, profile.id)) {
        return;
      }

      state = state.copyWith(
        recentSuccessfulAutoConnect:
            await _updateRecentAutoSelectCachesAfterBestServerCompleted(
              profileId: profile.id,
              serverTag: outcome.selectedServerTag,
              currentRecentSuccessfulAutoConnect: recentSuccessfulAutoConnect,
            ),
      );
    } on Object catch (error) {
      final isCurrentSession = _isCurrentConnectedSession(session, profile.id);
      if (isCurrentSession) {
        _finishAutoSelectActivity(
          'Automatic maintenance',
          message: 'Automatic maintenance failed: $error',
          session: session,
          profileId: profile.id,
          isError: true,
        );
      }

      if (!surfaceFailures || !isCurrentSession) {
        return;
      }

      state = state.copyWith(
        statusMessage:
            'Connected, but the automatic auto-selector pass failed: $error',
        logs: _runtimeService.logs,
      );
    } finally {
      _autoSelectionInFlight = false;
      if (rescheduleOnCompletion) {
        _scheduleNextAutoSelectionPass();
      }
    }
  }

  static Timer _defaultCreateTimer(
    Duration duration,
    void Function() callback,
  ) {
    return Timer(duration, callback);
  }

  static Future<void> _defaultPause(Duration duration) {
    return Future<void>.delayed(duration);
  }

  bool _isCurrentConnectedSession(RuntimeSession session, String profileId) {
    return state.connectionStage == ConnectionStage.connected &&
        identical(state.runtimeSession, session) &&
        state.activeProfile?.id == profileId;
  }

  int _beginConnectOperation() {
    _connectOperationId += 1;
    return _connectOperationId;
  }

  void _cancelPendingConnectOperation() {
    _connectOperationId += 1;
  }

  bool _isConnectOperationCurrent(int connectOperationId) {
    return _connectOperationId == connectOperationId;
  }

  String? _connectOperationAbortReason(int connectOperationId) {
    if (_isConnectOperationCurrent(connectOperationId)) {
      return null;
    }
    return 'Connection attempt was cancelled.';
  }

  void _throwIfConnectOperationCancelled(int connectOperationId) {
    final reason = _connectOperationAbortReason(connectOperationId);
    if (reason != null) {
      throw _CancelledConnectOperation(reason);
    }
  }

  Future<void> _waitForSystemProxyStartupSettle({
    required RuntimeMode mode,
  }) async {
    if (!mode.usesSystemProxy ||
        _systemProxyStartupSettleDelay <= Duration.zero) {
      return;
    }

    // The local mixed inbound is ready before Windows finishes propagating the
    // updated system proxy settings to other apps, so gate "connected" until
    // that handoff has had a short chance to settle.
    await _pause(_systemProxyStartupSettleDelay);
  }

  Future<Map<String, int>> _safeLoadDelays(
    ClashApiClient client,
    RuntimeSession session,
  ) async {
    final snapshot = await client.fetchSnapshot(
      selectorTag: session.manualSelectorTag,
    );
    try {
      final measured = await client.measureGroupDelay(
        groupTag: session.autoGroupTag,
        testUrl: resolveAutoSelectUrlTestUrl(
          state.autoSelectSettings.domainProbeUrl,
          rotationKey: '${session.profileId}::refresh::urltest',
        ),
      );
      return {...snapshot.delayByTag, ...measured};
    } on Object {
      return snapshot.delayByTag;
    }
  }

  Future<
    ({
      StoredProfilesState storage,
      String? activeServerTag,
      Map<String, int> delayByTag,
      List<AutoSelectProbeResult> probes,
      String? statusMessage,
      String? failureMessage,
    })
  >
  _verifyPostConnectInternetAccess({
    required ProxyProfile profile,
    required RuntimeSession session,
    required StoredProfilesState storage,
    required String? activeServerTag,
    required Map<String, int> delayByTag,
    String? templateConfig,
    bool forceCurrentServerOnly = false,
  }) async {
    final eligibleServers = await _resolveEligibleAutoSelectServers(
      profile,
      templateConfig: templateConfig,
    );
    final shouldUseAutoVerification =
        !forceCurrentServerOnly &&
        profile.prefersAutoSelection &&
        state.autoSelectSettings.enabled &&
        eligibleServers.isNotEmpty;

    if (shouldUseAutoVerification) {
      _startAutoSelectActivity('Automatic maintenance');
      try {
        final outcome = await _autoSelectorService.maintainBestServer(
          session: session,
          servers: eligibleServers,
          domainProbeUrl: state.autoSelectSettings.domainProbeUrl,
          ipProbeUrl: state.autoSelectSettings.ipProbeUrl,
          checkIp: state.autoSelectSettings.checkIp,
          allowSwitchDuringCooldown: true,
          onProgress: (event) {
            _reportAutoSelectProgress('Automatic maintenance', event);
          },
        );
        final selectedProbe = _probeByServerTag(
          outcome.probes,
          outcome.selectedServerTag,
        );
        final nextDelayByTag = {...delayByTag, ...outcome.delayByTag};
        if (selectedProbe == null || !selectedProbe.fullyHealthy) {
          final failureMessage = selectedProbe == null
              ? _internetAccessVerificationErrorMessage()
              : _fullInternetAccessFailureMessage(
                  serverName: _serverNameForTag(
                    profile.servers,
                    outcome.selectedServerTag,
                  ),
                );
          _finishAutoSelectActivity(
            'Automatic maintenance',
            message: failureMessage,
            isError: true,
          );
          return (
            storage: storage,
            activeServerTag: outcome.selectedServerTag,
            delayByTag: nextDelayByTag,
            probes: outcome.probes,
            statusMessage: null,
            failureMessage: failureMessage,
          );
        }

        var nextStorage = storage;
        if (profile.resolvedAutoSelectedServerTag !=
            outcome.selectedServerTag) {
          nextStorage = await _repository.updateAutoSelectedServer(
            profile.id,
            outcome.selectedServerTag,
          );
        }
        _finishAutoSelectActivity('Automatic maintenance');
        return (
          storage: nextStorage,
          activeServerTag: outcome.selectedServerTag,
          delayByTag: nextDelayByTag,
          probes: outcome.probes,
          statusMessage: outcome.didSwitch
              ? '${outcome.summary} ${_connectedStatus(session)}'
              : null,
          failureMessage: null,
        );
      } on Object {
        final failureMessage = _internetAccessVerificationErrorMessage();
        _finishAutoSelectActivity(
          'Automatic maintenance',
          message: failureMessage,
          isError: true,
        );
        return (
          storage: storage,
          activeServerTag: activeServerTag,
          delayByTag: delayByTag,
          probes: const <AutoSelectProbeResult>[],
          statusMessage: null,
          failureMessage: failureMessage,
        );
      }
    }

    final currentServer = _findServerByTag(profile.servers, activeServerTag);
    if (currentServer == null) {
      return (
        storage: storage,
        activeServerTag: activeServerTag,
        delayByTag: delayByTag,
        probes: const <AutoSelectProbeResult>[],
        statusMessage: null,
        failureMessage: _internetAccessVerificationErrorMessage(),
      );
    }

    try {
      final probe = await _autoSelectorService.verifyCurrentServer(
        session: session,
        server: currentServer,
        domainProbeUrl: state.autoSelectSettings.domainProbeUrl,
        ipProbeUrl: state.autoSelectSettings.ipProbeUrl,
        checkIp: state.autoSelectSettings.checkIp,
        urlTestDelay: delayByTag[currentServer.tag],
      );
      return (
        storage: storage,
        activeServerTag: currentServer.tag,
        delayByTag: {
          ...delayByTag,
          if (probe.urlTestDelay != null)
            currentServer.tag: probe.urlTestDelay!,
        },
        probes: const <AutoSelectProbeResult>[],
        statusMessage: null,
        failureMessage: probe.fullyHealthy
            ? null
            : _fullInternetAccessFailureMessage(
                serverName: _serverNameForTag(
                  profile.servers,
                  currentServer.tag,
                ),
              ),
      );
    } on Object catch (_) {
      return (
        storage: storage,
        activeServerTag: currentServer.tag,
        delayByTag: delayByTag,
        probes: const <AutoSelectProbeResult>[],
        statusMessage: null,
        failureMessage: _internetAccessVerificationErrorMessage(),
      );
    }
  }

  List<ServerEntry> _eligibleAutoSelectServers(
    ProxyProfile profile, {
    AutoSelectSettings? settings,
  }) {
    final effectiveSettings = settings ?? state.autoSelectSettings;
    return _deduplicateExactServers([
      for (final server in profile.servers)
        if (!effectiveSettings.isExcluded(profile.id, server.tag)) server,
    ]);
  }

  Future<List<ServerEntry>> _resolveEligibleAutoSelectServers(
    ProxyProfile profile, {
    AutoSelectSettings? settings,
    String? templateConfig,
  }) async {
    final eligibleServers = _eligibleAutoSelectServers(
      profile,
      settings: settings,
    );
    if (eligibleServers.length <= 1 ||
        eligibleServers.every(
          (server) => (server.configFingerprint ?? '').isNotEmpty,
        )) {
      return eligibleServers;
    }

    try {
      final resolvedTemplateConfig =
          templateConfig ?? await _loadEffectiveTemplateConfig(profile);
      final candidates = extractAutoSelectConfigCandidates(
        resolvedTemplateConfig,
      );
      if (candidates.isEmpty) {
        return eligibleServers;
      }

      final fingerprintByTag = {
        for (final candidate in candidates)
          candidate.tag: candidate.configFingerprint,
      };
      return _deduplicateExactServers([
        for (final server in eligibleServers)
          if ((server.configFingerprint ?? '').isNotEmpty)
            server
          else
            ServerEntry(
              tag: server.tag,
              displayName: server.displayName,
              type: server.type,
              host: server.host,
              port: server.port,
              configFingerprint: fingerprintByTag[server.tag],
            ),
      ]);
    } on Object {
      return eligibleServers;
    }
  }

  Future<String> _loadEffectiveTemplateConfig(ProxyProfile profile) async {
    final templateConfig = await _repository.loadTemplateConfig(profile);
    return _applyConnectionTuningSettings(templateConfig);
  }

  String _applyConnectionTuningSettings(String templateConfig) {
    return applyConnectionTuningSettingsToTemplateConfig(
      templateConfig: templateConfig,
      settings: state.connectionTuningSettings,
    );
  }

  List<ServerEntry> _deduplicateExactServers(List<ServerEntry> servers) {
    final deduplicated = <ServerEntry>[];
    final seenFingerprints = <String>{};

    for (final server in servers) {
      final fingerprint = server.configFingerprint;
      if (fingerprint == null || fingerprint.isEmpty) {
        deduplicated.add(server);
        continue;
      }
      if (!seenFingerprints.add(fingerprint)) {
        continue;
      }
      deduplicated.add(server);
    }

    return deduplicated;
  }

  ServerEntry? _findServerByTag(List<ServerEntry> servers, String? serverTag) {
    if (serverTag == null || serverTag.isEmpty) {
      return null;
    }

    for (final server in servers) {
      if (server.tag == serverTag) {
        return server;
      }
    }
    return null;
  }

  String _serverNameForTag(List<ServerEntry> servers, String serverTag) {
    final server = _findServerByTag(servers, serverTag);
    final raw = server?.displayName ?? serverTag;
    return normalizeServerDisplayText(raw);
  }

  AutoSelectProbeResult? _probeByServerTag(
    List<AutoSelectProbeResult> probes,
    String? serverTag,
  ) {
    if (serverTag == null || serverTag.isEmpty) {
      return null;
    }

    for (final probe in probes) {
      if (probe.serverTag == serverTag) {
        return probe;
      }
    }
    return null;
  }

  String _fullInternetAccessFailureMessage({required String serverName}) {
    final normalizedName = serverName.trim();
    if (normalizedName.isEmpty) {
      return 'Подключение не удалось: сервер недоступен.';
    }
    return 'Подключение не удалось: $normalizedName недоступен.';
  }

  String _internetAccessVerificationErrorMessage() {
    return 'Подключение не удалось: сервер недоступен.';
  }

  String _connectedStatus(RuntimeSession session) {
    return switch (_effectiveRuntimeMode(session.mode)) {
      RuntimeMode.mixed =>
        'Connected in local proxy mode on ${session.mixedProxyAddress}. Apps must use the proxy explicitly or switch to System proxy/TUN.',
      RuntimeMode.systemProxy =>
        'Connected in system proxy mode. Windows traffic that honors the system proxy now uses ${session.mixedProxyAddress}.',
      RuntimeMode.tun =>
        'Connected in TUN mode. System traffic is routed through sing-box, and the mixed inbound remains available on ${session.mixedProxyAddress}.',
    };
  }

  String _disconnectedStatus(RuntimeSession? previousSession) {
    return switch (previousSession == null
        ? null
        : _effectiveRuntimeMode(previousSession.mode)) {
      RuntimeMode.systemProxy =>
        'Local sing-box runtime stopped and the previous Windows system proxy settings were restored.',
      RuntimeMode.tun ||
      RuntimeMode.mixed ||
      null => 'Local sing-box runtime stopped.',
    };
  }

  String _modeSelectionStatus(RuntimeMode mode) {
    return switch (_effectiveRuntimeMode(mode)) {
      RuntimeMode.mixed =>
        'Local proxy mode selected. Connect and point apps at the mixed inbound manually.',
      RuntimeMode.systemProxy =>
        'System proxy mode selected. Connect to route browsers that honor the Windows system proxy.',
      RuntimeMode.tun =>
        'TUN mode selected. Connect to capture system traffic through sing-box.',
    };
  }

  String _connectionError(Object error, RuntimeMode mode) {
    if (error is ProcessException && _isElevationRequired(error)) {
      return 'Запуск TUN требует прав администратора. Подтвердите UAC-запрос или перезапустите Gorion от имени администратора.';
    }

    final message = error.toString();
    return switch (_effectiveRuntimeMode(mode)) {
      RuntimeMode.tun =>
        '$message TUN mode may require elevated privileges on this platform.',
      RuntimeMode.systemProxy when !Platform.isWindows =>
        '$message System proxy mode is currently implemented only on Windows.',
      _ => message,
    };
  }

  Future<bool> _maybeRelaunchForTunElevation() async {
    if (!Platform.isWindows || state.runtimeMode != RuntimeMode.tun) {
      return false;
    }
    if (_runtimeService.launchesWithEmbeddedPrivilegeBroker) {
      return false;
    }

    bool isElevated;
    try {
      isElevated = await _elevationService.isElevated();
    } on Object {
      return false;
    }

    if (isElevated) {
      return false;
    }

    final confirmed = await _elevationPromptService.confirmRelaunch(
      action: PendingElevatedLaunchAction.connectTun,
    );
    if (!confirmed) {
      state = state.copyWith(
        statusMessage: 'Запуск TUN отменён.',
        clearErrorMessage: true,
      );
      return true;
    }

    try {
      await _elevationService.relaunchAsAdministrator(
        action: PendingElevatedLaunchAction.connectTun,
      );
      state = state.copyWith(
        statusMessage:
            'Запрошены права администратора. После подтверждения UAC Gorion перезапустится и продолжит запуск TUN.',
        clearErrorMessage: true,
      );
    } on ElevationRequestCancelledException {
      state = state.copyWith(
        errorMessage: 'Запрос прав администратора был отменён. TUN не запущен.',
        clearStatusMessage: true,
      );
    } on Object catch (error) {
      state = state.copyWith(
        errorMessage:
            'Не удалось запросить права администратора для TUN: $error',
        clearStatusMessage: true,
      );
    }

    return true;
  }

  bool _isElevationRequired(ProcessException error) {
    if (error.errorCode == 740) {
      return true;
    }

    final details = '${error.message} ${error.toString()}'.toLowerCase();
    return details.contains('requested operation requires elevation') ||
        details.contains('requires elevation') ||
        details.contains('require elevation') ||
        details.contains('требует повышения');
  }
}
