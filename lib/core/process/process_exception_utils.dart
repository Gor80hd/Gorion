import 'dart:io';

bool isProcessElevationRequired(ProcessException error) {
  if (error.errorCode == 740) {
    return true;
  }

  final details = error.toString().toLowerCase();
  return details.contains('requested operation requires elevation') ||
      details.contains('requires elevation') ||
      details.contains('require elevation') ||
      details.contains('требует повышения');
}
