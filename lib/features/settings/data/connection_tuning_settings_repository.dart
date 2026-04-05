import 'dart:convert';
import 'dart:io';

import 'package:gorion_clean/features/settings/model/connection_tuning_settings.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class ConnectionTuningSettingsRepository {
  ConnectionTuningSettingsRepository({
    Future<Directory> Function()? storageRootLoader,
  }) : _storageRootLoader = storageRootLoader ?? _defaultStorageRoot;

  final Future<Directory> Function() _storageRootLoader;

  Future<ConnectionTuningSettings> load() async {
    final stateFile = await _stateFile();
    if (!await stateFile.exists()) {
      return const ConnectionTuningSettings();
    }

    final content = await stateFile.readAsString();
    if (content.trim().isEmpty) {
      return const ConnectionTuningSettings();
    }

    final decoded = jsonDecode(content);
    if (decoded is Map<String, dynamic>) {
      return ConnectionTuningSettings.fromJson(decoded);
    }
    if (decoded is Map) {
      return ConnectionTuningSettings.fromJson(
        Map<String, dynamic>.from(decoded.cast<String, dynamic>()),
      );
    }
    return const ConnectionTuningSettings();
  }

  Future<ConnectionTuningSettings> save(
    ConnectionTuningSettings settings,
  ) async {
    final normalized = settings.copyWith();
    final stateFile = await _stateFile();
    await stateFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(normalized.toJson()),
    );
    return normalized;
  }

  Future<File> _stateFile() async {
    final root = await _storageRootLoader();
    return File(p.join(root.path, 'connection-settings.json'));
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
