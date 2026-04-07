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

    state = state.copyWith(busy: true, clearErrorMessage: true);
    try {
      final updated = await _launchAtStartupService.setEnabled(enabled);
      if (!updated) {
        throw StateError('Не удалось обновить автозапуск Windows.');
      }
      state = state.copyWith(busy: false, launchAtStartupEnabled: enabled);
    } on Object catch (error) {
      state = state.copyWith(busy: false, errorMessage: error.toString());
    }
  }

  Future<void> setLaunchMinimized(bool enabled) async {
    await _saveSettings(state.settings.copyWith(launchMinimized: enabled));
  }

  Future<void> setKeepRunningInTrayOnClose(bool enabled) async {
    await _saveSettings(
      state.settings.copyWith(keepRunningInTrayOnClose: enabled),
    );
  }

  Future<void> setAutoConnectOnLaunch(bool enabled) async {
    await _saveSettings(state.settings.copyWith(autoConnectOnLaunch: enabled));
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
