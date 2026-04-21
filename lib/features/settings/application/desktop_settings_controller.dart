import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gorion_clean/features/settings/data/desktop_settings_repository.dart';
import 'package:gorion_clean/features/settings/data/launch_at_startup_service.dart';
import 'package:gorion_clean/features/settings/model/desktop_settings.dart';

final desktopSettingsRepositoryProvider = Provider<DesktopSettingsRepository>(
  (ref) => DesktopSettingsRepository(),
);

final launchAtStartupServiceProvider = Provider<LaunchAtStartupService>(
  (ref) => const NoopLaunchAtStartupService(),
);

final desktopSettingsBootstrapProvider = Provider<DesktopSettingsState>(
  (ref) => const DesktopSettingsState(),
);

final desktopSettingsControllerProvider =
    StateNotifierProvider<DesktopSettingsController, DesktopSettingsState>(
      (ref) => DesktopSettingsController(
        repository: ref.read(desktopSettingsRepositoryProvider),
        launchAtStartupService: ref.read(launchAtStartupServiceProvider),
        initialState: ref.read(desktopSettingsBootstrapProvider),
      ),
    );

class DesktopSettingsState {
  const DesktopSettingsState({
    this.busy = false,
    this.settings = const DesktopSettings(),
    this.launchAtStartupEnabled = false,
    this.errorMessage,
  });

  final bool busy;
  final DesktopSettings settings;
  final bool launchAtStartupEnabled;
  final String? errorMessage;

  bool get canLaunchMinimized => launchAtStartupEnabled;

  bool get effectiveLaunchMinimized =>
      canLaunchMinimized && settings.launchMinimized;

  DesktopSettingsState copyWith({
    bool? busy,
    DesktopSettings? settings,
    bool? launchAtStartupEnabled,
    String? errorMessage,
    bool clearErrorMessage = false,
  }) {
    return DesktopSettingsState(
      busy: busy ?? this.busy,
      settings: settings ?? this.settings,
      launchAtStartupEnabled:
          launchAtStartupEnabled ?? this.launchAtStartupEnabled,
      errorMessage: clearErrorMessage
          ? null
          : errorMessage ?? this.errorMessage,
    );
  }
}

Future<DesktopSettingsState> loadDesktopSettingsBootstrap({
  DesktopSettingsRepository? repository,
  LaunchAtStartupService? launchAtStartupService,
}) async {
  final effectiveRepository = repository ?? DesktopSettingsRepository();
  final effectiveLaunchAtStartupService =
      launchAtStartupService ?? const NoopLaunchAtStartupService();

  DesktopSettings settings;
  try {
    settings = await effectiveRepository.load();
  } on Object {
    settings = const DesktopSettings();
  }

  var launchAtStartupEnabled = false;
  try {
    launchAtStartupEnabled = await effectiveLaunchAtStartupService.isEnabled();
  } on Object {
    launchAtStartupEnabled = false;
  }
  if (launchAtStartupEnabled) {
    try {
      settings = settings.copyWith(
        launchAtStartupPriority: await effectiveLaunchAtStartupService
            .getPriority(),
      );
    } on Object {
      settings = settings.copyWith(
        launchAtStartupPriority: settings.launchAtStartupPriority,
      );
    }
  }

  return DesktopSettingsState(
    settings: settings,
    launchAtStartupEnabled: launchAtStartupEnabled,
  );
}

class DesktopSettingsController extends StateNotifier<DesktopSettingsState> {
  DesktopSettingsController({
    required DesktopSettingsRepository repository,
    required LaunchAtStartupService launchAtStartupService,
    DesktopSettingsState initialState = const DesktopSettingsState(),
  }) : _repository = repository,
       _launchAtStartupService = launchAtStartupService,
       super(initialState);

  final DesktopSettingsRepository _repository;
  final LaunchAtStartupService _launchAtStartupService;

