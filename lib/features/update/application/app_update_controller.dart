import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gorion_clean/core/http_client/http_client_provider.dart';
import 'package:gorion_clean/features/update/data/github_release_repository.dart';
import 'package:gorion_clean/features/update/model/app_update_state.dart';
import 'package:gorion_clean/features/update/model/app_version.dart';
import 'package:package_info_plus/package_info_plus.dart';

typedef CurrentAppVersionLoader = Future<String> Function();

final currentAppVersionLoaderProvider = Provider<CurrentAppVersionLoader>(
  (ref) => () async {
    final packageInfo = await PackageInfo.fromPlatform();
    return packageInfo.version;
  },
);

final appUpdateRepositoryProvider = Provider<AppUpdateRepository>((ref) {
  return GithubReleaseRepository(
    userAgent: ref.watch(httpClientProvider).userAgent,
  );
});

final appUpdateControllerProvider =
    StateNotifierProvider<AppUpdateController, AppUpdateState>((ref) {
      return AppUpdateController(
        repository: ref.read(appUpdateRepositoryProvider),
        currentVersionLoader: ref.read(currentAppVersionLoaderProvider),
      );
    });

class AppUpdateController extends StateNotifier<AppUpdateState> {
  AppUpdateController({
    required AppUpdateRepository repository,
    required CurrentAppVersionLoader currentVersionLoader,
  }) : _repository = repository,
       _currentVersionLoader = currentVersionLoader,
       super(const AppUpdateState());

  final AppUpdateRepository _repository;
  final CurrentAppVersionLoader _currentVersionLoader;
  bool _alive = true;

  Future<void> checkForUpdates({bool force = false}) async {
    if (state.busy || (!force && state.hasChecked)) {
      return;
    }

    state = state.copyWith(
      status: AppUpdateStatus.checking,
      clearErrorMessage: true,
    );

    try {
      final currentVersionRaw = (await _currentVersionLoader()).trim();
      if (currentVersionRaw.isEmpty) {
        throw StateError('Current app version is unavailable.');
      }

      final release = await _repository.fetchLatestRelease();
      final currentVersion =
          normalizeAppVersionLabel(currentVersionRaw) ?? currentVersionRaw;
      final latestVersion = release.versionLabel;
      final currentParsed = AppVersion.tryParse(currentVersionRaw);
      final latestParsed = AppVersion.tryParse(release.tagName);
      final updateAvailable =
          currentParsed != null &&
          latestParsed != null &&
          latestParsed.compareTo(currentParsed) > 0;
      final dismissedForSameVersion =
          !force &&
          state.update?.latestVersion == latestVersion &&
          state.bannerDismissed;

      if (!_alive) {
        return;
      }

      state = AppUpdateState(
        status: updateAvailable
            ? AppUpdateStatus.updateAvailable
            : AppUpdateStatus.upToDate,
        currentVersion: currentVersion,
        update: updateAvailable
            ? AppUpdateInfo(
                currentVersion: currentVersion,
                latestVersion: latestVersion,
                tagName: release.tagName,
                releaseName: release.name,
                releaseUrl: release.htmlUrl,
                publishedAt: release.publishedAt,
              )
            : null,
        bannerDismissed: updateAvailable && dismissedForSameVersion,
      );
    } on Object catch (error) {
      if (!_alive) {
        return;
      }

      state = state.copyWith(
        status: AppUpdateStatus.failure,
        errorMessage: error.toString(),
        clearUpdate: true,
      );
    }
  }

  void dismissBanner() {
    if (!state.hasAvailableUpdate || state.bannerDismissed) {
      return;
    }

    state = state.copyWith(bannerDismissed: true);
  }

  @override
  void dispose() {
    _alive = false;
    super.dispose();
  }
}
