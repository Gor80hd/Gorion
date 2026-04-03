import 'dart:convert';
import 'dart:io';

import 'package:gorion_clean/features/auto_select/model/auto_select_state.dart';
import 'package:gorion_clean/features/auto_select/utils/auto_select_server_exclusion.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class AutoSelectSettingsRepository {
  AutoSelectSettingsRepository({
    Future<Directory> Function()? storageRootLoader,
  }) : _storageRootLoader = storageRootLoader ?? _defaultStorageRoot;

  final Future<Directory> Function() _storageRootLoader;

  Future<StoredAutoSelectState> loadState() async {
    final stateFile = await _stateFile();
    if (!await stateFile.exists()) {
      return const StoredAutoSelectState();
    }

    final content = await stateFile.readAsString();
    if (content.trim().isEmpty) {
      return const StoredAutoSelectState();
    }

    final decoded = jsonDecode(content);
    if (decoded is Map<String, dynamic>) {
      return StoredAutoSelectState.fromJson(decoded);
    }
    if (decoded is Map) {
      return StoredAutoSelectState.fromJson(
        Map<String, dynamic>.from(decoded.cast<String, dynamic>()),
      );
    }
    return const StoredAutoSelectState();
  }

  Future<StoredAutoSelectState> saveSettings(
    AutoSelectSettings settings,
  ) async {
    final current = await loadState();
    final next = current.copyWith(settings: settings);
    await _writeState(next);
    return next;
  }

  Future<StoredAutoSelectState> updateExcludedServer({
    required String profileId,
    required String serverTag,
    required bool excluded,
  }) async {
    final current = await loadState();
    final exclusionKeys = {...current.settings.excludedServerKeys};
    final key = buildAutoSelectServerExclusionKey(
      profileId: profileId,
      serverTag: serverTag,
    );

    if (excluded) {
      exclusionKeys.add(key);
    } else {
      exclusionKeys.remove(key);
    }

    return saveSettings(
      current.settings.copyWith(
        excludedServerKeys: exclusionKeys.toList(growable: false),
      ),
    );
  }

  Future<StoredAutoSelectState> setRecentAutoSelectedServer({
    required String profileId,
    required String serverTag,
    Duration ttl = defaultRecentAutoSelectedServerTtl,
  }) async {
    final current = await loadState();
    final next = current.copyWith(
      recentAutoSelectedServer: RecentAutoSelectedServer(
        profileId: profileId,
        tag: serverTag,
        until: DateTime.now().add(ttl),
      ),
    );
    await _writeState(next);
    return next;
  }

  Future<StoredAutoSelectState> clearRecentAutoSelectedServer() async {
    final current = await loadState();
    final next = current.copyWith(clearRecentAutoSelectedServer: true);
    await _writeState(next);
    return next;
  }

  Future<StoredAutoSelectState> setRecentSuccessfulAutoConnect({
    required String profileId,
    required String serverTag,
    Duration ttl = defaultRecentSuccessfulAutoConnectTtl,
  }) async {
    final current = await loadState();
    final next = current.copyWith(
      recentSuccessfulAutoConnect: RecentSuccessfulAutoConnect(
        profileId: profileId,
        tag: serverTag,
        until: DateTime.now().add(ttl),
      ),
    );
    await _writeState(next);
    return next;
  }

  Future<StoredAutoSelectState> clearRecentSuccessfulAutoConnect() async {
    final current = await loadState();
    final next = current.copyWith(clearRecentSuccessfulAutoConnect: true);
    await _writeState(next);
    return next;
  }

  Future<StoredAutoSelectState> clearExpiredCaches() async {
    final current = await loadState();
    final next = current.copyWith(
      clearRecentAutoSelectedServer:
          !(current.recentAutoSelectedServer?.isActive ?? false),
      clearRecentSuccessfulAutoConnect:
          !(current.recentSuccessfulAutoConnect?.isActive ?? false),
    );
    if (next.toString() == current.toString()) {
      return current;
    }
    await _writeState(next);
    return next;
  }

  Future<File> _stateFile() async {
    final root = await _storageRootLoader();
    return File(p.join(root.path, 'auto-select.json'));
  }

  Future<void> _writeState(StoredAutoSelectState state) async {
    final stateFile = await _stateFile();
    await stateFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(state.toJson()),
    );
  }

  static Future<Directory> _defaultStorageRoot() async {
    final appDir = await getApplicationSupportDirectory();
    final root = Directory(p.join(appDir.path, 'gorion'));
    if (!await root.exists()) {
      await root.create(recursive: true);
    }
    return root;
  }
}
