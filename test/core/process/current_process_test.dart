import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gorion/core/process/current_process.dart';

void main() {
  test('currentProcessPid resolves to the current process id', () {
    expect(currentProcessPid, pid);
  });
}
