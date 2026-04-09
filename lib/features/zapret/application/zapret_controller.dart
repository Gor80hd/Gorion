import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gorion_clean/core/http_client/http_client_provider.dart';
import 'package:gorion_clean/core/windows/windows_elevation_service.dart';
import 'package:gorion_clean/features/zapret/data/zapret_probe_service.dart';
import 'package:gorion_clean/features/zapret/data/zapret_runtime_service.dart';
import 'package:gorion_clean/features/zapret/data/zapret_settings_repository.dart';
import 'package:gorion_clean/features/zapret/model/zapret_models.dart';
import 'package:gorion_clean/features/zapret/model/zapret_settings.dart';

final zapretSettingsRepositoryProvider = Provider<ZapretSettingsRepository>(
  (ref) => ZapretSettingsRepository(),
);

final zapretRuntimeServiceProvider = Provider<ZapretRuntimeService>((ref) {
  final service = ZapretRuntimeService();
  ref.onDispose(service.dispose);
  return service;
});

final zapretProbeServiceProvider = Provider<ZapretProbeService>((ref) {
  final httpClientState = ref.read(httpClientProvider);
  return ZapretProbeService(userAgent: httpClientState.userAgent);
});

final zapretControllerProvider =
    StateNotifierProvider<ZapretController, ZapretState>((ref) {
      return ZapretController(
        repository: ref.read(zapretSettingsRepositoryProvider),
        runtimeService: ref.read(zapretRuntimeServiceProvider),
        probeService: ref.read(zapretProbeServiceProvider),
        elevationService: ref.read(windowsElevationServiceProvider),
      );
    });

class ZapretState {
  const ZapretState({
    this.bootstrapping = true,
    this.busy = false,
    this.settings = const ZapretSettings(),
    this.stage = ZapretStage.stopped,
    this.runtimeSession,
    this.tunConflictActive = false,
    this.generatedConfigPreview,
    this.generatedConfigSummary,
    this.statusMessage,
    this.errorMessage,
    this.logs = const [],
    this.autotuneRunning = false,
    this.lastProbeReport,
  });

  final bool bootstrapping;
  final bool busy;
  final ZapretSettings settings;
  final ZapretStage stage;
  final ZapretRuntimeSession? runtimeSession;
  final bool tunConflictActive;
  final String? generatedConfigPreview;
  final String? generatedConfigSummary;
  final String? statusMessage;
  final String? errorMessage;
  final List<String> logs;
  final bool autotuneRunning;
  final ZapretProbeReport? lastProbeReport;

  bool get canStart {
    return !bootstrapping &&
        !busy &&
        !tunConflictActive &&
        settings.hasInstallDirectory &&
        stage != ZapretStage.running &&
        stage != ZapretStage.starting;
  }

  bool get canStop {
    return !busy &&
        (stage == ZapretStage.running || stage == ZapretStage.starting);
  }

  ZapretState copyWith({
    bool? bootstrapping,
    bool? busy,
    ZapretSettings? settings,
    ZapretStage? stage,
    ZapretRuntimeSession? runtimeSession,
    bool clearRuntimeSession = false,
    bool? tunConflictActive,
    String? generatedConfigPreview,
    bool clearGeneratedConfigPreview = false,
    String? generatedConfigSummary,
    bool clearGeneratedConfigSummary = false,
    String? statusMessage,
    bool clearStatusMessage = false,
    String? errorMessage,
    bool clearErrorMessage = false,
    List<String>? logs,
    bool? autotuneRunning,
    ZapretProbeReport? lastProbeReport,
    bool clearLastProbeReport = false,
  }) {
    return ZapretState(
      bootstrapping: bootstrapping ?? this.bootstrapping,
      busy: busy ?? this.busy,
      settings: settings ?? this.settings,
      stage: stage ?? this.stage,
      runtimeSession: clearRuntimeSession
          ? null
          : runtimeSession ?? this.runtimeSession,
      tunConflictActive: tunConflictActive ?? this.tunConflictActive,
      generatedConfigPreview: clearGeneratedConfigPreview
          ? null
          : generatedConfigPreview ?? this.generatedConfigPreview,
      generatedConfigSummary: clearGeneratedConfigSummary
          ? null
          : generatedConfigSummary ?? this.generatedConfigSummary,
      statusMessage: clearStatusMessage
          ? null
          : statusMessage ?? this.statusMessage,
      errorMessage: clearErrorMessage
          ? null
          : errorMessage ?? this.errorMessage,
      logs: logs ?? this.logs,
      autotuneRunning: autotuneRunning ?? this.autotuneRunning,
      lastProbeReport: clearLastProbeReport
          ? null
          : lastProbeReport ?? this.lastProbeReport,
    );
  }
}

