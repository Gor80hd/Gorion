import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gorion_clean/core/process/process_exception_utils.dart';
import 'package:gorion_clean/core/state/update_value.dart';
import 'package:gorion_clean/core/windows/elevation_relaunch_prompt_service.dart';
import 'package:gorion_clean/core/windows/windows_elevation_service.dart';
import 'package:gorion_clean/features/zapret/data/zapret_config_test_service.dart';
import 'package:gorion_clean/features/zapret/data/zapret_runtime_service.dart';
import 'package:gorion_clean/features/zapret/data/zapret_settings_repository.dart';
import 'package:gorion_clean/features/zapret/model/zapret_models.dart';
import 'package:gorion_clean/features/zapret/model/zapret_settings.dart';
import 'package:path/path.dart' as p;

final zapretSettingsRepositoryProvider = Provider<ZapretSettingsRepository>(
  (ref) => ZapretSettingsRepository(),
);

final zapretRuntimeServiceProvider = Provider<ZapretRuntimeService>((ref) {
  final service = buildZapretRuntimeService();
  ref.onDispose(service.dispose);
  return service;
});

final zapretConfigTestServiceProvider = Provider<ZapretConfigTestService>((
  ref,
) {
  return ZapretConfigTestService(
    runtimeService: ref.read(zapretRuntimeServiceProvider),
  );
});

final zapretControllerProvider =
    StateNotifierProvider<ZapretController, ZapretState>((ref) {
      return ZapretController(
        repository: ref.read(zapretSettingsRepositoryProvider),
        runtimeService: ref.read(zapretRuntimeServiceProvider),
        configTestService: ref.read(zapretConfigTestServiceProvider),
        elevationService: ref.read(windowsElevationServiceProvider),
        elevationPromptService: ref.read(
          elevationRelaunchPromptServiceProvider,
        ),
      );
    });

class ZapretState {
  const ZapretState({
    this.bootstrapping = true,
    this.busy = false,
    this.settings = const ZapretSettings(),
    this.availableConfigs = const [],
    this.stage = ZapretStage.stopped,
    this.runtimeSession,
    this.tunConflictActive = false,
    this.generatedConfigPreview,
    this.generatedConfigSummary,
    this.statusMessage,
    this.errorMessage,
    this.logs = const [],
    this.configTestInProgress = false,
    this.configTestCompleted = 0,
    this.configTestTotal = 0,
    this.configTestCurrentConfigLabel,
    this.configTestSuite,
  });

