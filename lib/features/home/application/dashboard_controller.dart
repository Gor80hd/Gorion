import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gorion_clean/features/auto_select/data/auto_selector_service.dart';
import 'package:gorion_clean/features/profiles/data/profile_repository.dart';
import 'package:gorion_clean/features/profiles/model/profile_models.dart';
import 'package:gorion_clean/features/runtime/data/clash_api_client.dart';
import 'package:gorion_clean/features/runtime/model/runtime_mode.dart';
import 'package:gorion_clean/features/runtime/data/singbox_runtime_service.dart';
import 'package:gorion_clean/features/runtime/model/runtime_models.dart';

const defaultConnectivityProbeUrl = 'https://www.gstatic.com/generate_204';

final profileRepositoryProvider = Provider<ProfileRepository>(
  (ref) => ProfileRepository(),
);

final singboxRuntimeServiceProvider = Provider<SingboxRuntimeService>((ref) {
  final service = SingboxRuntimeService();
  ref.onDispose(service.dispose);
  return service;
});

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
        autoSelectorService: ref.read(autoSelectorServiceProvider),
      );
    });

class DashboardState {
  const DashboardState({
    this.bootstrapping = true,
    this.busy = false,
    this.refreshingDelays = false,
    this.runtimeMode = RuntimeMode.mixed,
    this.storage = const StoredProfilesState(),
    this.connectionStage = ConnectionStage.disconnected,
    this.runtimeSession,
    this.delayByTag = const {},
    this.selectedServerTag,
    this.autoSelectResults = const [],
    this.statusMessage,
    this.errorMessage,
    this.logs = const [],
  });

  final bool bootstrapping;
  final bool busy;
  final bool refreshingDelays;
  final RuntimeMode runtimeMode;
  final StoredProfilesState storage;
  final ConnectionStage connectionStage;
  final RuntimeSession? runtimeSession;
  final Map<String, int> delayByTag;
  final String? selectedServerTag;
  final List<AutoSelectProbeResult> autoSelectResults;
  final String? statusMessage;
  final String? errorMessage;
  final List<String> logs;

  ProxyProfile? get activeProfile => storage.activeProfile;

