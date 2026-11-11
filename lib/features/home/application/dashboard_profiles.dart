part of 'dashboard_controller.dart';

/// Subscription profiles: add, choose, refresh and remove.
mixin _DashboardProfiles
    on _DashboardCore, _DashboardAutoSelect, _DashboardConnection {
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
      _candidates.invalidate();
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
      _candidates.invalidate();
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
      // The refreshed template can change the server inventory, so cached
      // effective configs and auto-select fingerprints are no longer valid.
      _candidates.invalidate(profile.id);
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
      _candidates.invalidate();
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
}
