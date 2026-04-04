import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gorion_clean/core/logging/gorion_console_log.dart';
import 'package:gorion_clean/features/auto_select/data/auto_select_preconnect_service.dart';
import 'package:gorion_clean/features/auto_select/data/auto_select_settings_repository.dart';
import 'package:gorion_clean/features/auto_select/model/auto_select_state.dart';
import 'package:gorion_clean/features/auto_select/data/auto_selector_service.dart';
import 'package:gorion_clean/features/profiles/data/profile_repository.dart';
import 'package:gorion_clean/features/profiles/model/profile_models.dart';
import 'package:gorion_clean/features/runtime/data/clash_api_client.dart';
import 'package:gorion_clean/features/runtime/model/runtime_mode.dart';
import 'package:gorion_clean/features/runtime/data/singbox_runtime_service.dart';
import 'package:gorion_clean/features/runtime/model/runtime_models.dart';
import 'package:gorion_clean/utils/server_display_text.dart';

const automaticAutoSelectInterval = Duration(seconds: 60);

final profileRepositoryProvider = Provider<ProfileRepository>(
  (ref) => ProfileRepository(),
);

final singboxRuntimeServiceProvider = Provider<SingboxRuntimeService>((ref) {
  final service = SingboxRuntimeService();
  ref.onDispose(service.dispose);
  return service;
});