  DashboardState copyWith({
    bool? bootstrapping,
    bool? busy,
    bool? refreshingDelays,
    RuntimeMode? runtimeMode,
    StoredProfilesState? storage,
    ConnectionStage? connectionStage,
    RuntimeSession? runtimeSession,
    bool clearRuntimeSession = false,
    Map<String, int>? delayByTag,
    String? selectedServerTag,
    bool clearSelectedServerTag = false,
    List<AutoSelectProbeResult>? autoSelectResults,
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
      storage: storage ?? this.storage,
      connectionStage: connectionStage ?? this.connectionStage,
      runtimeSession: clearRuntimeSession
          ? null
          : runtimeSession ?? this.runtimeSession,
      delayByTag: delayByTag ?? this.delayByTag,
      selectedServerTag: clearSelectedServerTag
          ? null
          : selectedServerTag ?? this.selectedServerTag,
      autoSelectResults: autoSelectResults ?? this.autoSelectResults,
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
  DashboardController({
    required ProfileRepository repository,
    required SingboxRuntimeService runtimeService,
    required AutoSelectorService autoSelectorService,
  }) : _repository = repository,
       _runtimeService = runtimeService,
       _autoSelectorService = autoSelectorService,
       super(DashboardState(runtimeMode: _defaultRuntimeMode())) {
    unawaited(load());
  }

  final ProfileRepository _repository;
  final SingboxRuntimeService _runtimeService;
  final AutoSelectorService _autoSelectorService;

  Future<void> load() async {
    state = state.copyWith(
      bootstrapping: true,
      clearErrorMessage: true,
      clearStatusMessage: true,
    );
    try {
      final storage = await _repository.loadState();
      state = state.copyWith(
        bootstrapping: false,
        storage: storage,
        selectedServerTag: storage.activeProfile?.selectedServerTag,
        autoSelectResults: const [],
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
    );
    try {
      final storage = await _repository.addRemoteSubscription(trimmed);
      state = state.copyWith(
        busy: false,
        storage: storage,
        selectedServerTag: storage.activeProfile?.selectedServerTag,
        autoSelectResults: const [],
        statusMessage: 'Subscription saved. Servers are ready for connection.',
      );
    } on Object catch (error) {
      state = state.copyWith(busy: false, errorMessage: error.toString());
    }
  }

  Future<void> chooseProfile(String profileId) async {
    if (state.connectionStage == ConnectionStage.connected ||
        state.connectionStage == ConnectionStage.starting) {
      await disconnect();
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
        delayByTag: const {},
        autoSelectResults: const [],
      );
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

    state = state.copyWith(
      busy: true,
      connectionStage: ConnectionStage.starting,
      clearErrorMessage: true,
      clearStatusMessage: true,
    );

    try {
      final selectedMode = state.runtimeMode;
      final templateConfig = await _repository.loadTemplateConfig(profile);
      final session = await _runtimeService.start(
        profileId: profile.id,
        templateConfig: templateConfig,
        urlTestUrl: defaultConnectivityProbeUrl,
        mode: selectedMode,
        selectedServerTag: profile.selectedServerTag,
      );
      final client = ClashApiClient.fromSession(session);
      final snapshot = await client.fetchSnapshot(
        selectorTag: session.manualSelectorTag,
      );
      final delays = await _safeLoadDelays(client, session);
      final persistedStorage = snapshot.selectedTag == null
          ? state.storage
          : await _repository.updateSelectedServer(
              profile.id,
              snapshot.selectedTag!,
            );

      state = state.copyWith(
        busy: false,
        storage: persistedStorage,
        connectionStage: ConnectionStage.connected,
        runtimeSession: session,
        delayByTag: delays,
        selectedServerTag: snapshot.selectedTag ?? profile.selectedServerTag,
        autoSelectResults: const [],
        statusMessage: _connectedStatus(session),
        logs: _runtimeService.logs,
      );
    } on Object catch (error) {
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
        autoSelectResults: const [],
        statusMessage: _disconnectedStatus(previousSession),
        logs: _runtimeService.logs,
      );
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
          selectedServerTag: snapshot.selectedTag ?? serverTag,
          delayByTag: delays,
          autoSelectResults: const [],
          statusMessage: 'Server selection updated.',
          logs: _runtimeService.logs,
        );
        return;
      }

      state = state.copyWith(
        busy: false,
        storage: storage,
        selectedServerTag: serverTag,
        autoSelectResults: const [],
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
        selectedServerTag: snapshot.selectedTag ?? state.selectedServerTag,
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

    state = state.copyWith(
      busy: true,
      clearErrorMessage: true,
      clearStatusMessage: true,
    );

    try {
      final outcome = await _autoSelectorService.selectBestServer(
        session: session,
        servers: profile.servers,
        domainProbeUrl: defaultConnectivityProbeUrl,
      );
      final updatedStorage = await _repository.updateSelectedServer(
        profile.id,
        outcome.selectedServerTag,
      );
      state = state.copyWith(
        busy: false,
        storage: updatedStorage,
        selectedServerTag: outcome.selectedServerTag,
        delayByTag: {...state.delayByTag, ...outcome.delayByTag},
        autoSelectResults: outcome.probes,
        statusMessage: outcome.summary,
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

  Future<void> refreshActiveProfile() async {
    final profile = state.activeProfile;
    if (profile == null) {
      state = state.copyWith(
        errorMessage: 'Select a profile first.',
        clearStatusMessage: true,
      );
      return;
    }

    final shouldReconnect = state.connectionStage == ConnectionStage.connected;
    if (shouldReconnect) {
      await disconnect();
    }

    state = state.copyWith(
      busy: true,
      clearErrorMessage: true,
      clearStatusMessage: true,
    );
    try {
      final storage = await _repository.refreshRemoteSubscription(profile.id);
      state = state.copyWith(
        busy: false,
        storage: storage,
        selectedServerTag: storage.activeProfile?.selectedServerTag,
        delayByTag: const {},
        autoSelectResults: const [],
        statusMessage: shouldReconnect
            ? 'Profile updated. Reconnecting with the refreshed config.'
            : 'Profile updated from the remote subscription.',
      );
      if (shouldReconnect) {
        await connect();
      }
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

    final shouldDisconnect =
        state.connectionStage == ConnectionStage.connected ||
        state.connectionStage == ConnectionStage.starting;
    if (shouldDisconnect) {
      await disconnect();
    }

    state = state.copyWith(
      busy: true,
      clearErrorMessage: true,
      clearStatusMessage: true,
    );
    try {
      final storage = await _repository.removeProfile(profile.id);
      state = state.copyWith(
        busy: false,
        storage: storage,
        selectedServerTag: storage.activeProfile?.selectedServerTag,
        delayByTag: const {},
        autoSelectResults: const [],
        statusMessage: 'Profile removed from local storage.',
      );
    } on Object catch (error) {
      state = state.copyWith(busy: false, errorMessage: error.toString());
    }
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
        testUrl: defaultConnectivityProbeUrl,
      );
      return {...snapshot.delayByTag, ...measured};
    } on Object {
      return snapshot.delayByTag;
    }
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
