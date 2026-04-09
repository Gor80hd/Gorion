import 'dart:io';

import 'package:flutter/services.dart';
import 'package:gorion_clean/core/constants/zapret_assets.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

Future<Directory> prepareZapretBundle() async {
  final descriptor = resolveZapretAsset();
  final runtimeRoot = await _ensureZapretRuntimeRoot();
  final bundleDir = Directory(p.join(runtimeRoot.path, descriptor.bundleKey));
  final executableFile = File(
    p.joinAll([
      bundleDir.path,
      ...descriptor.relativeExecutablePath.split('/'),
    ]),
  );
  final markerFile = File(p.join(bundleDir.path, 'zapret.version'));
  final expectedMarker = '$zapretVersion:${descriptor.bundleKey}';

  if (await executableFile.exists() && await markerFile.exists()) {
    final marker = await markerFile.readAsString();
    if (marker.trim() == expectedMarker) {
      return bundleDir;
    }
  }

  if (await bundleDir.exists()) {
    await bundleDir.delete(recursive: true);
  }
  await bundleDir.create(recursive: true);

  var extractedAssets = 0;
  for (final prefix in descriptor.assetPrefixes) {
    final assetPaths = await _listAssetPaths(prefix);
    for (final assetPath in assetPaths) {
      final relativePath = assetPath.substring(prefix.length);
      if (relativePath.isEmpty) {
        continue;
      }

      final outputFile = File(
        p.joinAll([bundleDir.path, ...relativePath.split('/')]),
      );
      await outputFile.parent.create(recursive: true);
      final assetData = await rootBundle.load(assetPath);
      await outputFile.writeAsBytes(
        assetData.buffer.asUint8List(),
        flush: true,
      );
      extractedAssets += 1;
    }
  }

  if (extractedAssets == 0) {
    throw StateError(
      'Vendored zapret assets were not found in the app bundle.',
    );
  }

  await markerFile.writeAsString(expectedMarker, flush: true);
  return bundleDir;
}

Future<Directory> _ensureZapretRuntimeRoot() async {
  final supportDir = await getApplicationSupportDirectory();
  final runtimeDir = Directory(
    p.join(supportDir.path, 'gorion', 'runtime', 'zapret2'),
  );
  if (!await runtimeDir.exists()) {
    await runtimeDir.create(recursive: true);
  }
  return runtimeDir;
}

Future<List<String>> _listAssetPaths(String prefix) async {
  try {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final assets =
        manifest.listAssets().where((key) => key.startsWith(prefix)).toList()
          ..sort();
    return assets;
  } on Object {
    return const <String>[];
  }
}
