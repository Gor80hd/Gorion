import 'dart:convert';
import 'dart:io';

import 'package:gorion_clean/features/settings/model/desktop_settings.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class DesktopSettingsRepository {
  DesktopSettingsRepository({
    Future<Directory> Function()? storageRootLoader,
  }) : _storageRootLoader = storageRootLoader ?? _defaultStorageRoot;

  final Future<Directory> Function() _storageRootLoader;

  Future<DesktopSettings> load() async {
    final stateFile = await _stateFile();
    if (!await stateFile.exists()) {
      return const DesktopSettings();
    }

    final content = await stateFile.readAsString();
    if (content.trim().isEmpty) {
      return const DesktopSettings();
    }

    final decoded = jsonDecode(content);
    if (decoded is Map<String, dynamic>) {
      return DesktopSettings.fromJson(decoded);
    }
    if (decoded is Map) {
      return DesktopSettings.fromJson(
        Map<String, dynamic>.from(decoded.cast<String, dynamic>()),
      );
    }
    return const DesktopSettings();
  }

  Future<DesktopSettings> save(DesktopSettings settings) async {
    final normalized = settings.copyWith();
    final stateFile = await _stateFile();
    await stateFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(normalized.toJson()),
      flush: true,
    );
    return normalized;
  }

  Future<File> _stateFile() async {
    final root = await _storageRootLoader();
    return File(p.join(root.path, 'desktop-settings.json'));
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