  final bool bootstrapping;
  final bool busy;
  final ZapretSettings settings;
  final List<ZapretConfigOption> availableConfigs;
  final ZapretStage stage;
  final ZapretRuntimeSession? runtimeSession;
  final bool tunConflictActive;
  final String? generatedConfigPreview;
  final String? generatedConfigSummary;
  final String? statusMessage;
  final String? errorMessage;
  final List<String> logs;
  final bool configTestInProgress;
  final int configTestCompleted;
  final int configTestTotal;
  final String? configTestCurrentConfigLabel;
  final ZapretConfigTestSuite? configTestSuite;

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
    List<ZapretConfigOption>? availableConfigs,
    ZapretStage? stage,
    ZapretRuntimeSession? runtimeSession,
    UpdateValue<ZapretRuntimeSession?> runtimeSessionUpdate =
        const UpdateValue<ZapretRuntimeSession?>.absent(),
    bool clearRuntimeSession = false,
    bool? tunConflictActive,
    String? generatedConfigPreview,
    UpdateValue<String?> generatedConfigPreviewUpdate =
        const UpdateValue<String?>.absent(),
    bool clearGeneratedConfigPreview = false,
    String? generatedConfigSummary,
    UpdateValue<String?> generatedConfigSummaryUpdate =
        const UpdateValue<String?>.absent(),
    bool clearGeneratedConfigSummary = false,
    String? statusMessage,
    UpdateValue<String?> statusMessageUpdate =
        const UpdateValue<String?>.absent(),
    bool clearStatusMessage = false,
    String? errorMessage,
    UpdateValue<String?> errorMessageUpdate =
        const UpdateValue<String?>.absent(),
    bool clearErrorMessage = false,
    List<String>? logs,
    bool? configTestInProgress,
    int? configTestCompleted,
    int? configTestTotal,
    String? configTestCurrentConfigLabel,
    UpdateValue<String?> configTestCurrentConfigLabelUpdate =
        const UpdateValue<String?>.absent(),
    bool clearConfigTestCurrentConfigLabel = false,
    ZapretConfigTestSuite? configTestSuite,
    UpdateValue<ZapretConfigTestSuite?> configTestSuiteUpdate =
        const UpdateValue<ZapretConfigTestSuite?>.absent(),
    bool clearConfigTestSuite = false,
  }) {
    return ZapretState(
      bootstrapping: bootstrapping ?? this.bootstrapping,
      busy: busy ?? this.busy,
      settings: settings ?? this.settings,
      availableConfigs: availableConfigs ?? this.availableConfigs,
      stage: stage ?? this.stage,
      runtimeSession: clearRuntimeSession
          ? null
          : runtimeSessionUpdate.isPresent
          ? runtimeSessionUpdate.value
          : runtimeSession ?? this.runtimeSession,
      tunConflictActive: tunConflictActive ?? this.tunConflictActive,
      generatedConfigPreview: clearGeneratedConfigPreview
          ? null
          : generatedConfigPreviewUpdate.isPresent
          ? generatedConfigPreviewUpdate.value
          : generatedConfigPreview ?? this.generatedConfigPreview,
      generatedConfigSummary: clearGeneratedConfigSummary
          ? null
          : generatedConfigSummaryUpdate.isPresent
          ? generatedConfigSummaryUpdate.value
          : generatedConfigSummary ?? this.generatedConfigSummary,
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
      configTestInProgress: configTestInProgress ?? this.configTestInProgress,
      configTestCompleted: configTestCompleted ?? this.configTestCompleted,
      configTestTotal: configTestTotal ?? this.configTestTotal,
      configTestCurrentConfigLabel: clearConfigTestCurrentConfigLabel
          ? null
          : configTestCurrentConfigLabelUpdate.isPresent
          ? configTestCurrentConfigLabelUpdate.value
          : configTestCurrentConfigLabel ?? this.configTestCurrentConfigLabel,
      configTestSuite: clearConfigTestSuite
          ? null
          : configTestSuiteUpdate.isPresent
          ? configTestSuiteUpdate.value
          : configTestSuite ?? this.configTestSuite,
    );
  }
}

class ZapretController extends StateNotifier<ZapretState> {
  ZapretController({
    required ZapretSettingsRepository repository,
    required ZapretRuntimeService runtimeService,
    ZapretConfigTestService? configTestService,
    WindowsElevationService? elevationService,
    ElevationRelaunchPromptService? elevationPromptService,
    ZapretState initialState = const ZapretState(),
    bool loadOnInit = true,
  }) : _repository = repository,
       _runtimeService = runtimeService,
       _configTestService =
           configTestService ??
           ZapretConfigTestService(runtimeService: runtimeService),
       _elevationService =
           elevationService ?? const NoopWindowsElevationService(),
       _elevationPromptService =
           elevationPromptService ?? const NoopElevationRelaunchPromptService(),
       super(initialState) {
    if (loadOnInit) {
      unawaited(_load());
    }
  }

  final ZapretSettingsRepository _repository;
  final ZapretRuntimeService _runtimeService;
  final ZapretConfigTestService _configTestService;
  final WindowsElevationService _elevationService;
  final ElevationRelaunchPromptService _elevationPromptService;

