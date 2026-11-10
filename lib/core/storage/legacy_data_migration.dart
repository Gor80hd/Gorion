import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// All app data lives in this folder inside the platform support directory.
const _dataFolderName = 'gorion';

/// Windows builds before the rename stored data under
/// `%APPDATA%\com.example\gorion_clean`. Moves it to the current support
/// directory once, so profiles and settings survive the upgrade.
Future<void> migrateLegacyWindowsAppData() async {
  if (!Platform.isWindows) {
    return;
  }
  final roaming = Platform.environment['APPDATA'];
  if (roaming == null || roaming.isEmpty) {
    return;
  }
  await migrateLegacyAppData(
    legacySupportDir: Directory(p.join(roaming, 'com.example', 'gorion_clean')),
    currentSupportDir: await getApplicationSupportDirectory(),
  );
}

/// Moves the data folder from [legacySupportDir] into [currentSupportDir].
///
/// Does nothing when there is no legacy data or the current directory already
/// has data: existing data is never overwritten. Returns whether data moved.
Future<bool> migrateLegacyAppData({
  required Directory legacySupportDir,
  required Directory currentSupportDir,
}) async {
  final legacyData = Directory(p.join(legacySupportDir.path, _dataFolderName));
  final currentData = Directory(
    p.join(currentSupportDir.path, _dataFolderName),
  );
  if (!await legacyData.exists() || await currentData.exists()) {
    return false;
  }

  await currentSupportDir.create(recursive: true);
  try {
    await legacyData.rename(currentData.path);
  } on FileSystemException {
    // A rename fails across volumes or while a file is locked. Copy into a
    // staging folder first so a half-finished copy is never taken for data.
    final staging = Directory('${currentData.path}.migrating');
    if (await staging.exists()) {
      await staging.delete(recursive: true);
    }
    await _copyDirectory(legacyData, staging);
    await staging.rename(currentData.path);
  }
  return true;
}

Future<void> _copyDirectory(Directory source, Directory destination) async {
  await destination.create(recursive: true);
  await for (final entity in source.list(followLinks: false)) {
    final target = p.join(destination.path, p.basename(entity.path));
    if (entity is Directory) {
      await _copyDirectory(entity, Directory(target));
    } else if (entity is File) {
      await entity.copy(target);
    }
  }
}
