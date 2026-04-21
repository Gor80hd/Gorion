import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:gorion_clean/core/constants/singbox_assets.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const _staleDetachedRuntimeAge = Duration(minutes: 20);
const _detachedRuntimeCleanupInterval = Duration(minutes: 5);
const _detachedRuntimeRoots = {'benchmark', 'maintain', 'preconnect'};
const _detachedRuntimeMarkerFiles = {
  'config.json',
  'maintain-config.json',
  'preconnect-config.json',
  'sing-box',
  'sing-box.exe',
  'sing-box.version',
};

DateTime? _lastDetachedRuntimeCleanupAt;
Future<void>? _detachedRuntimeCleanupInFlight;

Future<Directory> ensureGorionRuntimeDirectory({String? subdirectory}) async {
  final supportDir = await getApplicationSupportDirectory();
  final runtimeRoot = Directory(p.join(supportDir.path, 'gorion', 'runtime'));
  if (!await runtimeRoot.exists()) {
    await runtimeRoot.create(recursive: true);
  }
  await _cleanupDetachedRuntimeDirectoriesIfNeeded(runtimeRoot);

  if (subdirectory == null || subdirectory.trim().isEmpty) {
    return runtimeRoot;
  }

  final runtimeDir = Directory(p.join(runtimeRoot.path, subdirectory));
  if (!await runtimeDir.exists()) {
    await runtimeDir.create(recursive: true);
  }
  return runtimeDir;
}

Future<void> cleanupStaleDetachedRuntimeDirectories(
  Directory runtimeRoot, {
  DateTime? now,
  Duration staleAge = _staleDetachedRuntimeAge,
}) async {
  final cutoff = (now ?? DateTime.now()).subtract(staleAge);

  for (final rootName in _detachedRuntimeRoots) {
    final detachedRoot = Directory(p.join(runtimeRoot.path, rootName));
    if (!await detachedRoot.exists()) {
      continue;
    }

    final runtimeDirs = <Directory>[];
    try {
      await for (final entity in detachedRoot.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! Directory) {
          continue;
        }
        if (await _looksLikeDetachedRuntimeDirectory(entity)) {
          runtimeDirs.add(entity);
        }
      }
    } on FileSystemException {
      continue;
    }

    runtimeDirs.sort(
      (left, right) => right.path.length.compareTo(left.path.length),
    );
    for (final runtimeDir in runtimeDirs) {
      if (!await runtimeDir.exists()) {
        continue;
      }

      final lastTouchedAt = await _detachedRuntimeLastTouchedAt(runtimeDir);
      if (lastTouchedAt == null) {
        continue;
      }
      if (lastTouchedAt.isAfter(cutoff)) {
        continue;
      }

      try {
        await runtimeDir.delete(recursive: true);
      } on FileSystemException {
        continue;
      }
    }

    await _pruneEmptyDetachedRuntimeDirectories(detachedRoot);
  }
}

Future<File> prepareSingboxBinary(Directory runtimeDir) async {
  final descriptor = resolveSingboxAsset();
  final binaryFile = File(p.join(runtimeDir.path, descriptor.fileName));
  final versionMarker = File(p.join(runtimeDir.path, 'sing-box.version'));
  final expectedMarker = '$singboxVersion:${descriptor.assetPath}';

  if (await binaryFile.exists() && await versionMarker.exists()) {
    final marker = await versionMarker.readAsString();
    if (marker.trim() == expectedMarker) {
      return binaryFile;
    }
  }

  final assetData = await rootBundle.load(descriptor.assetPath);
  await binaryFile.writeAsBytes(assetData.buffer.asUint8List(), flush: true);
  await versionMarker.writeAsString(expectedMarker, flush: true);

  if (!Platform.isWindows) {
    await Process.run('chmod', ['755', binaryFile.path]);
  }
  return binaryFile;
}

class ReservedLoopbackPort {
  const ReservedLoopbackPort._(this.socket);

  final ServerSocket socket;

  int get port => socket.port;

  Future<void> close() {
    return socket.close();
  }
}

Future<ReservedLoopbackPort> reserveLoopbackPort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  return ReservedLoopbackPort._(socket);
}

Future<int> findFreePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

Future<void> _cleanupDetachedRuntimeDirectoriesIfNeeded(
  Directory runtimeRoot,
) async {
  final now = DateTime.now();
  final lastRun = _lastDetachedRuntimeCleanupAt;
  if (lastRun != null &&
      now.difference(lastRun) < _detachedRuntimeCleanupInterval) {
    final inFlight = _detachedRuntimeCleanupInFlight;
    if (inFlight != null) {
      await inFlight;
    }
    return;
  }

  final inFlight = _detachedRuntimeCleanupInFlight;
  if (inFlight != null) {
    await inFlight;
    return;
  }

  final cleanupFuture = cleanupStaleDetachedRuntimeDirectories(
    runtimeRoot,
    now: now,
  );
  _detachedRuntimeCleanupInFlight = cleanupFuture;
  try {
    await cleanupFuture;
    _lastDetachedRuntimeCleanupAt = now;
  } finally {
    if (identical(_detachedRuntimeCleanupInFlight, cleanupFuture)) {
      _detachedRuntimeCleanupInFlight = null;
    }
  }
}

Future<bool> _looksLikeDetachedRuntimeDirectory(Directory directory) async {
  try {
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) {
        continue;
      }
      if (_detachedRuntimeMarkerFiles.contains(p.basename(entity.path))) {
        return true;
      }
    }
  } on FileSystemException {
    return false;
  }
  return false;
}

Future<DateTime?> _detachedRuntimeLastTouchedAt(Directory directory) async {
  DateTime? latestModifiedAt;
  var sawMarkerFile = false;

  try {
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) {
        continue;
      }
      if (!_detachedRuntimeMarkerFiles.contains(p.basename(entity.path))) {
        continue;
      }

      sawMarkerFile = true;
      final modifiedAt = await entity.lastModified();
      if (latestModifiedAt == null || modifiedAt.isAfter(latestModifiedAt)) {
        latestModifiedAt = modifiedAt;
      }
    }
    if (!sawMarkerFile) {
      latestModifiedAt = (await directory.stat()).modified;
    }
  } on FileSystemException {
    return null;
  }

  return latestModifiedAt;
}

Future<void> _pruneEmptyDetachedRuntimeDirectories(
  Directory detachedRoot,
) async {
  final directories = <Directory>[];
  try {
    await for (final entity in detachedRoot.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is Directory) {
        directories.add(entity);
      }
    }
  } on FileSystemException {
    return;
  }

  directories.sort(
    (left, right) => right.path.length.compareTo(left.path.length),
  );
  for (final directory in directories) {
    if (!await directory.exists()) {
      continue;
    }

    try {
      final contents = await directory
          .list(followLinks: false)
          .take(1)
          .toList();
      if (contents.isEmpty) {
        await directory.delete();
      }
    } on FileSystemException {
      continue;
    }
  }
}
