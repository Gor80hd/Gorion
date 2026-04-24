import 'package:flutter_test/flutter_test.dart';
import 'package:gorion_clean/features/update/application/app_update_controller.dart';
import 'package:gorion_clean/features/update/data/github_release_repository.dart';
import 'package:gorion_clean/features/update/model/app_update_state.dart';

void main() {
  test('reports update when GitHub release is newer', () async {
    final controller = AppUpdateController(
      repository: _FakeAppUpdateRepository(
        release: const GithubRelease(
          tagName: 'v1.6.0',
          name: 'Gorion 1.6.0',
          htmlUrl: 'https://github.com/Gor80hd/Gorion/releases/tag/v1.6.0',
        ),
      ),
      currentVersionLoader: () async => '1.5.0',
    );
    addTearDown(controller.dispose);

    await controller.checkForUpdates();

    expect(controller.state.status, AppUpdateStatus.updateAvailable);
    expect(controller.state.availableUpdate?.latestVersion, '1.6.0');
    expect(controller.state.availableUpdate?.currentVersion, '1.5.0');
    expect(controller.state.bannerDismissed, isFalse);
  });

  test('keeps state up to date when release matches current version', () async {
    final controller = AppUpdateController(
      repository: _FakeAppUpdateRepository(
        release: const GithubRelease(tagName: 'v1.5.0'),
      ),
      currentVersionLoader: () async => '1.5.0+8',
    );
    addTearDown(controller.dispose);

    await controller.checkForUpdates();

    expect(controller.state.status, AppUpdateStatus.upToDate);
    expect(controller.state.availableUpdate, isNull);
    expect(controller.state.currentVersion, '1.5.0');
  });

  test('dismisses available update banner for the current session', () async {
    final controller = AppUpdateController(
      repository: _FakeAppUpdateRepository(
        release: const GithubRelease(tagName: 'v1.6.0'),
      ),
      currentVersionLoader: () async => '1.5.0',
    );
    addTearDown(controller.dispose);

    await controller.checkForUpdates();
    controller.dismissBanner();

    expect(controller.state.hasAvailableUpdate, isTrue);
    expect(controller.state.bannerDismissed, isTrue);
  });

  test('force check shows the update banner again', () async {
    final controller = AppUpdateController(
      repository: _FakeAppUpdateRepository(
        release: const GithubRelease(tagName: 'v1.6.0'),
      ),
      currentVersionLoader: () async => '1.5.0',
    );
    addTearDown(controller.dispose);

    await controller.checkForUpdates();
    controller.dismissBanner();
    await controller.checkForUpdates(force: true);

    expect(controller.state.hasAvailableUpdate, isTrue);
    expect(controller.state.bannerDismissed, isFalse);
  });
}

class _FakeAppUpdateRepository implements AppUpdateRepository {
  const _FakeAppUpdateRepository({required this.release});

  final GithubRelease release;

  @override
  Future<GithubRelease> fetchLatestRelease() async => release;
}