class ZapretController extends StateNotifier<ZapretState> {
  ZapretController({
    required ZapretSettingsRepository repository,
    required ZapretRuntimeService runtimeService,
    ZapretProbeService? probeService,
    WindowsElevationService? elevationService,
    Duration probeSettleDuration = const Duration(milliseconds: 1600),
    ZapretState initialState = const ZapretState(),
    bool loadOnInit = true,
  }) : _repository = repository,
       _runtimeService = runtimeService,
       _probeService = probeService ?? ZapretProbeService(),
       _elevationService =
           elevationService ?? const NoopWindowsElevationService(),
       _probeSettleDuration = probeSettleDuration,
       super(initialState) {
    if (loadOnInit) {
      unawaited(_load());
    }
  }

  final ZapretSettingsRepository _repository;
  final ZapretRuntimeService _runtimeService;
  final ZapretProbeService _probeService;
  final WindowsElevationService _elevationService;
  final Duration _probeSettleDuration;

  Future<void> setInstallDirectory(String value) async {
    var nextSettings = state.settings.copyWith(installDirectory: value);
    if (!nextSettings.hasInstallDirectory) {
      nextSettings = await _runtimeService.hydrateSettings(nextSettings);
    }
    return _saveSettings(nextSettings);
  }

  Future<void> setPreset(ZapretPreset preset) {
    return _saveSettings(
      state.settings.copyWith(
        preset: preset,
        clearStrategyProfile: true,
        clearCustomProfile: true,
      ),
    );
  }

  Future<void> setGameFilterEnabled(bool enabled) {
    return _saveSettings(state.settings.copyWith(gameFilterEnabled: enabled));
  }

  Future<void> setYoutubeVariant(ZapretFlowsealVariant variant) {
    return _saveSettings(
      state.settings.copyWith(
        customProfile: state.settings.effectiveCustomProfile.copyWith(
          youtubeVariant: variant,
        ),
      ),
    );
  }

  Future<void> setDiscordVariant(ZapretFlowsealVariant variant) {
    return _saveSettings(
      state.settings.copyWith(
        customProfile: state.settings.effectiveCustomProfile.copyWith(
          discordVariant: variant,
        ),
      ),
    );
  }

  Future<void> setGenericVariant(ZapretFlowsealVariant variant) {
    return _saveSettings(
      state.settings.copyWith(
        customProfile: state.settings.effectiveCustomProfile.copyWith(
          genericVariant: variant,
        ),
      ),
    );
  }

  Future<void> setIpSetFilterMode(ZapretIpSetFilterMode mode) {
    return _saveSettings(state.settings.copyWith(ipSetFilterMode: mode));
  }

  Future<void> setStartOnAppLaunch(bool enabled) {
    return _saveSettings(state.settings.copyWith(startOnAppLaunch: enabled));
  }

  Future<void> generateConfiguration() async {
    if (state.bootstrapping) {
      return;
    }

    try {
      final settings = await _ensureHydratedSettings();
      final configuration = _runtimeService.buildPreview(settings);
      state = state.copyWith(
        settings: settings,
        generatedConfigPreview: configuration.preview,
        generatedConfigSummary: configuration.summary,
        statusMessage:
            'Сформирован предпросмотр конфигурации: ${configuration.summary}.',
        clearErrorMessage: true,
        logs: _runtimeService.logs,
      );
    } on Object catch (error) {
      state = state.copyWith(
        errorMessage: _describeError(error),
        clearStatusMessage: true,
      );
    }
  }

  Future<void> start() async {
    if (state.bootstrapping || state.busy) {
      return;
    }
    if (state.tunConflictActive) {
      state = state.copyWith(
        errorMessage: 'Перед запуском zapret2 остановите TUN-режим.',
        clearStatusMessage: true,
      );
      return;
    }
    final settings = await _ensureHydratedSettings();
    if (!settings.hasInstallDirectory) {
      state = state.copyWith(
        errorMessage: 'Сначала укажите каталог установки zapret2.',
        clearStatusMessage: true,
      );
      return;
    }

    if (await _maybeRelaunchForElevation()) {
      return;
    }

    state = state.copyWith(
      busy: true,
      stage: ZapretStage.starting,
      clearErrorMessage: true,
      clearStatusMessage: true,
      logs: _runtimeService.logs,
    );

    try {
      final configuration = _runtimeService.buildPreview(settings);
      final session = await _runtimeService.start(
        settings: settings,
        onExit: _handleProcessExit,
      );
      state = state.copyWith(
        busy: false,
        settings: settings,
        stage: ZapretStage.running,
        runtimeSession: session,
        generatedConfigPreview: configuration.preview,
        generatedConfigSummary: configuration.summary,
        statusMessage: 'zapret2 запущен: ${configuration.summary}.',
        clearErrorMessage: true,
        logs: _runtimeService.logs,
      );
    } on Object catch (error) {
      state = state.copyWith(
        busy: false,
        stage: ZapretStage.failed,
        clearRuntimeSession: true,
        errorMessage: _describeError(error),
        clearStatusMessage: true,
        logs: _runtimeService.logs,
      );
    }
  }

