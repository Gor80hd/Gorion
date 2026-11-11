part of 'dashboard_controller.dart';

/// Connection lifecycle: connect, disconnect, server and mode switching.
mixin _DashboardConnection on _DashboardCore, _DashboardAutoSelect {
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

    final gate = await _tunPrivilegeGate.ensure(state.runtimeMode);
    if (gate.errorMessage case final message?) {
      state = state.copyWith(errorMessage: message, clearStatusMessage: true);
    } else if (gate.statusMessage case final message?) {
      state = state.copyWith(statusMessage: message, clearErrorMessage: true);
    }
    if (!gate.proceed) {
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
              label: _preConnectAutoSelectLabel,
              message: preparedAutoSelection!.summary,
            ),
          );
        } else {
          _startAutoSelectActivity(
            _preConnectAutoSelectLabel,
            message:
                'Loading saved auto-select state and preparing candidate probes.',
          );
          preparedAutoSelection = await _autoSelectPreconnectService.prepare(
            profile: profile,
            templateConfig: templateConfig,
            abortReason: () => _connectOperationAbortReason(connectOperationId),
            onProgress: (event) {
              _reportAutoSelectProgress(_preConnectAutoSelectLabel, event);
            },
          );
          _throwIfConnectOperationCancelled(connectOperationId);
          _finishAutoSelectActivity(_preConnectAutoSelectLabel);
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
        onExit: _handleRuntimeExit,
      );
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
          ? connectedStatus(session)
          : '${preparedAutoSelection.summary} ${connectedStatus(session)}';
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
      // A failure after the core started (snapshot, persistence,
      // verification) must still bring the core down — the UI is about to
      // show "failed", so nothing may keep routing traffic behind its back.
      await _runtimeService.stop();
      if (state.autoSelectActivity.active &&
          state.autoSelectActivity.label == _preConnectAutoSelectLabel) {
        _finishAutoSelectActivity(
          _preConnectAutoSelectLabel,
          message: 'Автовыбор перед подключением завершился с ошибкой: $error',
          isError: true,
        );
      }
      state = state.copyWith(
        busy: false,
        connectionStage: ConnectionStage.failed,
        clearRuntimeSession: true,
        clearConnectedAt: true,
        clearLastBestServerCheckAt: true,
        errorMessage: connectionErrorMessage(error, state.runtimeMode),
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
        statusMessage: disconnectedStatus(previousSession),
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

  void _handleRuntimeExit(RuntimeSession session, int exitCode) {
    if (!identical(state.runtimeSession, session)) {
      return;
    }

    _stopAutoSelectionMonitoring();
    _autoSelectorService.resetProfileState(session.profileId);
    final exitedCleanly = exitCode == 0;
    state = state.copyWith(
      busy: false,
      connectionStage: exitedCleanly
          ? ConnectionStage.disconnected
          : ConnectionStage.failed,
      clearRuntimeSession: true,
      clearConnectedAt: true,
      delayByTag: const {},
      activeServerTag: state.activeProfile?.startupServerTag,
      autoSelectResults: const [],
      clearAutoSelectActivity: true,
      clearLastBestServerCheckAt: true,
      statusMessage: exitedCleanly ? disconnectedStatus(session) : null,
      clearStatusMessage: !exitedCleanly,
      errorMessage: exitedCleanly
          ? null
          : 'Локальный runtime sing-box неожиданно завершился с кодом $exitCode.',
      clearErrorMessage: exitedCleanly,
      logs: _runtimeService.logs,
    );
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
      if (state.connectionStage == ConnectionStage.connected &&
          state.runtimeSession != null) {
        final session = state.runtimeSession!;
        final client = _createClashApiClient(session);
        await client.selectProxy(
          selectorTag: session.manualSelectorTag,
          serverTag: serverTag,
        );
        final snapshot = await client.fetchSnapshot(
          selectorTag: session.manualSelectorTag,
        );
        final delays = await _safeLoadDelays(client, session);
        final persistedServerTag = snapshot.selectedTag ?? serverTag;
        final storage = await _repository.updateSelectedServer(
          profile.id,
          persistedServerTag,
        );
        state = state.copyWith(
          busy: false,
          storage: storage,
          selectedServerTag:
              storage.activeProfile?.selectedServerTag ?? persistedServerTag,
          activeServerTag: persistedServerTag,
          delayByTag: delays,
          autoSelectResults: const [],
          clearAutoSelectActivity: true,
          clearLastBestServerCheckAt: true,
          statusMessage: 'Server selection updated.',
          logs: _runtimeService.logs,
        );
        return;
      }

      final storage = await _repository.updateSelectedServer(
        profile.id,
        serverTag,
      );
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

  Future<void> refreshDelays({bool silent = false}) async {
    final session = state.runtimeSession;
    if (session == null) {
      return;
    }

    state = state.copyWith(
      refreshingDelays: true,
      clearErrorMessage: !silent,
      clearStatusMessage: !silent,
    );
    try {
      final client = _createClashApiClient(session);
      final snapshot = await client.fetchSnapshot(
        selectorTag: session.manualSelectorTag,
      );
      final delays = await _safeLoadDelays(client, session);
      state = state.copyWith(
        refreshingDelays: false,
        delayByTag: delays,
        activeServerTag: snapshot.selectedTag ?? state.activeServerTag,
        statusMessage: silent
            ? null
            : 'Delays refreshed through sing-box URLTest.',
        logs: _runtimeService.logs,
      );
    } on Object catch (error) {
      state = state.copyWith(
        refreshingDelays: false,
        errorMessage: silent ? null : error.toString(),
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
    final normalizedMode = normalizeRuntimeMode(mode);
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
          : modeSelectionStatus(normalizedMode),
    );

    if (shouldReconnect) {
      await reconnect();
    }
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
      _startAutoSelectActivity(_automaticMaintenanceLabel);
      try {
        final outcome = await _autoSelectorService.maintainBestServer(
          session: session,
          servers: eligibleServers,
          domainProbeUrl: state.autoSelectSettings.domainProbeUrl,
          ipProbeUrl: state.autoSelectSettings.ipProbeUrl,
          checkIp: state.autoSelectSettings.checkIp,
          allowSwitchDuringCooldown: true,
          onProgress: (event) {
            _reportAutoSelectProgress(_automaticMaintenanceLabel, event);
          },
        );
        final selectedProbe = probeByServerTag(
          outcome.probes,
          outcome.selectedServerTag,
        );
        final nextDelayByTag = {...delayByTag, ...outcome.delayByTag};
        if (selectedProbe == null || !selectedProbe.fullyHealthy) {
          final failureMessage = selectedProbe == null
              ? internetAccessVerificationErrorMessage()
              : fullInternetAccessFailureMessage(
                  serverName: serverNameForTag(
                    profile.servers,
                    outcome.selectedServerTag,
                  ),
                );
          _finishAutoSelectActivity(
            _automaticMaintenanceLabel,
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
        _finishAutoSelectActivity(_automaticMaintenanceLabel);
        return (
          storage: nextStorage,
          activeServerTag: outcome.selectedServerTag,
          delayByTag: nextDelayByTag,
          probes: outcome.probes,
          statusMessage: outcome.didSwitch
              ? '${outcome.summary} ${connectedStatus(session)}'
              : null,
          failureMessage: null,
        );
      } on Object {
        final failureMessage = internetAccessVerificationErrorMessage();
        _finishAutoSelectActivity(
          _automaticMaintenanceLabel,
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

    final currentServer = findServerByTag(profile.servers, activeServerTag);
    if (currentServer == null) {
      return (
        storage: storage,
        activeServerTag: activeServerTag,
        delayByTag: delayByTag,
        probes: const <AutoSelectProbeResult>[],
        statusMessage: null,
        failureMessage: internetAccessVerificationErrorMessage(),
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
            : fullInternetAccessFailureMessage(
                serverName: serverNameForTag(
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
        failureMessage: internetAccessVerificationErrorMessage(),
      );
    }
  }
}
