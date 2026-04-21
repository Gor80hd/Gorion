enum RunningProcessLookupState { found, missing, unavailable }

class RunningProcessLookup {
  const RunningProcessLookup.found({
    this.executablePath,
    required this.commandLine,
  }) : state = RunningProcessLookupState.found;

  const RunningProcessLookup.missing()
    : state = RunningProcessLookupState.missing,
      executablePath = null,
      commandLine = '';

  const RunningProcessLookup.unavailable()
    : state = RunningProcessLookupState.unavailable,
      executablePath = null,
      commandLine = '';

  final RunningProcessLookupState state;
  final String? executablePath;
  final String commandLine;

  bool get isFound => state == RunningProcessLookupState.found;
  bool get isMissing => state == RunningProcessLookupState.missing;

  String get normalizedCommandLine =>
      commandLine.trim().replaceAll('\\', '/').toLowerCase();
}