  Future<void> autoTuneForBlockedResources() async {
    if (state.bootstrapping || state.busy) {
      return;
    }
    if (!Platform.isWindows) {
      state = state.copyWith(
        errorMessage:
            'Автоподбор zapret2 пока поддерживается только в Windows.',
        clearStatusMessage: true,
      );
      return;
    }
    if (state.tunConflictActive) {
      state = state.copyWith(
        errorMessage: 'Перед автоподбором остановите TUN-режим.',
        clearStatusMessage: true,
      );
      return;
    }

    final hydratedSettings = await _ensureHydratedSettings();
    if (!hydratedSettings.hasInstallDirectory) {
      state = state.copyWith(
        errorMessage: 'Сначала укажите каталог установки zapret2.',
        clearStatusMessage: true,
      );
      return;
    }

    if (await _maybeRelaunchForElevation()) {
      return;
    }

    final previousSettings = state.settings;
    final hadRunningSession =
        state.stage == ZapretStage.running ||
        state.stage == ZapretStage.starting;
    ZapretProbeReport? lastReport = state.lastProbeReport;
    final outcomes = <_ZapretAutotuneCandidateOutcome>[];

    if (hadRunningSession) {
      try {
        await _runtimeService.stop();
      } on Object catch (error) {
        _runtimeService.recordDiagnostic(
          'Не удалось остановить текущий процесс перед автоподбором: $error',
          isError: true,
        );
      }
    }

    _runtimeService.recordDiagnostic(
      'Автоподбор zapret2: запускаю staged-search с расширенным перебором Discord/HTTPS комбинаций и backtracking по лучшим Flowseal-style кандидатам без overlay-шумов.',
    );
    final coreSettings = hydratedSettings.copyWith(
      gameFilterEnabled: false,
      ipSetFilterMode: ZapretIpSetFilterMode.none,
    );
    state = state.copyWith(
      busy: true,
      autotuneRunning: true,
      stage: ZapretStage.starting,
      settings: coreSettings,
      clearRuntimeSession: true,
      clearErrorMessage: true,
      clearStatusMessage: true,
      logs: _runtimeService.logs,
    );

    final coreFinalists = await _tuneFlowsealProfile(
      baseSettings: coreSettings,
      outcomes: outcomes,
      onReport: (report) {
        lastReport = report;
        state = state.copyWith(
          lastProbeReport: report,
          logs: _runtimeService.logs,
        );
      },
    );

    if (coreFinalists.isEmpty) {
      if (hadRunningSession) {
        try {
          _runtimeService.recordDiagnostic(
            'Рабочий staged-profile не найден. Восстанавливаю предыдущий профиль.',
          );
          final restoreConfiguration = _runtimeService.buildPreview(
            previousSettings,
          );
          final restoredSession = await _runtimeService.start(
            settings: previousSettings,
            onExit: _handleProcessExit,
            preserveLogs: true,
          );
          state = state.copyWith(
            busy: false,
            autotuneRunning: false,
            settings: previousSettings,
            stage: ZapretStage.running,
            runtimeSession: restoredSession,
            generatedConfigPreview: restoreConfiguration.preview,
            generatedConfigSummary: restoreConfiguration.summary,
            statusMessage:
                'Автоподбор не нашёл рабочий staged-profile. Предыдущий профиль восстановлен.',
            clearErrorMessage: true,
            lastProbeReport: lastReport,
            logs: _runtimeService.logs,
          );
          return;
        } on Object catch (error) {
          _runtimeService.recordDiagnostic(
            'Не удалось восстановить предыдущий профиль: $error',
            isError: true,
          );
        }
      }

      state = state.copyWith(
        busy: false,
        autotuneRunning: false,
        settings: previousSettings,
        stage: ZapretStage.failed,
        clearRuntimeSession: true,
        errorMessage: _buildAutotuneFailureMessage(lastReport, outcomes),
        clearStatusMessage: true,
        lastProbeReport: lastReport,
        logs: _runtimeService.logs,
      );
      return;
    }

    final requiredTargets = _probeService.targetsById(const [
      'youtube',
      'discord',
      'google',
      'cloudflare',
    ]);
    ZapretCustomProfile? coreProfile;

    for (var index = 0; index < coreFinalists.length; index += 1) {
      final finalist = coreFinalists[index];
      final candidateSettings = coreSettings.copyWith(
        customProfile: finalist.profile,
      );
      final coreConfirmation = await _runAutotuneProbeCandidate(
        label:
            'Финальная проверка core-profile ${index + 1}/${coreFinalists.length}: ${finalist.label}',
        settings: candidateSettings,
        targets: requiredTargets,
        outcomes: outcomes,
        onReport: (report) {
          lastReport = report;
          state = state.copyWith(
            lastProbeReport: report,
            logs: _runtimeService.logs,
          );
        },
      );

      if (coreConfirmation != null &&
          _reportPassesTargets(coreConfirmation, requiredTargets)) {
        coreProfile = finalist.profile;
        _runtimeService.recordDiagnostic(
          'Финальная проверка: подтверждён ${finalist.profile.summaryLabel}.',
        );
        break;
      }

      _runtimeService.recordDiagnostic(
        'Финальная проверка ${index + 1}/${coreFinalists.length} не прошла, продолжаю со следующим кандидатом.',
      );
    }

    if (coreProfile == null) {
      _runtimeService.recordDiagnostic(
        'Ни один finalist core-profile не прошёл общую проверку обязательных ресурсов.',
        isError: true,
      );
      if (hadRunningSession) {
        try {
          _runtimeService.recordDiagnostic(
            'Core-profile не прошёл финальную проверку. Восстанавливаю предыдущий профиль.',
          );
          final restoreConfiguration = _runtimeService.buildPreview(
            previousSettings,
          );
          final restoredSession = await _runtimeService.start(
            settings: previousSettings,
            onExit: _handleProcessExit,
            preserveLogs: true,
          );
          state = state.copyWith(
            busy: false,
            autotuneRunning: false,
            settings: previousSettings,
            stage: ZapretStage.running,
            runtimeSession: restoredSession,
            generatedConfigPreview: restoreConfiguration.preview,
            generatedConfigSummary: restoreConfiguration.summary,
            statusMessage:
                'Автоподбор не подтвердил core-profile. Предыдущий профиль восстановлен.',
            clearErrorMessage: true,
            lastProbeReport: lastReport,
            logs: _runtimeService.logs,
          );
          return;
        } on Object catch (error) {
          _runtimeService.recordDiagnostic(
            'Не удалось восстановить предыдущий профиль: $error',
            isError: true,
          );
        }
      }

      state = state.copyWith(
        busy: false,
        autotuneRunning: false,
        settings: previousSettings,
        stage: ZapretStage.failed,
        clearRuntimeSession: true,
        errorMessage: _buildAutotuneFailureMessage(lastReport, outcomes),
        clearStatusMessage: true,
        lastProbeReport: lastReport,
        logs: _runtimeService.logs,
      );
      return;
    }

    final resolvedCoreProfile = coreProfile;
    var finalSettings = coreSettings.copyWith(
      customProfile: resolvedCoreProfile,
    );

    if (hydratedSettings.gameFilterEnabled ||
        hydratedSettings.ipSetFilterMode == ZapretIpSetFilterMode.any) {
      final overlaySettings = finalSettings.copyWith(
        gameFilterEnabled: hydratedSettings.gameFilterEnabled,
        ipSetFilterMode: hydratedSettings.ipSetFilterMode,
      );
      final overlayConfirmation = await _runAutotuneProbeCandidate(
        label: 'Проверка overlay-блоков',
        settings: overlaySettings,
        targets: requiredTargets,
        outcomes: outcomes,
        onReport: (report) {
          lastReport = report;
          state = state.copyWith(
            lastProbeReport: report,
            logs: _runtimeService.logs,
          );
        },
      );
      if (overlayConfirmation != null &&
          _reportPassesTargets(overlayConfirmation, requiredTargets)) {
        finalSettings = overlaySettings;
      } else {
        _runtimeService.recordDiagnostic(
          'Overlay-блоки ухудшили обязательные проверки. Сохраняю чистый core-profile без Game Filter/IPSet.',
        );
      }
    }

    final stored = await _repository.save(finalSettings);
    final finalConfiguration = _runtimeService.buildPreview(stored);
    final finalSession = await _runtimeService.start(
      settings: stored,
      onExit: _handleProcessExit,
      preserveLogs: true,
    );

    state = state.copyWith(
      busy: false,
      autotuneRunning: false,
      settings: stored,
      stage: ZapretStage.running,
      runtimeSession: finalSession,
      generatedConfigPreview: finalConfiguration.preview,
      generatedConfigSummary: finalConfiguration.summary,
      statusMessage:
          'Автоподбор завершён: ${stored.customProfile?.summaryLabel ?? finalConfiguration.summary}.',
      clearErrorMessage: true,
      lastProbeReport: lastReport,
      logs: _runtimeService.logs,
    );
  }

