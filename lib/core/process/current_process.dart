import 'dart:io';

/// Returns the PID of the current application process.
///
/// We wrap [pid] explicitly so callers do not have to depend on the global
/// `dart:io` getter directly when passing the parent process to watchdogs.
int get currentProcessPid => pid;