  Future<void> setInstallDirectory(String value) async {
    var nextSettings = state.settings.copyWith(installDirectory: value);
    nextSettings = await _runtimeService.hydrateSettings(nextSettings);
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

  Future<void> setConfigFileName(String fileName) {
    return _saveSettings(state.settings.copyWith(configFileName: fileName));
  }

  Future<void> setGameFilterMode(ZapretGameFilterMode mode) {
    return _saveSettings(state.settings.copyWith(gameFilterMode: mode));
  }

  Future<void> setGameFilterEnabled(bool enabled) {
    return _saveSettings(
      state.settings.copyWith(
        gameFilterMode: enabled
            ? ZapretGameFilterMode.all
            : ZapretGameFilterMode.disabled,
      ),
    );
  }

  Future<void> setYoutubeVariant(ZapretFlowsealVariant variant) {
    return _saveSettings(
      state.settings.copyWith(
        customProfile: state.settings.effectiveCustomProfile.copyWith(
          youtubeEnabled: true,
          youtubeVariant: variant,
        ),
      ),
    );
  }

  Future<void> setYoutubeBlockProfile(ZapretFlowsealBlockProfile profile) {
    return _saveSettings(
      state.settings.copyWith(
        customProfile: state.settings.effectiveCustomProfile.copyWith(
          youtube: profile,
        ),
      ),
    );
  }

  Future<void> setDiscordVariant(ZapretFlowsealVariant variant) {
    return _saveSettings(
      state.settings.copyWith(
        customProfile: state.settings.effectiveCustomProfile.copyWith(
          discordEnabled: true,
          discordVariant: variant,
        ),
      ),
    );
  }

  Future<void> setDiscordBlockProfile(ZapretFlowsealBlockProfile profile) {
    return _saveSettings(
      state.settings.copyWith(
        customProfile: state.settings.effectiveCustomProfile.copyWith(
          discord: profile,
        ),
      ),
    );
  }

  Future<void> setGenericVariant(ZapretFlowsealVariant variant) {
    return _saveSettings(
      state.settings.copyWith(
        customProfile: state.settings.effectiveCustomProfile.copyWith(
          genericEnabled: true,
          genericVariant: variant,
        ),
      ),
    );
  }

  Future<void> setGenericBlockProfile(ZapretFlowsealBlockProfile profile) {
    return _saveSettings(
      state.settings.copyWith(
        customProfile: state.settings.effectiveCustomProfile.copyWith(
          generic: profile,
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

  Future<void> refreshConfigs() async {
    if (state.bootstrapping || state.busy) {
      return;
    }

    state = state.copyWith(busy: true, clearErrorMessage: true);
    try {
      final settings = _normalizeSettingsModel(await _ensureHydratedSettings());
      final availableConfigs = _runtimeService.listAvailableProfiles(
        settings.normalizedInstallDirectory,
      );
      final configuration = _tryBuildPreview(settings);
      state = state.copyWith(
        busy: false,
        settings: settings,
        availableConfigs: availableConfigs,
        generatedConfigPreview: configuration?.preview,
        clearGeneratedConfigPreview: configuration == null,
        generatedConfigSummary: configuration?.summary,
        clearGeneratedConfigSummary: configuration == null,
        statusMessage: availableConfigs.isEmpty
            ? 'Конфиги не найдены. Откройте папку профилей и добавьте свой .conf.'
            : 'Список конфигов обновлён.',
        logs: _runtimeService.logs,
      );
    } on Object catch (error) {
      state = state.copyWith(
        busy: false,
        errorMessage: _describeError(error),
        clearStatusMessage: true,
      );
    }
  }

  Future<String?> prepareProfilesDirectory() async {
    if (state.bootstrapping || state.busy) {
      return null;
    }

    try {
      final settings = _normalizeSettingsModel(await _ensureHydratedSettings());
      if (!settings.hasInstallDirectory) {
        return null;
      }

      final profilesDirectory = Directory(
        p.join(settings.normalizedInstallDirectory, 'profiles'),
      );
      await profilesDirectory.create(recursive: true);
      return profilesDirectory.path;
    } on Object catch (error) {
      state = state.copyWith(
        errorMessage: _describeError(error),
        clearStatusMessage: true,
      );
      return null;
    }
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
        availableConfigs: _runtimeService.listAvailableProfiles(
          settings.normalizedInstallDirectory,
        ),
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

  Future<void> runHttpConfigTests() async {
    if (state.bootstrapping || state.busy) {
      return;
    }
    if (!Platform.isWindows) {
      state = state.copyWith(
        errorMessage:
            'Автотест конфигов Boost сейчас доступен только на Windows.',
        clearStatusMessage: true,
      );
      return;
    }
    if (state.stage == ZapretStage.running ||
        state.stage == ZapretStage.starting) {
      state = state.copyWith(
        errorMessage:
            'Остановите текущий Boost перед прогоном стандартного теста конфигов.',
        clearStatusMessage: true,
      );
      return;
    }
    if (state.tunConflictActive) {
      state = state.copyWith(
        errorMessage:
            'Сначала отключите TUN-режим, затем можно запускать стандартный тест конфигов.',
        clearStatusMessage: true,
      );
      return;
    }

    final settings = await _ensureHydratedSettings();
    if (!settings.hasInstallDirectory) {
      state = state.copyWith(
        errorMessage: 'Сначала укажите каталог установки Gorion Boost.',
        clearStatusMessage: true,
      );
      return;
    }

    if (await _maybeRelaunchForElevation(
      action: PendingElevatedLaunchAction.testZapretConfigs,
      successMessage:
          'Запрошены права администратора. После подтверждения UAC Gorion перезапустится и продолжит тестирование конфигов Boost.',
      cancelledMessage:
          'Запрос прав администратора был отменён. Тестирование конфигов не запущено.',
      failureMessagePrefix:
          'Не удалось запросить права администратора для тестирования конфигов Boost',
    )) {
      return;
    }

    final availableConfigs = _runtimeService.listAvailableProfiles(
      settings.normalizedInstallDirectory,
    );
    if (availableConfigs.isEmpty) {
      state = state.copyWith(
        errorMessage:
            'В папке Gorion Boost не найдено ни одного конфига для теста.',
        clearStatusMessage: true,
      );
      return;
    }

    state = state.copyWith(
      busy: true,
      clearErrorMessage: true,
      clearStatusMessage: true,
      configTestInProgress: true,
      configTestCompleted: 0,
      configTestTotal: availableConfigs.length,
      clearConfigTestCurrentConfigLabel: true,
    );

    try {
      final suite = await _configTestService.runHttpSuite(
        settings: settings,
        onProgress: (completed, total, config) {
          state = state.copyWith(
            configTestInProgress: true,
            configTestCompleted: completed,
            configTestTotal: total,
            configTestCurrentConfigLabel: config.label,
            logs: _runtimeService.logs,
          );
        },
      );

      final bestWorking = suite.bestWorkingResult;
      var savedSettings = settings;
      if (bestWorking != null &&
          bestWorking.config.fileName != settings.effectiveConfigFileName) {
        savedSettings = await _repository.save(
          settings.copyWith(configFileName: bestWorking.config.fileName),
        );
      }
      final normalizedSettings = _normalizeSettingsModel(savedSettings);
      final normalizedConfigs = _runtimeService.listAvailableProfiles(
        normalizedSettings.normalizedInstallDirectory,
      );

      final statusMessage = bestWorking == null
          ? suite.summary
          : bestWorking.config.fileName == settings.effectiveConfigFileName
          ? '${suite.summary} Лучший конфиг уже был выбран.'
          : '${suite.summary} Выбран автоматически: ${bestWorking.config.label}.';

      state = state.copyWith(
        busy: false,
        settings: normalizedSettings,
        availableConfigs: normalizedConfigs,
        statusMessage: statusMessage,
        clearErrorMessage: true,
        logs: _runtimeService.logs,
        configTestInProgress: false,
        configTestCompleted: suite.results.length,
        configTestTotal: suite.results.length,
        clearConfigTestCurrentConfigLabel: true,
        configTestSuite: suite,
      );
    } on Object catch (error) {
      state = state.copyWith(
        busy: false,
        errorMessage: _describeError(error),
        clearStatusMessage: true,
        logs: _runtimeService.logs,
        configTestInProgress: false,
        clearConfigTestCurrentConfigLabel: true,
      );
    }
  }

  Future<void> start() async {
    if (state.bootstrapping || state.busy) {
      return;
    }
    if (state.tunConflictActive) {
      state = state.copyWith(
        errorMessage: 'Перед запуском Gorion Boost остановите TUN-режим.',
        clearStatusMessage: true,
      );
      return;
    }
    final settings = await _ensureHydratedSettings();
    if (!settings.hasInstallDirectory) {
      state = state.copyWith(
        errorMessage: 'Сначала укажите каталог установки Gorion Boost.',
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
        availableConfigs: _runtimeService.listAvailableProfiles(
          settings.normalizedInstallDirectory,
        ),
        stage: ZapretStage.running,
        runtimeSession: session,
        generatedConfigPreview: configuration.preview,
        generatedConfigSummary: configuration.summary,
        statusMessage: 'Gorion Boost запущен: ${configuration.summary}.',
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
              reason ??
              'Gorion Boost остановлен, потому что активен TUN-режим.',
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
        stage: pausedByTun ? ZapretStage.pausedByTun : ZapretStage.stopped,
        clearRuntimeSession: true,
        statusMessage:
            reason ??
            (pausedByTun
                ? 'Gorion Boost остановлен, потому что активен TUN-режим.'
                : 'Gorion Boost остановлен.'),
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
              'Gorion Boost остановлен, потому что стал активен TUN-режим sing-box.',
          force: true,
        );
        return;
      }
      state = state.copyWith(
        statusMessage:
            'Активен TUN-режим. Остановите TUN перед запуском Gorion Boost.',
        clearErrorMessage: true,
      );
      return;
    }

    if (state.stage == ZapretStage.pausedByTun) {
      state = state.copyWith(
        stage: ZapretStage.stopped,
        statusMessage:
            'TUN-режим больше не активен. Gorion Boost можно запустить снова.',
        clearErrorMessage: true,
      );
    }
  }

  Future<void> shutdownForAppExit() async {
    try {
      await _runtimeService.stopForAppExit();
    } on Object {
      return;
    }
  }

  Future<void> reload() async {
    if (state.busy) {
      return;
    }
    await _load();
  }

  void _handleProcessExit(int exitCode) {
    final nextStage = state.tunConflictActive
        ? ZapretStage.pausedByTun
        : exitCode == 0
        ? ZapretStage.stopped
        : ZapretStage.failed;
    state = state.copyWith(
      busy: false,
      stage: nextStage,
      clearRuntimeSession: true,
      statusMessage: exitCode == 0
          ? state.tunConflictActive
                ? 'Gorion Boost остановлен, потому что активен TUN-режим.'
                : 'Gorion Boost остановлен.'
          : null,
      clearStatusMessage: exitCode != 0,
      errorMessage: exitCode == 0 ? null : _describeExitCode(exitCode),
      clearErrorMessage: exitCode == 0,
      logs: _runtimeService.logs,
    );
  }

  String _describeExitCode(int exitCode) {
    if (exitCode == 87) {
      return 'Gorion Boost отклонил параметры запуска (код 87 / ERROR_INVALID_PARAMETER). Значит, winws не принял один из аргументов текущего конфига.';
    }
    if (exitCode == -1073741502) {
      return 'Gorion Boost не смог инициализироваться (код -1073741502 / 0xC0000142). Обычно это сбой инициализации DLL или процесса; сначала попробуйте запустить Gorion от имени администратора.';
    }

    final hexSuffix = exitCode < 0
        ? ' (${_formatWindowsExitCode(exitCode)})'
        : '';
    return 'Gorion Boost завершился с кодом $exitCode$hexSuffix.';
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
      final availableConfigs = _runtimeService.listAvailableProfiles(
        settings.normalizedInstallDirectory,
      );
      final configuration = _tryBuildPreview(settings);
      state = state.copyWith(
        bootstrapping: false,
        settings: settings,
        availableConfigs: availableConfigs,
        generatedConfigPreview: configuration?.preview,
        generatedConfigSummary: configuration?.summary,
        clearStatusMessage: true,
        clearErrorMessage: true,
        logs: _runtimeService.logs,
      );
    } on Object catch (error) {
      state = state.copyWith(
        bootstrapping: false,
        settings: const ZapretSettings(),
        availableConfigs: const [],
        errorMessage: _describeError(error),
        clearStatusMessage: true,
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
      final normalizedStored = _normalizeSettingsModel(stored);
      final availableConfigs = _runtimeService.listAvailableProfiles(
        normalizedStored.normalizedInstallDirectory,
      );
      final configuration = _tryBuildPreview(normalizedStored);
      state = state.copyWith(
        busy: false,
        settings: normalizedStored,
        availableConfigs: availableConfigs,
        generatedConfigPreview: configuration?.preview,
        clearGeneratedConfigPreview: configuration == null,
        generatedConfigSummary: configuration?.summary,
        clearGeneratedConfigSummary: configuration == null,
        statusMessage: 'Настройки Gorion Boost сохранены.',
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
      state = state.copyWith(
        settings: hydrated,
        availableConfigs: _runtimeService.listAvailableProfiles(
          hydrated.normalizedInstallDirectory,
        ),
      );
    }
    return hydrated;
  }

  ZapretSettings _normalizeSettingsModel(ZapretSettings settings) {
    if (!settings.hasInstallDirectory) {
      return settings.copyWith(
        configFileName: settings.effectiveConfigFileName,
      );
    }

    final resolvedConfigFileName = _runtimeService
        .resolveSelectedConfigFileName(
          settings.normalizedInstallDirectory,
          settings.effectiveConfigFileName,
        );
    return settings.copyWith(configFileName: resolvedConfigFileName);
  }

  String _describeError(Object error) {
    if (error is ProcessException && isProcessElevationRequired(error)) {
      return 'Запуск winws требует прав администратора. Перезапустите Gorion от имени администратора и попробуйте снова.';
    }
    return error.toString();
  }

  ZapretLaunchConfiguration? _tryBuildPreview(ZapretSettings settings) {
    if (!settings.hasInstallDirectory) {
      return null;
    }

    try {
      return _runtimeService.buildPreview(settings);
    } on Object {
      return null;
    }
  }

  Future<bool> _maybeRelaunchForElevation({
    PendingElevatedLaunchAction action =
        PendingElevatedLaunchAction.startZapret,
    String successMessage =
        'Запрошены права администратора. После подтверждения UAC Gorion перезапустится и продолжит запуск Gorion Boost.',
    String cancelledMessage =
        'Запрос прав администратора был отменён. Gorion Boost не запущен.',
    String failureMessagePrefix =
        'Не удалось запросить права администратора для Gorion Boost',
  }) async {
    if (!Platform.isWindows) {
      return false;
    }
    if (await _runtimeService.canLaunchWithEmbeddedPrivilegeBroker()) {
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
      action: action,
    );
    if (!confirmed) {
      state = state.copyWith(
        statusMessage: action == PendingElevatedLaunchAction.testZapretConfigs
            ? 'Тестирование конфигов Boost отменено.'
            : 'Запуск Gorion Boost отменён.',
        clearErrorMessage: true,
      );
      return true;
    }

    try {
      await _elevationService.relaunchAsAdministrator(action: action);
      state = state.copyWith(
        statusMessage: successMessage,
        clearErrorMessage: true,
      );
    } on ElevationRequestCancelledException {
      state = state.copyWith(
        errorMessage: cancelledMessage,
        clearStatusMessage: true,
      );
    } on Object catch (error) {
      state = state.copyWith(
        errorMessage: '$failureMessagePrefix: $error',
        clearStatusMessage: true,
      );
    }

    return true;
  }
}
