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
    this.delayByTag = const {},
    this.selectedServerTag,
    this.activeServerTag,
    this.autoSelectResults = const [],
    this.autoSelectActivity = const AutoSelectActivityState(),
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
  final Map<String, int> delayByTag;
  final String? selectedServerTag;
  final String? activeServerTag;
  final List<AutoSelectProbeResult> autoSelectResults;
  final AutoSelectActivityState autoSelectActivity;
  final String? statusMessage;
  final String? errorMessage;
  final List<String> logs;

  ProxyProfile? get activeProfile => storage.activeProfile;

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
    Map<String, int>? delayByTag,
    String? selectedServerTag,
    bool clearSelectedServerTag = false,
    String? activeServerTag,
    bool clearActiveServerTag = false,
    List<AutoSelectProbeResult>? autoSelectResults,
    AutoSelectActivityState? autoSelectActivity,
    bool clearAutoSelectActivity = false,
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
      delayByTag: delayByTag ?? this.delayByTag,
      selectedServerTag: clearSelectedServerTag
          ? null
          : selectedServerTag ?? this.selectedServerTag,
      activeServerTag: clearActiveServerTag
          ? null
          : activeServerTag ?? this.activeServerTag,
      autoSelectResults: autoSelectResults ?? this.autoSelectResults,
      autoSelectActivity: clearAutoSelectActivity
          ? const AutoSelectActivityState()
          : autoSelectActivity ?? this.autoSelectActivity,
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

  DashboardController({
    required ProfileRepository repository,
    required SingboxRuntimeService runtimeService,
    required AutoSelectSettingsRepository autoSelectSettingsRepository,
    required AutoSelectPreconnectService autoSelectPreconnectService,
    required AutoSelectorService autoSelectorService,
    Duration autoSelectionInterval = automaticAutoSelectInterval,
    Timer Function(Duration duration, void Function() callback)? createTimer,
    DashboardState? initialState,
    bool loadOnInit = true,
  }) : _repository = repository,
       _runtimeService = runtimeService,
       _autoSelectSettingsRepository = autoSelectSettingsRepository,
       _autoSelectPreconnectService = autoSelectPreconnectService,
       _autoSelectorService = autoSelectorService,
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

    if (message != null && message.isNotEmpty) {
      _appendAutoSelectActivity(
        label,
        message,
        active: false,
        completedSteps: completedSteps,
        totalSteps: totalSteps,
        isError: isError,
      );
      return;
    }

    state = state.copyWith(
      autoSelectActivity: state.autoSelectActivity.copyWith(active: false),
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
        autoSelectResults: const [],
        clearAutoSelectActivity: true,
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
    );

    try {
      final selectedMode = state.runtimeMode;
      final templateConfig = await _repository.loadTemplateConfig(profile);
      final autoSelectSettings = state.autoSelectSettings;
      PreparedAutoConnectSelection? preparedAutoSelection;
      var startupServerTag = profile.startupServerTag;
      if (profile.prefersAutoSelection && autoSelectSettings.enabled) {
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
      final client = ClashApiClient.fromSession(session);
      final snapshot = await client.fetchSnapshot(
        selectorTag: session.manualSelectorTag,
      );
      final delays = await _safeLoadDelays(client, session);
      final connectedTag = snapshot.selectedTag ?? startupServerTag;
      final persistedStorage = snapshot.selectedTag == null
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

      if (profile.prefersAutoSelection &&
          autoSelectSettings.enabled &&
          connectedTag != null) {
        await _autoSelectSettingsRepository.setRecentAutoSelectedServer(
          profileId: profile.id,
          serverTag: connectedTag,
        );
        await _autoSelectSettingsRepository.setRecentSuccessfulAutoConnect(
          profileId: profile.id,
          serverTag: connectedTag,
        );
      }

      final statusMessage = preparedAutoSelection == null
          ? _connectedStatus(session)
          : '${preparedAutoSelection.summary} ${_connectedStatus(session)}';

      state = state.copyWith(
        busy: false,
        storage: persistedStorage,
        connectionStage: ConnectionStage.connected,
        runtimeSession: session,
        delayByTag: {
          ...preparedAutoSelection?.delayByTag ?? const <String, int>{},
          ...delays,
        },
        selectedServerTag:
            persistedStorage.activeProfile?.selectedServerTag ??
            profile.selectedServerTag,
        activeServerTag: snapshot.selectedTag ?? startupServerTag,
        autoSelectResults: preparedAutoSelection?.probes ?? const [],
        statusMessage: statusMessage,
        logs: _runtimeService.logs,
      );
      if (profile.prefersAutoSelection && autoSelectSettings.enabled) {
        if (preparedAutoSelection == null ||
            preparedAutoSelection.requiresImmediatePostConnectCheck) {
          _runAutomaticAutoSelectNow(
            allowSwitchDuringCooldown: true,
            surfaceFailures: true,
          );
        } else {
          _startAutoSelectionMonitoring();
        }
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
        delayByTag: const {},
        activeServerTag: previousProfile?.startupServerTag,
        autoSelectResults: const [],
        clearAutoSelectActivity: true,
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
          activeServerTag:
              state.activeServerTag ?? updatedProfile?.startupServerTag,
          autoSelectResults: const [],
          clearAutoSelectActivity: true,
          statusMessage: !state.autoSelectSettings.enabled
              ? 'Auto server saved, but automatic selection is disabled in settings.'
              : state.connectionStage == ConnectionStage.connected
              ? 'Auto server selected. Running an immediate auto-selection pass.'
              : 'Auto server saved. It will choose and maintain a server on the next connection.',
          logs: _runtimeService.logs,
        );

        if (state.connectionStage == ConnectionStage.connected &&
            state.runtimeSession != null &&
            state.autoSelectSettings.enabled) {
          _runAutomaticAutoSelectNow(
            allowSwitchDuringCooldown: true,
            surfaceFailures: true,
          );
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
      state = state.copyWith(
        busy: false,
        storage: updatedStorage,
        selectedServerTag:
            updatedStorage.activeProfile?.selectedServerTag ??
            profile.selectedServerTag,
        activeServerTag: outcome.selectedServerTag,
        delayByTag: {...state.delayByTag, ...outcome.delayByTag},
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
        delayByTag: isActiveProfile ? const {} : state.delayByTag,
        autoSelectResults: isActiveProfile ? const [] : state.autoSelectResults,
        clearAutoSelectActivity: isActiveProfile,
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
        delayByTag: isActiveProfile ? const {} : state.delayByTag,
        autoSelectResults: isActiveProfile ? const [] : state.autoSelectResults,
        clearAutoSelectActivity: isActiveProfile,
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

      final baseState = state.copyWith(
        storage: storage,
        selectedServerTag:
            storage.activeProfile?.selectedServerTag ??
            profile.selectedServerTag,
        activeServerTag: outcome.selectedServerTag,
        delayByTag: {...state.delayByTag, ...outcome.delayByTag},
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
