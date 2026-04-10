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
      await ensureBundledSupportLayout(bundleDir.path);
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

  await ensureLegacyBatchCompatibilityLayout(
    bundleDir: bundleDir,
    relativeExecutablePath: descriptor.relativeExecutablePath,
  );
  await ensureBundledSupportLayout(bundleDir.path);
  await markerFile.writeAsString(expectedMarker, flush: true);
  return bundleDir;
}

Future<void> ensureBundledProfileConfigs(String installDirectory) async {
  final normalizedRoot = installDirectory.trim();
  if (normalizedRoot.isEmpty) {
    return;
  }

  final profilesDir = Directory(p.join(normalizedRoot, 'profiles'));
  await profilesDir.create(recursive: true);

  const profilePrefix = 'assets/zapret/profiles/';
  final assetPaths = await _listAssetPaths(profilePrefix);
  for (final assetPath in assetPaths) {
    final relativePath = assetPath.substring(profilePrefix.length);
    if (relativePath.isEmpty) {
      continue;
    }

    final outputFile = File(
      p.joinAll([profilesDir.path, ...relativePath.split('/')]),
    );
    await outputFile.parent.create(recursive: true);
    final assetData = await rootBundle.load(assetPath);
    await outputFile.writeAsBytes(assetData.buffer.asUint8List(), flush: true);
  }
}

Future<void> ensureBundledSupportLayout(String installDirectory) async {
  final normalizedRoot = installDirectory.trim();
  if (normalizedRoot.isEmpty) {
    return;
  }

  await _copyAssetPrefixIfMissing(
    assetPrefix: 'assets/zapret/profiles/',
    outputRoot: p.join(normalizedRoot, 'profiles'),
  );
  await _copyAssetPrefixIfMissing(
    assetPrefix: 'assets/zapret/common/files/',
    outputRoot: p.join(normalizedRoot, 'files'),
  );
  await _copyAssetPrefixIfMissing(
    assetPrefix: 'assets/zapret/common/lua/',
    outputRoot: p.join(normalizedRoot, 'lua'),
  );
}

Future<void> ensureLegacyBatchCompatibilityLayout({
  required Directory bundleDir,
  required String relativeExecutablePath,
}) async {
  final legacyBinDir = Directory(p.join(bundleDir.path, 'bin'));
  final legacyListsDir = Directory(p.join(bundleDir.path, 'lists'));
  await legacyBinDir.create(recursive: true);
  await legacyListsDir.create(recursive: true);

  final sourceExecutable = File(
    p.joinAll([bundleDir.path, ...relativeExecutablePath.split('/')]),
  );
  final sourceBinaryDir = sourceExecutable.parent;
  if (await sourceBinaryDir.exists()) {
    await for (final entity in sourceBinaryDir.list(followLinks: false)) {
      if (entity is! File) {
        continue;
      }

      await _copyFile(
        entity,
        p.join(legacyBinDir.path, p.basename(entity.path)),
      );
    }
  }

  if (await sourceExecutable.exists()) {
    await _copyFile(sourceExecutable, p.join(legacyBinDir.path, 'winws.exe'));
  }

  final fakeDirectory = Directory(p.join(bundleDir.path, 'files', 'fake'));
  if (await fakeDirectory.exists()) {
    await for (final entity in fakeDirectory.list(followLinks: false)) {
      if (entity is! File) {
        continue;
      }

      await _copyFile(
        entity,
        p.join(legacyBinDir.path, p.basename(entity.path)),
      );
    }
  }

  final sourceListsDir = Directory(p.join(bundleDir.path, 'files'));
  if (await sourceListsDir.exists()) {
    await for (final entity in sourceListsDir.list(followLinks: false)) {
      if (entity is! File || p.extension(entity.path).toLowerCase() != '.txt') {
        continue;
      }

      await _copyFile(
        entity,
        p.join(legacyListsDir.path, p.basename(entity.path)),
      );
    }
  }
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

Future<void> _copyAssetPrefixIfMissing({
  required String assetPrefix,
  required String outputRoot,
}) async {
  final assetPaths = await _listAssetPaths(assetPrefix);
  for (final assetPath in assetPaths) {
    final relativePath = assetPath.substring(assetPrefix.length);
    if (relativePath.isEmpty) {
      continue;
    }

    final outputFile = File(
      p.joinAll([outputRoot, ...relativePath.split('/')]),
    );
    if (await outputFile.exists()) {
      continue;
    }

    await outputFile.parent.create(recursive: true);
    final assetData = await rootBundle.load(assetPath);
    await outputFile.writeAsBytes(assetData.buffer.asUint8List(), flush: true);
  }
}

Future<void> _copyFile(File source, String destinationPath) async {
  final destination = File(destinationPath);
  await destination.parent.create(recursive: true);
  if (await destination.exists()) {
    await destination.delete();
  }
  await source.copy(destination.path);
}
