import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class ServerFavoritesRepository {
  ServerFavoritesRepository({Future<Directory> Function()? storageRootLoader})
    : _storageRootLoader = storageRootLoader ?? _defaultStorageRoot;

  final Future<Directory> Function() _storageRootLoader;

  Future<Set<String>> load() async {
    final stateFile = await _stateFile();
    if (!await stateFile.exists()) {
      return const <String>{};
    }

    final content = await stateFile.readAsString();
    if (content.trim().isEmpty) {
      return const <String>{};
    }

    try {
      final decoded = jsonDecode(content);
      final keys = switch (decoded) {
        {'favoriteServerKeys': final List values} => values,
        {'keys': final List values} => values,
        final List values => values,
        _ => const <Object?>[],
      };
      return keys
          .map((item) => item.toString())
          .where((item) => item.isNotEmpty)
          .toSet();
    } catch (_) {
      return const <String>{};
    }
  }

  Future<Set<String>> save(Set<String> keys) async {
    final stateFile = await _stateFile();
    final sortedKeys = keys.toList(growable: false)..sort();
    await stateFile.writeAsString(
      const JsonEncoder.withIndent(
        '  ',
      ).convert({'favoriteServerKeys': sortedKeys}),
    );
    return sortedKeys.toSet();
  }

  Future<File> _stateFile() async {
    final root = await _storageRootLoader();
    return File(p.join(root.path, 'server-favorites.json'));
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
