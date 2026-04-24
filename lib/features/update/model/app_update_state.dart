import 'package:gorion_clean/features/update/model/app_version.dart';

enum AppUpdateStatus { idle, checking, upToDate, updateAvailable, failure }

class GithubRelease {
  const GithubRelease({
    required this.tagName,
    this.name,
    this.htmlUrl,
    this.publishedAt,
  });

  factory GithubRelease.fromJson(Map<String, dynamic> json) {
    final tagName = _readString(json, 'tag_name');
    if (tagName == null) {
      throw const FormatException('GitHub release response has no tag_name.');
    }

    return GithubRelease(
      tagName: tagName,
      name: _readString(json, 'name'),
      htmlUrl: _readString(json, 'html_url'),
      publishedAt: DateTime.tryParse(_readString(json, 'published_at') ?? ''),
    );
  }

  final String tagName;
  final String? name;
  final String? htmlUrl;
  final DateTime? publishedAt;

  String get versionLabel => normalizeAppVersionLabel(tagName) ?? tagName;
}

class AppUpdateInfo {
  const AppUpdateInfo({
    required this.currentVersion,
    required this.latestVersion,
    required this.tagName,
    this.releaseName,
    this.releaseUrl,
    this.publishedAt,
  });

  final String currentVersion;
  final String latestVersion;
  final String tagName;
  final String? releaseName;
  final String? releaseUrl;
  final DateTime? publishedAt;
}

class AppUpdateState {
  const AppUpdateState({
    this.status = AppUpdateStatus.idle,
    this.currentVersion,
    this.update,
    this.errorMessage,
    this.bannerDismissed = false,
  });

  final AppUpdateStatus status;
  final String? currentVersion;
  final AppUpdateInfo? update;
  final String? errorMessage;
  final bool bannerDismissed;

  bool get busy => status == AppUpdateStatus.checking;

  bool get hasChecked =>
      status == AppUpdateStatus.upToDate ||
      status == AppUpdateStatus.updateAvailable ||
      status == AppUpdateStatus.failure;

  bool get hasAvailableUpdate =>
      status == AppUpdateStatus.updateAvailable && update != null;

  AppUpdateInfo? get availableUpdate => hasAvailableUpdate ? update : null;

  AppUpdateState copyWith({
    AppUpdateStatus? status,
    String? currentVersion,
    AppUpdateInfo? update,
    String? errorMessage,
    bool? bannerDismissed,
    bool clearUpdate = false,
    bool clearErrorMessage = false,
  }) {
    return AppUpdateState(
      status: status ?? this.status,
      currentVersion: currentVersion ?? this.currentVersion,
      update: clearUpdate ? null : update ?? this.update,
      errorMessage: clearErrorMessage
          ? null
          : errorMessage ?? this.errorMessage,
      bannerDismissed: bannerDismissed ?? this.bannerDismissed,
    );
  }
}

String? _readString(Map<String, dynamic> json, String key) {
  final value = json[key]?.toString().trim();
  if (value == null || value.isEmpty || value.toLowerCase() == 'null') {
    return null;
  }
  return value;
}