final autoSelectSettingsRepositoryProvider =
    Provider<AutoSelectSettingsRepository>(
      (ref) => AutoSelectSettingsRepository(),
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

final dashboardControllerProvider =
    StateNotifierProvider<DashboardController, DashboardState>((ref) {
      return DashboardController(
        repository: ref.read(profileRepositoryProvider),
        runtimeService: ref.read(singboxRuntimeServiceProvider),
        autoSelectSettingsRepository: ref.read(
          autoSelectSettingsRepositoryProvider,
        ),
        autoSelectPreconnectService: ref.read(
          autoSelectPreconnectServiceProvider,
        ),
        autoSelectorService: ref.read(autoSelectorServiceProvider),
      );
    });

class DashboardState {
  const DashboardState({
    this.bootstrapping = true,
    this.busy = false,
    this.refreshingDelays = false,
    this.runtimeMode = RuntimeMode.mixed,
    this.autoSelectSettings = const AutoSelectSettings(),
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
      runtimeMode: runtimeMode ?? this.runtimeMode,
      autoSelectSettings: autoSelectSettings ?? this.autoSelectSettings,
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
    required AutoSelectPreconnectService autoSelectPreconnectService,
    required AutoSelectorService autoSelectorService,
    ClashApiClientFactory? clashApiClientFactory,
    Duration autoSelectionInterval = automaticAutoSelectInterval,
    Timer Function(Duration duration, void Function() callback)? createTimer,
    DashboardState? initialState,
    bool loadOnInit = true,
  }) : _repository = repository,
       _runtimeService = runtimeService,
       _autoSelectSettingsRepository = autoSelectSettingsRepository,
       _autoSelectPreconnectService = autoSelectPreconnectService,
       _autoSelectorService = autoSelectorService,
       _createClashApiClient =
           clashApiClientFactory ?? ClashApiClient.fromSession,
       _autoSelectionInterval = autoSelectionInterval,
       _createTimer = createTimer ?? _defaultCreateTimer,
       super(
         initialState ?? DashboardState(runtimeMode: _defaultRuntimeMode()),
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
  final AutoSelectPreconnectService _autoSelectPreconnectService;
  final AutoSelectorService _autoSelectorService;
  final ClashApiClientFactory _createClashApiClient;
  final Duration _autoSelectionInterval;
  final Timer Function(Duration duration, void Function() callback)
  _createTimer;
  Timer? _autoSelectionTimer;
  bool _autoSelectionInFlight = false;

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
      final storage = await storageFuture;
      final autoSelectState = await autoSelectStateFuture;
      state = state.copyWith(
        bootstrapping: false,
        autoSelectSettings: autoSelectState.settings,
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
    final profile = state.activeProfile;
    if (profile == null) {
      state = state.copyWith(
        errorMessage: 'Add a subscription before connecting.',
        clearStatusMessage: true,
      );
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
      final templateConfig = await _repository.loadTemplateConfig(profile);
      final autoSelectSettings = state.autoSelectSettings;
      PreparedAutoConnectSelection? preparedAutoSelection;
      var startupServerTag = profile.startupServerTag;
      if (profile.prefersAutoSelection && autoSelectSettings.enabled) {
        preparedAutoSelection = await _autoSelectPreconnectService
            .recentSuccessfulSelection(
              profile: profile,
              templateConfig: templateConfig,
            );
        if (preparedAutoSelection == null) {
          _startAutoSelectActivity(
            'Pre-connect auto-select',
            message:
                'Loading saved auto-select state and preparing candidate probes.',
          );
          preparedAutoSelection = await _autoSelectPreconnectService.prepare(
            profile: profile,
            templateConfig: templateConfig,
            onProgress: (event) {
              _reportAutoSelectProgress('Pre-connect auto-select', event);
            },
          );
          _finishAutoSelectActivity('Pre-connect auto-select');
        }
        startupServerTag =
            preparedAutoSelection?.selectedServerTag ?? startupServerTag;
      }
      final session = await _runtimeService.start(
        profileId: profile.id,
        templateConfig: templateConfig,
        urlTestUrl: autoSelectSettings.domainProbeUrl,
        mode: selectedMode,
        selectedServerTag: startupServerTag,
      );
      final client = _createClashApiClient(session);
      final snapshot = await client.fetchSnapshot(
        selectorTag: session.manualSelectorTag,
      );
      final delays = await _safeLoadDelays(client, session);
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
      final shouldVerifyPostConnectInternetAccess =
          preparedAutoSelection == null ||
          preparedAutoSelection.requiresImmediatePostConnectCheck;

      final verification = shouldVerifyPostConnectInternetAccess
          ? await _verifyPostConnectInternetAccess(
              profile: profile,
              session: session,
              storage: persistedStorage,
              activeServerTag: effectiveActiveServerTag,
              delayByTag: effectiveDelayByTag,
            )
          : (
              storage: persistedStorage,
              activeServerTag: effectiveActiveServerTag,
              delayByTag: effectiveDelayByTag,
              probes: effectiveProbes,
              statusMessage: null,
              failureMessage: null,
            );
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
        final recentSuccessfulAutoConnect = await _updateRecentAutoSelectCaches(
          profileId: profile.id,
          serverTag: effectiveActiveServerTag,
        );
        state = state.copyWith(
          recentSuccessfulAutoConnect: recentSuccessfulAutoConnect,
        );
      }

      final statusMessage = preparedAutoSelection == null
          ? _connectedStatus(session)
          : '${preparedAutoSelection.summary} ${_connectedStatus(session)}';
      final effectiveStatusMessage =
          verification.statusMessage ?? statusMessage;

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

  Future<void> disconnect() async {
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
      final eligibleServers = _eligibleAutoSelectServers(profile);
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
        onProgress: (event) {
          _reportAutoSelectProgress('Manual auto-select', event);
        },
      );
      final updatedStorage = await _repository.updateAutoSelectedServer(
        profile.id,
        outcome.selectedServerTag,
      );
      final recentSuccessfulAutoConnect = outcome.hasReachableCandidate
          ? await _updateRecentAutoSelectCaches(
              profileId: profile.id,
              serverTag: outcome.selectedServerTag,
            )
          : state.recentSuccessfulAutoConnect;
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
    if (state.busy || state.refreshingDelays || state.runtimeMode == mode) {
      return;
    }

    final shouldReconnect = state.connectionStage == ConnectionStage.connected;
    state = state.copyWith(
      runtimeMode: mode,
      clearErrorMessage: true,
      statusMessage: shouldReconnect
          ? 'Reconnecting with ${mode.label.toLowerCase()} mode.'
          : _modeSelectionStatus(mode),
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
    } on Object {}
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
    _autoSelectionTimer = _createTimer(delay ?? _autoSelectionInterval, () {
      _autoSelectionTimer = null;
      unawaited(
        _runAutomaticAutoSelect(
          allowSwitchDuringCooldown: false,
          surfaceFailures: false,
          rescheduleOnCompletion: true,
        ),
      );
    });
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

    final eligibleServers = _eligibleAutoSelectServers(profile);
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

      final recentSuccessfulAutoConnect = outcome.hasReachableCandidate
          ? await _updateRecentAutoSelectCaches(
              profileId: profile.id,
              serverTag: outcome.selectedServerTag,
            )
          : state.recentSuccessfulAutoConnect;
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

  bool _isCurrentConnectedSession(RuntimeSession session, String profileId) {
    return state.connectionStage == ConnectionStage.connected &&
        identical(state.runtimeSession, session) &&
        state.activeProfile?.id == profileId;
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
        testUrl: state.autoSelectSettings.domainProbeUrl,
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
  }) async {
    final eligibleServers = _eligibleAutoSelectServers(profile);
    final shouldUseAutoVerification =
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
    return [
      for (final server in profile.servers)
        if (!effectiveSettings.isExcluded(profile.id, server.tag)) server,
    ];
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
    return switch (session.mode) {
      RuntimeMode.mixed =>
        'Connected in local proxy mode on ${session.mixedProxyAddress}. Apps must use the proxy explicitly or switch to System proxy/TUN.',
      RuntimeMode.systemProxy =>
        'Connected in system proxy mode. Windows traffic that honors the system proxy now uses ${session.mixedProxyAddress}.',
      RuntimeMode.tun =>
        'Connected in TUN mode. System traffic is routed through sing-box, and the mixed inbound remains available on ${session.mixedProxyAddress}.',
    };
  }

  String _disconnectedStatus(RuntimeSession? previousSession) {
    return switch (previousSession?.mode) {
      RuntimeMode.systemProxy =>
        'Local sing-box runtime stopped and the previous Windows system proxy settings were restored.',
      RuntimeMode.tun ||
      RuntimeMode.mixed ||
      null => 'Local sing-box runtime stopped.',
    };
  }

  String _modeSelectionStatus(RuntimeMode mode) {
    return switch (mode) {
      RuntimeMode.mixed =>
        'Local proxy mode selected. Connect and point apps at the mixed inbound manually.',
      RuntimeMode.systemProxy =>
        'System proxy mode selected. Connect to route browsers that honor the Windows system proxy.',
      RuntimeMode.tun =>
        'TUN mode selected. Connect to capture system traffic through sing-box.',
    };
  }

  String _connectionError(Object error, RuntimeMode mode) {
    final message = error.toString();
    return switch (mode) {
      RuntimeMode.tun =>
        '$message TUN mode may require elevated privileges on this platform.',
      RuntimeMode.systemProxy when !Platform.isWindows =>
        '$message System proxy mode is currently implemented only on Windows.',
      _ => message,
    };
  }
}