  Future<void> stop({
    bool pausedByTun = false,
    String? reason,
    bool force = false,
  }) async {
    if (state.bootstrapping || (state.busy && !force)) {
      return;
    }
    if (state.stage != ZapretStage.running &&
        state.stage != ZapretStage.starting) {
      if (pausedByTun) {
        state = state.copyWith(
          stage: ZapretStage.pausedByTun,
          statusMessage:
              reason ?? 'zapret2 остановлен, потому что активен TUN-режим.',
          clearErrorMessage: true,
          clearRuntimeSession: true,
          logs: _runtimeService.logs,
        );
      }
      return;
    }

    state = state.copyWith(
      busy: true,
      stage: ZapretStage.stopping,
      clearErrorMessage: true,
      clearStatusMessage: true,
    );

    try {
      await _runtimeService.stop();
      state = state.copyWith(
        busy: false,
        autotuneRunning: false,
        stage: pausedByTun ? ZapretStage.pausedByTun : ZapretStage.stopped,
        clearRuntimeSession: true,
        statusMessage:
            reason ??
            (pausedByTun
                ? 'zapret2 остановлен, потому что активен TUN-режим.'
                : 'zapret2 остановлен.'),
        logs: _runtimeService.logs,
      );
    } on Object catch (error) {
      state = state.copyWith(
        busy: false,
        autotuneRunning: false,
        stage: ZapretStage.failed,
        clearRuntimeSession: true,
        errorMessage: _describeError(error),
        clearStatusMessage: true,
        logs: _runtimeService.logs,
      );
    }
  }