  Future<void> setLaunchAtStartupEnabled(bool enabled) async {
    if (state.busy || state.launchAtStartupEnabled == enabled) {
      return;
    }

    final previousState = state;
    state = state.copyWith(busy: true, clearErrorMessage: true);
    var nextSettings = previousState.settings;
    var nextLaunchAtStartupEnabled = previousState.launchAtStartupEnabled;
    try {
      final updated = await _launchAtStartupService.setEnabled(
        enabled,
        priority: previousState.settings.launchAtStartupPriority,
      );
      if (!updated) {
        throw StateError('Не удалось обновить автозапуск Windows.');
      }
      nextLaunchAtStartupEnabled = enabled;
      if (!enabled && nextSettings.launchMinimized) {
        nextSettings = await _repository.save(
          nextSettings.copyWith(launchMinimized: false),
        );
      }
      state = previousState.copyWith(
        busy: false,
        settings: nextSettings,
        launchAtStartupEnabled: nextLaunchAtStartupEnabled,
        clearErrorMessage: true,
      );
    } on Object catch (error) {
      state = previousState.copyWith(
        busy: false,
        settings: nextSettings,
        launchAtStartupEnabled: nextLaunchAtStartupEnabled,
        errorMessage: error.toString(),
      );
    }
  }

  Future<void> setLaunchMinimized(bool enabled) async {
    final nextEnabled = enabled && state.launchAtStartupEnabled;
    await _saveSettings(state.settings.copyWith(launchMinimized: nextEnabled));
  }

  Future<void> setLaunchAtStartupPriority(
    LaunchAtStartupPriority priority,
  ) async {
    if (state.busy || state.settings.launchAtStartupPriority == priority) {
      return;
    }

    final previousState = state;
    state = state.copyWith(busy: true, clearErrorMessage: true);
    try {
      if (previousState.launchAtStartupEnabled) {
        final updated = await _launchAtStartupService.setEnabled(
          true,
          priority: priority,
        );
        if (!updated) {
          throw StateError(
            'Не удалось обновить приоритет автозагрузки Windows.',
          );
        }
      }

      final settings = await _repository.save(
        previousState.settings.copyWith(launchAtStartupPriority: priority),
      );
      state = previousState.copyWith(
        busy: false,
        settings: settings,
        clearErrorMessage: true,
      );
    } on Object catch (error) {
      state = previousState.copyWith(
        busy: false,
        errorMessage: error.toString(),
      );
    }
  }

  Future<void> setKeepRunningInTrayOnClose(bool enabled) async {
    await _saveSettings(
      state.settings.copyWith(keepRunningInTrayOnClose: enabled),
    );
  }

  Future<void> setAutoConnectOnLaunch(bool enabled) async {
    await _saveSettings(state.settings.copyWith(autoConnectOnLaunch: enabled));
  }

  Future<void> reload() async {
    if (state.busy) {
      return;
    }

    state = state.copyWith(busy: true, clearErrorMessage: true);
    try {
      final settingsFuture = _repository.load();
      final launchAtStartupEnabledFuture = _launchAtStartupService.isEnabled();
      final settings = await settingsFuture;
      final launchAtStartupEnabled = await launchAtStartupEnabledFuture;
      var effectiveSettings = settings;
      if (launchAtStartupEnabled) {
        try {
          effectiveSettings = settings.copyWith(
            launchAtStartupPriority: await _launchAtStartupService
                .getPriority(),
          );
        } on Object {
          effectiveSettings = settings;
        }
      }
      state = state.copyWith(
        busy: false,
        settings: effectiveSettings,
        launchAtStartupEnabled: launchAtStartupEnabled,
      );
    } on Object catch (error) {
      state = state.copyWith(busy: false, errorMessage: error.toString());
    }
  }

  Future<void> _saveSettings(DesktopSettings nextSettings) async {
    if (state.busy || state.settings == nextSettings) {
      return;
    }

    state = state.copyWith(busy: true, clearErrorMessage: true);
    try {
      final stored = await _repository.save(nextSettings);
      state = state.copyWith(busy: false, settings: stored);
    } on Object catch (error) {
      state = state.copyWith(busy: false, errorMessage: error.toString());
    }
  }
}
