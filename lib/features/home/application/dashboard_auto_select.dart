part of 'dashboard_controller.dart';

/// Auto-select: settings, the activity trace, manual runs and the
/// background maintenance loop.
mixin _DashboardAutoSelect on _DashboardCore {
  /// Persists auto-select settings behind the busy flag. Returns the stored
  /// settings, or null when saving failed (the error is then in the state).
  Future<AutoSelectSettings?> _saveAutoSelectSettings(
    AutoSelectSettings next, {
    required String statusMessage,
    bool clearLastBestServerCheckAt = false,
  }) async {
    state = state.copyWith(
      busy: true,
      clearErrorMessage: true,
      clearStatusMessage: true,
    );
    try {
      final stored = await _autoSelectSettingsRepository.saveSettings(next);
      state = state.copyWith(
        busy: false,
        autoSelectSettings: stored.settings,
        recentSuccessfulAutoConnect: stored.recentSuccessfulAutoConnect,
        clearLastBestServerCheckAt: clearLastBestServerCheckAt,
        statusMessage: statusMessage,
      );
      return stored.settings;
    } on Object catch (error) {
      state = state.copyWith(busy: false, errorMessage: error.toString());
      return null;
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

    final saved = await _saveAutoSelectSettings(
      currentSettings.copyWith(enabled: enabled),
      clearLastBestServerCheckAt: !enabled,
      statusMessage: enabled
          ? 'Автоматический выбор сервера включён.'
          : 'Автоматический выбор сервера выключен.',
    );
    if (saved == null) {
      return;
    }
    if (!enabled) {
      _stopAutoSelectionMonitoring();
    } else if (shouldKickMonitor) {
      _runAutomaticAutoSelectNow(
        allowSwitchDuringCooldown: true,
        surfaceFailures: true,
      );
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
    final saved = await _saveAutoSelectSettings(
      currentSettings.copyWith(bestServerCheckIntervalMinutes: clampedMinutes),
      statusMessage:
          'Интервал проверки лучшего сервера: '
          '${describeAutoSelectBestServerCheckInterval(clampedMinutes)}.',
    );
    if (saved != null && shouldRescheduleMonitor && !_autoSelectionInFlight) {
      _scheduleNextAutoSelectionPass();
    }
  }

  Future<void> setLiveServerPingEnabled(bool enabled) async {
    final currentSettings = state.autoSelectSettings;
    if (state.busy || currentSettings.liveServerPingEnabled == enabled) {
      return;
    }
    await _saveAutoSelectSettings(
      currentSettings.copyWith(liveServerPingEnabled: enabled),
      statusMessage: enabled
          ? 'Live ping серверов включён.'
          : 'Live ping серверов выключен.',
    );
  }

  Future<void> setLiveServerPingIntervalSeconds(int seconds) async {
    final clampedSeconds = clampLiveServerPingIntervalSeconds(seconds);
    final currentSettings = state.autoSelectSettings;
    if (state.busy ||
        currentSettings.liveServerPingIntervalSeconds == clampedSeconds) {
      return;
    }
    await _saveAutoSelectSettings(
      currentSettings.copyWith(liveServerPingIntervalSeconds: clampedSeconds),
      statusMessage:
          'Интервал Live ping серверов: '
          '${formatLiveServerPingInterval(clampedSeconds)}.',
    );
  }

  Future<void> setLiveServerPingOnStartupEnabled(bool enabled) async {
    final currentSettings = state.autoSelectSettings;
    if (state.busy ||
        currentSettings.liveServerPingOnStartupEnabled == enabled) {
      return;
    }
    await _saveAutoSelectSettings(
      currentSettings.copyWith(liveServerPingOnStartupEnabled: enabled),
      statusMessage: enabled
          ? 'Live ping при запуске включён.'
          : 'Live ping при запуске выключен.',
    );
  }

  Future<void> setAutoSelectServerExcluded(
    String serverTag,
    bool excluded, {
    String? profileId,
  }) async {
    final resolvedProfileId = profileId ?? state.activeProfile?.id;
    final profile = resolvedProfileId == null
        ? null
        : _profileById(resolvedProfileId);
    if (profile == null || state.busy || isAutoSelectServerTag(serverTag)) {
      return;
    }

    final currentSettings = state.autoSelectSettings;
    final alreadyExcluded = currentSettings.isExcluded(
      resolvedProfileId!,
      serverTag,
    );
    if (alreadyExcluded == excluded) {
      return;
    }
    _candidates.invalidate(profile.id);

    final shouldKickMonitor =
        currentSettings.enabled &&
        state.connectionStage == ConnectionStage.connected &&
        state.runtimeSession != null &&
        profile.id == state.activeProfile?.id &&
        profile.prefersAutoSelection;

    state = state.copyWith(
      busy: true,
      clearErrorMessage: true,
      clearStatusMessage: true,
    );
    try {
      final stored = await _autoSelectSettingsRepository.updateExcludedServer(
        profileId: resolvedProfileId,
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
            ? 'Сервер $serverTag исключён из автоматического выбора.'
            : 'Сервер $serverTag снова участвует в автоматическом выборе.',
      );

      if (shouldKickMonitor) {
        if (eligibleServers.isEmpty) {
          _stopAutoSelectionMonitoring();
          state = state.copyWith(
            statusMessage:
                'Для активного профиля не осталось серверов для автоматического выбора.',
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
        _manualAutoSelectLabel,
        message: 'Обновляем URLTest и проверяем доступные серверы.',
      );

      final outcome = await _autoSelectorService.selectBestServer(
        session: session,
        servers: eligibleServers,
        domainProbeUrl: state.autoSelectSettings.domainProbeUrl,
        ipProbeUrl: state.autoSelectSettings.ipProbeUrl,
        checkIp: state.autoSelectSettings.checkIp,
        onProgress: (event) {
          _reportAutoSelectProgress(_manualAutoSelectLabel, event);
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
      _finishAutoSelectActivity(_manualAutoSelectLabel);
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
          state.autoSelectActivity.label == _manualAutoSelectLabel) {
        _finishAutoSelectActivity(
          _manualAutoSelectLabel,
          message: 'Ручной автовыбор завершился с ошибкой: $error',
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

    _startAutoSelectActivity(_automaticMaintenanceLabel);
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
            _automaticMaintenanceLabel,
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
        _automaticMaintenanceLabel,
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
          _automaticMaintenanceLabel,
          message: 'Фоновая проверка завершилась с ошибкой: $error',
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
}
