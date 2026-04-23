import 'dart:convert';
import 'dart:io';

import 'package:gorion_clean/features/profiles/data/profile_parser.dart';
import 'package:gorion_clean/features/profiles/model/profile_models.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

class ProfileRepository {
  ProfileRepository({
    ProfileParser? parser,
    Future<Directory> Function()? storageRootLoader,
  }) : _parser = parser ?? ProfileParser(),
       _storageRootLoader = storageRootLoader ?? _defaultStorageRoot;

  final ProfileParser _parser;
  final Future<Directory> Function() _storageRootLoader;
  final Uuid _uuid = const Uuid();

  Future<StoredProfilesState> loadState() async {
    final indexFile = await _indexFile();
    if (!await indexFile.exists()) {
      return const StoredProfilesState();
    }

    final content = await indexFile.readAsString();
    if (content.trim().isEmpty) {
      return const StoredProfilesState();
    }

    final decoded = jsonDecode(content);
    if (decoded is Map<String, dynamic>) {
      return StoredProfilesState.fromJson(decoded);
    }
    if (decoded is Map) {
      return StoredProfilesState.fromJson(
        Map<String, dynamic>.from(decoded.cast<String, dynamic>()),
      );
    }
    return const StoredProfilesState();
  }

  Future<StoredProfilesState> addRemoteSubscription(String url) async {
    final parsed = await _parser.fetchAndParse(url);
    final state = await loadState();
    final id = _uuid.v4();
    final templateFileName = '$id.json';
    final now = DateTime.now();
    final profile = ProxyProfile(
      id: id,
      name: parsed.name,
      subscriptionUrl: url.trim(),
      templateFileName: templateFileName,
      createdAt: now,
      updatedAt: now,
      servers: parsed.servers,
      subscriptionInfo: parsed.subscriptionInfo,
      lastSelectedServerTag: parsed.servers.first.tag,
      lastAutoSelectedServerTag: parsed.servers.first.tag,
    );

    await _writeTemplateFile(templateFileName, parsed.normalizedConfigJson);
    final next = StoredProfilesState(
      activeProfileId: state.activeProfileId ?? id,
      profiles: [profile, ...state.profiles],
    );
    await _writeState(next);
    return next;
  }

  Future<StoredProfilesState> refreshRemoteSubscription(
    String profileId,
  ) async {
    final state = await loadState();
    ProxyProfile? profile;
    for (final item in state.profiles) {
      if (item.id == profileId) {
        profile = item;
        break;
      }
    }
    if (profile == null) {
      throw ArgumentError.value(profileId, 'profileId', 'Profile not found.');
    }
    final currentProfile = profile;
    if (currentProfile.subscriptionUrl.trim().isEmpty) {
      throw const FormatException(
        'Only remote subscription profiles can be refreshed.',
      );
    }

    final parsed = await _parser.fetchAndParse(currentProfile.subscriptionUrl);
    final preservedSelection = currentProfile.prefersAutoSelection
        ? autoSelectServerTag
        : parsed.servers.any(
            (server) => server.tag == currentProfile.selectedServerTag,
          )
        ? currentProfile.selectedServerTag
        : parsed.servers.first.tag;
    final preservedAutoSelection =
        parsed.servers.any(
          (server) =>
              server.tag == currentProfile.resolvedAutoSelectedServerTag,
        )
        ? currentProfile.resolvedAutoSelectedServerTag
        : parsed.servers.first.tag;
    final updatedProfile = currentProfile.copyWith(
      name: parsed.name,
      updatedAt: DateTime.now(),
      servers: parsed.servers,
      subscriptionInfo: parsed.subscriptionInfo,
      lastSelectedServerTag: preservedSelection,
      lastAutoSelectedServerTag: preservedAutoSelection,
    );

    await _writeTemplateFile(
      currentProfile.templateFileName,
      parsed.normalizedConfigJson,
    );
    final profiles = [
      for (final item in state.profiles)
        if (item.id == profileId) updatedProfile else item,
    ];
    final next = state.copyWith(profiles: profiles);
    await _writeState(next);
    return next;
  }

  Future<StoredProfilesState> setActiveProfile(String profileId) async {
    final state = await loadState();
    final exists = state.profiles.any((profile) => profile.id == profileId);
    if (!exists) {
      throw ArgumentError.value(profileId, 'profileId', 'Profile not found.');
    }

    final next = state.copyWith(activeProfileId: profileId);
    await _writeState(next);
    return next;
  }

  Future<StoredProfilesState> updateSelectedServer(
    String profileId,
    String serverTag,
  ) async {
    final state = await loadState();
    final profiles = [
      for (final profile in state.profiles)
        if (profile.id == profileId)
          profile.copyWith(lastSelectedServerTag: serverTag)
        else
          profile,
    ];
    final next = state.copyWith(profiles: profiles);
    await _writeState(next);
    return next;
  }

  Future<StoredProfilesState> updateAutoSelectedServer(
    String profileId,
    String serverTag,
  ) async {
    final state = await loadState();
    final profiles = [
      for (final profile in state.profiles)
        if (profile.id == profileId)
          profile.copyWith(lastAutoSelectedServerTag: serverTag)
        else
          profile,
    ];
    final next = state.copyWith(profiles: profiles);
    await _writeState(next);
    return next;
  }

  Future<StoredProfilesState> removeProfile(String profileId) async {
    final state = await loadState();
    ProxyProfile? profile;
    for (final item in state.profiles) {
      if (item.id == profileId) {
        profile = item;
        break;
      }
    }
    if (profile == null) {
      throw ArgumentError.value(profileId, 'profileId', 'Profile not found.');
    }

    final profiles = [
      for (final item in state.profiles)
        if (item.id != profileId) item,
    ];

    final nextActiveProfileId = state.activeProfileId == profileId
        ? (profiles.isEmpty ? null : profiles.first.id)
        : state.activeProfileId;

    final next = StoredProfilesState(
      activeProfileId: nextActiveProfileId,
      profiles: profiles,
    );

    await _writeState(next);
    final templateFile = await _templateFile(profile.templateFileName);
    try {
      if (await templateFile.exists()) {
        await templateFile.delete();
      }
    } on FileSystemException {
      // The index is authoritative; an orphaned template is safer than a
      // profile that still points to a deleted config.
    }
    return next;
  }

  Future<String> loadTemplateConfig(ProxyProfile profile) async {
    final file = await _templateFile(profile.templateFileName);
    return file.readAsString();
  }

  Future<Directory> _storageRoot() async {
    return _storageRootLoader();
  }

  static Future<Directory> _defaultStorageRoot() async {
    final appDir = await getApplicationSupportDirectory();
    final root = Directory(p.join(appDir.path, 'gorion'));
    if (!await root.exists()) {
      await root.create(recursive: true);
    }
    return root;
  }

  Future<File> _indexFile() async {
    final root = await _storageRoot();
    return File(p.join(root.path, 'profiles.json'));
  }

  Future<File> _templateFile(String fileName) async {
    final root = await _storageRoot();
    final templateDir = Directory(p.join(root.path, 'profiles'));
    if (!await templateDir.exists()) {
      await templateDir.create(recursive: true);
    }
    return File(p.join(templateDir.path, fileName));
  }

  Future<void> _writeTemplateFile(String fileName, String content) async {
    final file = await _templateFile(fileName);
    await file.writeAsString(content);
  }

  Future<void> _writeState(StoredProfilesState state) async {
    final indexFile = await _indexFile();
    await indexFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(state.toJson()),
    );
  }
}
