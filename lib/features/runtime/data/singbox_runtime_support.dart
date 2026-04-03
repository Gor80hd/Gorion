import 'dart:io';

import 'package:flutter/services.dart';
import 'package:gorion_clean/core/constants/singbox_assets.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

Future<Directory> ensureGorionRuntimeDirectory({String? subdirectory}) async {
  final supportDir = await getApplicationSupportDirectory();
  final segments = <String>[supportDir.path, 'gorion', 'runtime'];
  if (subdirectory != null && subdirectory.trim().isNotEmpty) {
    segments.add(subdirectory);
  }

  final runtimeDir = Directory(p.joinAll(segments));
  if (!await runtimeDir.exists()) {
    await runtimeDir.create(recursive: true);
  }
  return runtimeDir;
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

Future<int> findFreePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}