  Future<void> syncTunConflict({required bool active}) async {
    final previousConflict = state.tunConflictActive;
    if (previousConflict == active) {
      return;
    }

    state = state.copyWith(tunConflictActive: active);

    if (active) {
      if (state.settings.autoStopOnTun &&
          (state.stage == ZapretStage.running ||
              state.stage == ZapretStage.starting)) {
        await stop(
          pausedByTun: true,
          reason:
              'zapret2 остановлен, потому что стал активен TUN-режим sing-box.',
          force: true,
        );
        return;
      }
      state = state.copyWith(
        statusMessage:
            'Активен TUN-режим. Остановите TUN перед запуском zapret2.',
        clearErrorMessage: true,
      );
      return;
    }

    if (state.stage == ZapretStage.pausedByTun) {
      state = state.copyWith(
        stage: ZapretStage.stopped,
        statusMessage:
            'TUN-режим больше не активен. zapret2 можно запустить снова.',
        clearErrorMessage: true,
      );
    }
  }

  Future<void> shutdownForAppExit() async {
    try {
      await _runtimeService.stop();
    } on Object {
      return;
    }
  }

  void _handleProcessExit(int exitCode) {
    final nextStage = state.tunConflictActive
        ? ZapretStage.pausedByTun
        : exitCode == 0
        ? ZapretStage.stopped
        : ZapretStage.failed;
    state = state.copyWith(
      busy: false,
      autotuneRunning: false,
      stage: nextStage,
      clearRuntimeSession: true,
      statusMessage: exitCode == 0
          ? state.tunConflictActive
                ? 'zapret2 остановлен, потому что активен TUN-режим.'
                : 'zapret2 остановлен.'
          : null,
      clearStatusMessage: exitCode != 0,
      errorMessage: exitCode == 0 ? null : _describeExitCode(exitCode),
      clearErrorMessage: exitCode == 0,
      logs: _runtimeService.logs,
    );
  }

  String _describeExitCode(int exitCode) {
    if (exitCode == 87) {
      return 'zapret2 отклонил параметры запуска (код 87 / ERROR_INVALID_PARAMETER). Значит, winws2 не принял один из аргументов текущего пресета.';
    }
    if (exitCode == -1073741502) {
      return 'zapret2 не смог инициализироваться (код -1073741502 / 0xC0000142). Обычно это сбой инициализации DLL или процесса; сначала попробуйте запустить Gorion от имени администратора.';
    }

    final hexSuffix = exitCode < 0
        ? ' (${_formatWindowsExitCode(exitCode)})'
        : '';
    return 'zapret2 завершился с кодом $exitCode$hexSuffix.';
  }

  String _formatWindowsExitCode(int exitCode) {
    final unsignedCode = exitCode & 0xFFFFFFFF;
    final hex = unsignedCode.toRadixString(16).toUpperCase().padLeft(8, '0');
    return '0x$hex';
  }

  Future<void> _load() async {
    try {
      final stored = await _repository.load();
      final settings = _normalizeSettingsModel(
        await _runtimeService.hydrateSettings(stored),
      );
      final configuration = settings.hasInstallDirectory
          ? _runtimeService.buildPreview(settings)
          : null;
      state = state.copyWith(
        bootstrapping: false,
        settings: settings,
        generatedConfigPreview: configuration?.preview,
        generatedConfigSummary: configuration?.summary,
        logs: _runtimeService.logs,
      );
    } on Object catch (error) {
      state = state.copyWith(
        bootstrapping: false,
        settings: const ZapretSettings(),
        errorMessage: _describeError(error),
        logs: _runtimeService.logs,
      );
    }
  }

  Future<void> _saveSettings(ZapretSettings nextSettings) async {
    var candidate = _normalizeSettingsModel(nextSettings);
    if (!candidate.hasInstallDirectory) {
      candidate = _normalizeSettingsModel(
        await _runtimeService.hydrateSettings(candidate),
      );
    }

    if (state.busy || state.settings == candidate) {
      return;
    }

    state = state.copyWith(busy: true, clearErrorMessage: true);
    try {
      final stored = await _repository.save(candidate);
      final configuration = stored.hasInstallDirectory
          ? _runtimeService.buildPreview(stored)
          : null;
      state = state.copyWith(
        busy: false,
        settings: stored,
        generatedConfigPreview: configuration?.preview,
        clearGeneratedConfigPreview: configuration == null,
        generatedConfigSummary: configuration?.summary,
        clearGeneratedConfigSummary: configuration == null,
        statusMessage: 'Настройки zapret2 сохранены.',
        logs: _runtimeService.logs,
      );
    } on Object catch (error) {
      state = state.copyWith(busy: false, errorMessage: _describeError(error));
    }
  }

