import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gorion_clean/core/windows/privileged_helper_client.dart';
import 'package:gorion_clean/core/windows/privileged_helper_protocol.dart';
import 'package:path/path.dart' as p;

void main() {
  test(
    'WindowsPrivilegedHelperClient detects installer-provisioned helper marker',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'gorion-helper-marker-',
      );
      addTearDown(() => tempDir.delete(recursive: true));

      final fakeExecutable = p.join(tempDir.path, 'gorion_clean.exe');
      await File(fakeExecutable).writeAsString('');
      await privilegedHelperProvisionMarkerForExecutable(
        fakeExecutable,
      ).writeAsString('');

      expect(
        WindowsPrivilegedHelperClient.isProvisionedSync(
          executablePath: fakeExecutable,
        ),
        Platform.isWindows,
      );
    },
  );
}
