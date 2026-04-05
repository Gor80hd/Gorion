import 'dart:convert';
import 'dart:io';

import 'package:gorion_clean/features/home/model/server_sort_mode.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class ServerSortModeSettingsRepository {
  ServerSortModeSettingsRepository({
    Future<Directory> Function()? storageRootLoader,
  }) : _storageRootLoader = storageRootLoader ?? _defaultStorageRoot;

  final Future<Directory> Function() _storageRootLoader;

  Future<ServerSortMode> load() async {
    final stateFile = await _stateFile();
    if (!await stateFile.exists()) {
      return ServerSortMode.speed;
    }

    final content = await stateFile.readAsString();
    if (content.trim().isEmpty) {
      return ServerSortMode.speed;
    }

    try {
      final decoded = jsonDecode(content);
      if (decoded is Map<String, dynamic>) {
        return ServerSortModeStorage.fromStorageValue(
          decoded['sortMode']?.toString(),
        );
      }
      if (decoded is Map) {
        final json = Map<String, dynamic>.from(decoded.cast<String, dynamic>());
        return ServerSortModeStorage.fromStorageValue(
          json['sortMode']?.toString(),
        );
      }
    } catch (_) {
      return ServerSortMode.speed;
    }
    return ServerSortMode.speed;
  }

  Future<ServerSortMode> save(ServerSortMode mode) async {
    final stateFile = await _stateFile();
    await stateFile.writeAsString(
      const JsonEncoder.withIndent(
        '  ',
      ).convert({'sortMode': mode.storageValue}),
    );
    return mode;
  }

  Future<File> _stateFile() async {
    final root = await _storageRootLoader();
    return File(p.join(root.path, 'server-sort-mode.json'));
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