  Future<ZapretSettings> _ensureHydratedSettings() async {
    final hydrated = _normalizeSettingsModel(
      await _runtimeService.hydrateSettings(state.settings),
    );
    if (hydrated != state.settings) {
      state = state.copyWith(settings: hydrated);
    }
    return hydrated;
  }

  ZapretSettings _normalizeSettingsModel(ZapretSettings settings) {
    if (settings.hasCustomProfile) {
      return settings;
    }
    return settings.copyWith(customProfile: settings.effectiveCustomProfile);
  }

  String _describeError(Object error) {
    if (error is ProcessException && _isElevationRequired(error)) {
      return 'Запуск winws2 требует прав администратора. Перезапустите Gorion от имени администратора и попробуйте снова.';
    }
    return error.toString();
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

  Future<bool> _maybeRelaunchForElevation() async {
    if (!Platform.isWindows) {
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

    try {
      await _elevationService.relaunchAsAdministrator(
        action: PendingElevatedLaunchAction.startZapret,
      );
      state = state.copyWith(
        statusMessage:
            'Запрошены права администратора. После подтверждения UAC Gorion перезапустится и продолжит запуск zapret2.',
        clearErrorMessage: true,
      );
    } on ElevationRequestCancelledException {
      state = state.copyWith(
        errorMessage:
            'Запрос прав администратора был отменён. zapret2 не запущен.',
        clearStatusMessage: true,
      );
    } on Object catch (error) {
      state = state.copyWith(
        errorMessage:
            'Не удалось запросить права администратора для zapret2: $error',
        clearStatusMessage: true,
      );
    }

    return true;
  }

  Future<List<_ZapretAutotuneStageSelection>> _tuneFlowsealProfile({
    required ZapretSettings baseSettings,
    required List<_ZapretAutotuneCandidateOutcome> outcomes,
    required void Function(ZapretProbeReport report) onReport,
  }) async {
    const youtubeSeedCount = 2;
    const discordSeedCount = 2;
    const httpsSeedCount = 3;

    final youtubeSelections = await _runAutotuneStage(
      stageLabel: 'YouTube',
      baseSettings: baseSettings,
      targets: _probeService.targetsById(const ['youtube']),
      candidates: [
        for (final variant in ZapretFlowsealVariant.values)
          _ZapretAutotuneProfileCandidate(
            label: 'YouTube ${variant.label}',
            retentionKey: variant.jsonValue,
            profile: const ZapretCustomProfile().copyWith(
              youtubeVariant: variant,
            ),
          ),
      ],
      outcomes: outcomes,
      onReport: onReport,
      maxRetainedSelections: youtubeSeedCount,
    );
    if (youtubeSelections.isEmpty) {
      return const [];
    }

    final discordSelections = await _runAutotuneStage(
      stageLabel: 'Discord',
      baseSettings: baseSettings,
      targets: _probeService.targetsById(const ['discord']),
      candidates: [
        for (final seed in youtubeSelections)
          for (final genericVariant in ZapretFlowsealVariant.values)
            for (final discordVariant in ZapretFlowsealVariant.values)
              _ZapretAutotuneProfileCandidate(
                label:
                    'YT ${seed.profile.youtubeVariant.label} • Discord ${discordVariant.label} • HTTPS ${genericVariant.label}',
                retentionKey:
                    '${seed.profile.youtubeVariant.jsonValue}|${genericVariant.jsonValue}',
                profile: seed.profile.copyWith(
                  discordVariant: discordVariant,
                  genericVariant: genericVariant,
                ),
              ),
      ],
      outcomes: outcomes,
      onReport: onReport,
      maxRetainedSelections: discordSeedCount,
    );
    if (discordSelections.isEmpty) {
      return const [];
    }

    return _runAutotuneStage(
      stageLabel: 'HTTPS',
      baseSettings: baseSettings,
      targets: _probeService.targetsById(const ['google', 'cloudflare']),
      candidates: [
        for (final seed in discordSelections)
          for (final genericVariant in ZapretFlowsealVariant.values)
            _ZapretAutotuneProfileCandidate(
              label:
                  'YT ${seed.profile.youtubeVariant.label} • Discord ${seed.profile.discordVariant.label} • HTTPS ${genericVariant.label}',
              retentionKey:
                  '${seed.profile.youtubeVariant.jsonValue}|${genericVariant.jsonValue}',
              profile: seed.profile.copyWith(genericVariant: genericVariant),
            ),
      ],
      outcomes: outcomes,
      onReport: onReport,
      maxRetainedSelections: httpsSeedCount,
    );
  }

  Future<List<_ZapretAutotuneStageSelection>> _runAutotuneStage({
    required String stageLabel,
    required ZapretSettings baseSettings,
    required List<ZapretProbeTarget> targets,
    required List<_ZapretAutotuneProfileCandidate> candidates,
    required List<_ZapretAutotuneCandidateOutcome> outcomes,
    required void Function(ZapretProbeReport report) onReport,
    int maxRetainedSelections = 1,
  }) async {
    final stageOutcomes = <_ZapretAutotuneStageSelection>[];

    for (var index = 0; index < candidates.length; index += 1) {
      final candidate = candidates[index];
      final candidateSettings = baseSettings.copyWith(
        customProfile: candidate.profile,
      );
      final configuration = _runtimeService.buildPreview(candidateSettings);

      _runtimeService.recordDiagnostic(
        'Автоподбор [$stageLabel] ${index + 1}/${candidates.length}: ${candidate.label}.',
      );
      state = state.copyWith(
        settings: candidateSettings,
        generatedConfigPreview: configuration.preview,
        generatedConfigSummary: configuration.summary,
        statusMessage:
            'Автоподбор [$stageLabel] ${index + 1}/${candidates.length}: ${candidate.label}.',
        clearErrorMessage: true,
        logs: _runtimeService.logs,
      );

      try {
        final report = await _runAutotuneProbeCandidate(
          label: candidate.label,
          settings: candidateSettings,
          targets: targets,
          outcomes: outcomes,
          onReport: onReport,
        );
        if (report == null) {
          continue;
        }
        stageOutcomes.add(
          _ZapretAutotuneStageSelection(
            label: candidate.label,
            retentionKey: candidate.retentionKey,
            profile: candidate.profile,
            report: report,
            order: index,
          ),
        );
      } on Object catch (error) {
        outcomes.add(
          _ZapretAutotuneCandidateOutcome(
            label: '$stageLabel: ${candidate.label}',
            error: error.toString(),
          ),
        );
        _runtimeService.recordDiagnostic(
          'Кандидат [$stageLabel] ${candidate.label} завершился ошибкой: $error',
          isError: true,
        );
      }
    }

    if (stageOutcomes.isEmpty) {
      return const [];
    }

    final stageTargetIds = {for (final target in targets) target.id};
    stageOutcomes.sort((left, right) {
      final compare = _compareAutotuneReports(
        left.report,
        right.report,
        stageTargetIds,
      );
      if (compare != 0) {
        return compare;
      }
      return left.order.compareTo(right.order);
    });

    final retained = <_ZapretAutotuneStageSelection>[];
    final seenRetentionKeys = <String>{};
    for (final selection in stageOutcomes) {
      if (!_reportPassesTargets(selection.report, targets)) {
        continue;
      }
      if (!seenRetentionKeys.add(selection.retentionKey)) {
        continue;
      }
      retained.add(selection);
      if (retained.length >= maxRetainedSelections) {
        break;
      }
    }
    if (retained.isEmpty) {
      _runtimeService.recordDiagnostic(
        'Этап $stageLabel не нашёл вариант, который прошёл все обязательные проверки этапа.',
        isError: true,
      );
      return const [];
    }

    _runtimeService.recordDiagnostic(
      'Этап $stageLabel: оставляю ${retained.length} кандидата(ов). Лучший: ${retained.first.label}. ${retained.first.report.summary}',
    );
    return retained;
  }

  Future<ZapretProbeReport?> _runAutotuneProbeCandidate({
    required String label,
    required ZapretSettings settings,
    required List<ZapretProbeTarget> targets,
    required List<_ZapretAutotuneCandidateOutcome> outcomes,
    required void Function(ZapretProbeReport report) onReport,
  }) async {
    try {
      await _runtimeService.start(
        settings: settings,
        onExit: (_) {},
        preserveLogs: true,
      );
      _runtimeService.recordDiagnostic(
        'Ожидание стабилизации перехвата перед сетевыми проверками.',
      );
      await Future.delayed(_probeSettleDuration);

      final probeReport = await _probeService.runProbes(
        targets: targets,
        onLog: (line) {
          _runtimeService.recordDiagnostic('Проверка: $line');
        },
      );
      outcomes.add(
        _ZapretAutotuneCandidateOutcome(label: label, report: probeReport),
      );
      onReport(probeReport);
      return probeReport;
    } on Object catch (error) {
      outcomes.add(
        _ZapretAutotuneCandidateOutcome(label: label, error: error.toString()),
      );
      _runtimeService.recordDiagnostic(
        'Кандидат $label завершился ошибкой: $error',
        isError: true,
      );
      return null;
    } finally {
      if (_runtimeService.session != null) {
        try {
          await _runtimeService.stop();
        } on Object catch (error) {
          _runtimeService.recordDiagnostic(
            'Не удалось остановить промежуточную попытку: $error',
            isError: true,
          );
        }
      }
    }
  }

  bool _reportPassesTargets(
    ZapretProbeReport report,
    List<ZapretProbeTarget> targets,
  ) {
    final targetIds = {for (final target in targets) target.id};
    final resultsById = {
      for (final result in report.results) result.target.id: result,
    };
    for (final targetId in targetIds) {
      final result = resultsById[targetId];
      if (result == null || !result.success) {
        return false;
      }
    }
    return true;
  }

  int _compareAutotuneReports(
    ZapretProbeReport left,
    ZapretProbeReport right,
    Set<String> targetIds,
  ) {
    final rightPassed = _targetPassCount(right, targetIds);
    final leftPassed = _targetPassCount(left, targetIds);
    final passedCompare = rightPassed.compareTo(leftPassed);
    if (passedCompare != 0) {
      return passedCompare;
    }

    final rightLatency = _targetLatencyTotal(right, targetIds);
    final leftLatency = _targetLatencyTotal(left, targetIds);
    final latencyCompare = leftLatency.compareTo(rightLatency);
    if (latencyCompare != 0) {
      return latencyCompare;
    }

    final rightSuccess = right.results.where((item) => item.success).length;
    final leftSuccess = left.results.where((item) => item.success).length;
    return rightSuccess.compareTo(leftSuccess);
  }

  int _targetPassCount(ZapretProbeReport report, Set<String> targetIds) {
    return report.results.where((item) {
      return targetIds.contains(item.target.id) && item.success;
    }).length;
  }

  int _targetLatencyTotal(ZapretProbeReport report, Set<String> targetIds) {
    var total = 0;
    for (final result in report.results) {
      if (!targetIds.contains(result.target.id)) {
        continue;
      }
      total += result.success ? (result.latencyMs ?? 5000) : 5000;
    }
    return total;
  }

  String _buildAutotuneFailureMessage(
    ZapretProbeReport? report,
    List<_ZapretAutotuneCandidateOutcome> outcomes,
  ) {
    if (report == null && outcomes.isEmpty) {
      return 'Автоподбор не смог проверить ни один кандидат.';
    }

    final reportOutcomes =
        outcomes.where((entry) => entry.report != null).toList()
          ..sort((left, right) {
            final passedCompare = right.report!.requiredPassedCount.compareTo(
              left.report!.requiredPassedCount,
            );
            if (passedCompare != 0) {
              return passedCompare;
            }
            final coverageCompare = right.report!.requiredTotalCount.compareTo(
              left.report!.requiredTotalCount,
            );
            if (coverageCompare != 0) {
              return coverageCompare;
            }
            return right.report!.results
                .where((item) => item.success)
                .length
                .compareTo(
                  left.report!.results.where((item) => item.success).length,
                );
          });

    if (reportOutcomes.isNotEmpty) {
      final best = reportOutcomes.first;
      final bestReport = best.report!;
      final passedTargets = bestReport.passedRequiredResults
          .map((result) => result.target.label)
          .join(', ');
      final failedTargets = bestReport.failedRequiredResults
          .map((result) => result.target.label)
          .join(', ');
      final passedText = passedTargets.isEmpty ? 'ничего' : passedTargets;
      final failedText = failedTargets.isEmpty ? 'нет данных' : failedTargets;
      return 'Автоподбор не нашёл рабочий вариант после ${outcomes.length} попыток. Лучший кандидат: ${best.label} (${bestReport.requiredPassedCount}/${bestReport.requiredTotalCount}). Прошли: $passedText. Не прошли: $failedText.';
    }

    String? lastError;
    for (final outcome in outcomes.reversed) {
      if (outcome.error != null && outcome.error!.trim().isNotEmpty) {
        lastError = outcome.error;
        break;
      }
    }
    if (lastError != null) {
      return 'Автоподбор не нашёл рабочий вариант после ${outcomes.length} попыток. Последняя ошибка: $lastError';
    }

    return 'Автоподбор не нашёл рабочий вариант.';
  }
}

class _ZapretAutotuneProfileCandidate {
  const _ZapretAutotuneProfileCandidate({
    required this.label,
    required this.retentionKey,
    required this.profile,
  });

  final String label;
  final String retentionKey;
  final ZapretCustomProfile profile;
}

class _ZapretAutotuneStageSelection {
  const _ZapretAutotuneStageSelection({
    required this.label,
    required this.retentionKey,
    required this.profile,
    required this.report,
    required this.order,
  });

  final String label;
  final String retentionKey;
  final ZapretCustomProfile profile;
  final ZapretProbeReport report;
  final int order;
}

class _ZapretAutotuneCandidateOutcome {
  const _ZapretAutotuneCandidateOutcome({
    required this.label,
    this.report,
    this.error,
  });

  final String label;
  final ZapretProbeReport? report;
  final String? error;
}
