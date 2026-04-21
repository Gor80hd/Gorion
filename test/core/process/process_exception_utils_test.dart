import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gorion_clean/core/process/process_exception_utils.dart';

void main() {
  test('treats Windows elevation error code 740 as admin-required', () {
    final error = ProcessException('run', const <String>[], 'Access denied', 740);

    expect(isProcessElevationRequired(error), isTrue);
  });

  test('matches localized elevation text from the process exception body', () {
    final error = ProcessException(
      'run',
      const <String>[],
      'Операция требует повышения прав администратора.',
      1,
    );

    expect(isProcessElevationRequired(error), isTrue);
  });

  test('ignores unrelated process failures', () {
    final error = ProcessException(
      'run',
      const <String>[],
      'The system cannot find the file specified.',
      2,
    );

    expect(isProcessElevationRequired(error), isFalse);
  });
}
