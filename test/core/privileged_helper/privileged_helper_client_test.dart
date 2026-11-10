import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gorion/core/privileged_helper/privileged_helper_client.dart';
import 'package:gorion/core/privileged_helper/privileged_helper_protocol.dart';
import 'package:path/path.dart' as p;

void main() {
  test(
    'PrivilegedHelperClient detects installer-provisioned helper marker',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'gorion-helper-marker-',
      );
      addTearDown(() => tempDir.delete(recursive: true));

      final fakeExecutable = p.join(tempDir.path, 'Gorion.exe');
      await File(fakeExecutable).writeAsString('');
      await privilegedHelperProvisionMarkerForExecutable(
        fakeExecutable,
      ).writeAsString('');

      expect(
        PrivilegedHelperClient.isProvisionedSync(
          executablePath: fakeExecutable,
        ),
        Platform.isWindows,
      );
    },
  );
}
