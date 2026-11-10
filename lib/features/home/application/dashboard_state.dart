import 'dart:io';

import 'package:gorion/core/state/update_value.dart';
import 'package:gorion/features/auto_select/data/auto_selector_service.dart';
import 'package:gorion/features/auto_select/model/auto_select_state.dart';
import 'package:gorion/features/profiles/model/profile_models.dart';
import 'package:gorion/features/runtime/model/runtime_mode.dart';
import 'package:gorion/features/runtime/model/runtime_models.dart';
import 'package:gorion/features/settings/model/connection_tuning_settings.dart';

RuntimeMode defaultRuntimeMode() {
  // The system proxy is the best default where Gorion can manage it; Linux
  // stays on the explicit local proxy (desktop environments differ too much).
  if (Platform.isWindows || Platform.isMacOS) {
    return RuntimeMode.systemProxy;
  }
  return RuntimeMode.mixed;
}

RuntimeMode normalizeRuntimeMode(RuntimeMode mode) {
  if (Platform.isWindows && mode == RuntimeMode.mixed) {
    return RuntimeMode.systemProxy;
  }
  return mode;
}

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
    UpdateValue<RuntimeSession?> runtimeSessionUpdate =
        const UpdateValue<RuntimeSession?>.absent(),
    bool clearRuntimeSession = false,
    DateTime? connectedAt,
    UpdateValue<DateTime?> connectedAtUpdate =
        const UpdateValue<DateTime?>.absent(),
    bool clearConnectedAt = false,
    Map<String, int>? delayByTag,
    String? selectedServerTag,
    UpdateValue<String?> selectedServerTagUpdate =
        const UpdateValue<String?>.absent(),
    bool clearSelectedServerTag = false,
    String? activeServerTag,
    UpdateValue<String?> activeServerTagUpdate =
        const UpdateValue<String?>.absent(),
    bool clearActiveServerTag = false,
    RecentSuccessfulAutoConnect? recentSuccessfulAutoConnect,
    UpdateValue<RecentSuccessfulAutoConnect?>
        recentSuccessfulAutoConnectUpdate =
        const UpdateValue<RecentSuccessfulAutoConnect?>.absent(),
    bool clearRecentSuccessfulAutoConnect = false,
    List<AutoSelectProbeResult>? autoSelectResults,
    AutoSelectActivityState? autoSelectActivity,
    UpdateValue<AutoSelectActivityState> autoSelectActivityUpdate =
        const UpdateValue<AutoSelectActivityState>.absent(),
    bool clearAutoSelectActivity = false,
    DateTime? lastBestServerCheckAt,
    UpdateValue<DateTime?> lastBestServerCheckAtUpdate =
        const UpdateValue<DateTime?>.absent(),
    bool clearLastBestServerCheckAt = false,
    String? statusMessage,
    UpdateValue<String?> statusMessageUpdate =
        const UpdateValue<String?>.absent(),
    bool clearStatusMessage = false,
    String? errorMessage,
    UpdateValue<String?> errorMessageUpdate =
        const UpdateValue<String?>.absent(),
    bool clearErrorMessage = false,
    List<String>? logs,
  }) {
    return DashboardState(
      bootstrapping: bootstrapping ?? this.bootstrapping,
      busy: busy ?? this.busy,
      refreshingDelays: refreshingDelays ?? this.refreshingDelays,
      runtimeMode: normalizeRuntimeMode(runtimeMode ?? this.runtimeMode),
      autoSelectSettings: autoSelectSettings ?? this.autoSelectSettings,
      connectionTuningSettings:
          connectionTuningSettings ?? this.connectionTuningSettings,
      storage: storage ?? this.storage,
      connectionStage: connectionStage ?? this.connectionStage,
      runtimeSession: clearRuntimeSession
          ? null
          : runtimeSessionUpdate.isPresent
          ? runtimeSessionUpdate.value
          : runtimeSession ?? this.runtimeSession,
      connectedAt: clearConnectedAt
          ? null
          : connectedAtUpdate.isPresent
          ? connectedAtUpdate.value
          : connectedAt ?? this.connectedAt,
      delayByTag: delayByTag ?? this.delayByTag,
      selectedServerTag: clearSelectedServerTag
          ? null
          : selectedServerTagUpdate.isPresent
          ? selectedServerTagUpdate.value
          : selectedServerTag ?? this.selectedServerTag,
      activeServerTag: clearActiveServerTag
          ? null
          : activeServerTagUpdate.isPresent
          ? activeServerTagUpdate.value
          : activeServerTag ?? this.activeServerTag,
      recentSuccessfulAutoConnect: clearRecentSuccessfulAutoConnect
          ? null
          : recentSuccessfulAutoConnectUpdate.isPresent
          ? recentSuccessfulAutoConnectUpdate.value
          : recentSuccessfulAutoConnect ?? this.recentSuccessfulAutoConnect,
      autoSelectResults: autoSelectResults ?? this.autoSelectResults,
      autoSelectActivity: clearAutoSelectActivity
          ? const AutoSelectActivityState()
          : autoSelectActivityUpdate.isPresent
          ? autoSelectActivityUpdate.value!
          : autoSelectActivity ?? this.autoSelectActivity,
      lastBestServerCheckAt: clearLastBestServerCheckAt
          ? null
          : lastBestServerCheckAtUpdate.isPresent
          ? lastBestServerCheckAtUpdate.value
          : lastBestServerCheckAt ?? this.lastBestServerCheckAt,
      statusMessage: clearStatusMessage
          ? null
          : statusMessageUpdate.isPresent
          ? statusMessageUpdate.value
          : statusMessage ?? this.statusMessage,
      errorMessage: clearErrorMessage
          ? null
          : errorMessageUpdate.isPresent
          ? errorMessageUpdate.value
          : errorMessage ?? this.errorMessage,
      logs: logs ?? this.logs,
    );
  }
}
