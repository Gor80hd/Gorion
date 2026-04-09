import 'dart:io';

enum GorionConsoleSection { preconnect, bestServer, connect, zapret }

class GorionConsoleLog {
  static const _reset = '\x1B[0m';
  static const _bold = '\x1B[1m';
  static const _dim = '\x1B[2m';
  static const _cyan = '\x1B[36m';
  static const _yellow = '\x1B[33m';
  static const _green = '\x1B[32m';
  static const _red = '\x1B[31m';
  static const _blue = '\x1B[34m';
  static const _pink = '\x1B[95m';

  static GorionConsoleSection? _lastSection;
  static bool _connectNoiseNoticeShown = false;

  static void autoSelect({
    required String label,
    required String message,
    int? completedSteps,
    int? totalSteps,
    bool isError = false,
  }) {
    final section = switch (label) {
      'Pre-connect auto-select' => GorionConsoleSection.preconnect,
      _ => GorionConsoleSection.bestServer,
    };

    final scope = switch (label) {
      'Manual auto-select' => 'run: ',
      'Automatic maintenance' => 'maintain: ',
      _ => '',
    };

    final shortened = _shortenAutoSelectMessage(message);
    if (shortened.isEmpty) return;
    _write(
      section: section,
      message: '$scope${_formatProgress(completedSteps, totalSteps)}$shortened',
      isError: isError,
      highlight: message.startsWith('DEEP-REFRESH:'),
    );
  }

  static void connect(String message, {bool isError = false}) {
    final trimmed = message.trim();
    final isSingboxRuntimeLine =
        trimmed.startsWith('STDOUT ') || trimmed.startsWith('STDERR ');

    if (!isSingboxRuntimeLine) {
      if (trimmed.startsWith('Preparing sing-box runtime for profile ') ||
          trimmed.startsWith('Stopping sing-box PID ') ||
          trimmed.startsWith('sing-box exited with code ')) {
        _connectNoiseNoticeShown = false;
      }
      _write(
        section: GorionConsoleSection.connect,
        message: _shortenConnectionMessage(trimmed),
        isError: isError,
      );
      return;
    }

    final severity = _runtimeSeverity(trimmed);
    final shortened = _shortenSingboxRuntimeLine(trimmed);
    if (_shouldSuppressSingboxRuntimeLine(trimmed, shortened)) {
      if (!_connectNoiseNoticeShown) {
        _connectNoiseNoticeShown = true;
        _write(
          section: GorionConsoleSection.connect,
          message:
              'SBX traffic logs hidden; showing only state changes and real errors',
          isError: false,
          subtle: true,
        );
      }
      return;
    }

    _write(
      section: GorionConsoleSection.connect,
      message: 'SBX $shortened',
      isError: severity == 'ERROR',
      subtle: severity == 'INFO' || severity == 'DEBUG',
    );
  }

  static void zapret(String message, {bool isError = false}) {
    final trimmed = message.trim();
    if (trimmed.isEmpty) {
      return;
    }

    final isRuntimeLine =
        trimmed.startsWith('STDOUT ') || trimmed.startsWith('STDERR ');
    final display = isRuntimeLine
        ? 'WWS ${trimmed.replaceFirst(RegExp(r'^STD(?:OUT|ERR)\s+'), '')}'
        : trimmed;

    _write(
      section: GorionConsoleSection.zapret,
      message: display,
      isError: isError,
      subtle: isRuntimeLine && !isError,
    );
  }

  static void _write({
    required GorionConsoleSection section,
    required String message,
    required bool isError,
    bool subtle = false,
    bool highlight = false,
  }) {
    final sink = isError ? stderr : stdout;
    final ansi = isError
        ? stderr.supportsAnsiEscapes
        : stdout.supportsAnsiEscapes;
    final label = _sectionLabel(section);

    if (_lastSection != section) {
      if (_lastSection != null) {
        sink.writeln('');
      }
      _lastSection = section;
      sink.writeln(
        _paint(
          '=== $label ===',
          color: _sectionColor(section),
          bold: true,
          ansi: ansi,
        ),
      );
    }

    sink.writeln(
      _paint(
        '[$label] $message',
        color: isError
            ? _red
            : highlight
            ? _pink
            : _sectionColor(section),
        bold: !subtle || isError || highlight,
        dim: subtle && !isError && !highlight,
        ansi: ansi,
      ),
    );
  }

  static String _sectionLabel(GorionConsoleSection section) {
    return switch (section) {
      GorionConsoleSection.preconnect => 'PRECONNECT',
      GorionConsoleSection.bestServer => 'BEST-SERVER',
      GorionConsoleSection.connect => 'CONNECT',
      GorionConsoleSection.zapret => 'ZAPRET',
    };
  }

  static String _sectionColor(GorionConsoleSection section) {
    return switch (section) {
      GorionConsoleSection.preconnect => _cyan,
      GorionConsoleSection.bestServer => _yellow,
      GorionConsoleSection.connect => _green,
      GorionConsoleSection.zapret => _blue,
    };
  }

  static String _paint(
    String text, {
    required String color,
    required bool ansi,
    bool bold = false,
    bool dim = false,
  }) {
    if (!ansi) {
      return text;
    }

    final buffer = StringBuffer();
    if (bold) {
      buffer.write(_bold);
    }
    if (dim) {
      buffer.write(_dim);
    }
    buffer.write(color);
    buffer.write(text);
    buffer.write(_reset);
    return buffer.toString();
  }

  static String _formatProgress(int? completedSteps, int? totalSteps) {
    if (completedSteps == null || totalSteps == null || totalSteps <= 0) {
      return '';
    }

    final boundedCompleted = completedSteps < 0
        ? 0
        : (completedSteps > totalSteps ? totalSteps : completedSteps);
    return '[$boundedCompleted/$totalSteps] ';
  }

  static String _shortenAutoSelectMessage(String message) {
    final trimmed = message.trim();

    RegExpMatch? match;

    match = RegExp(
      r'^Loading saved auto-select state and preparing candidate probes\.$',
    ).firstMatch(trimmed);
    if (match != null) {
      return 'load cached state';
    }

    match = RegExp(
      r'^Reusing recent successful server (.+) before probing new candidates\.$',
    ).firstMatch(trimmed);
    if (match != null) {
      return 'reuse recent ${match.group(1)}';
    }

    match = RegExp(
      r'^Preparing detached probes for (\d+) server candidates before starting sing-box\.$',
    ).firstMatch(trimmed);
    if (match != null) {
      return 'detached probes: ${match.group(1)} servers';
    }

    match = RegExp(
      r'^Probing (.+) \((\d+)/(\d+)\) in a detached sing-box runtime\.$',
    ).firstMatch(trimmed);
    if (match != null) {
      return 'probe ${match.group(1)} ${match.group(2)}/${match.group(3)}';
    }

    match = RegExp(
      r'^check (current|contender|recovery|candidate) (.+): (n/a|\d+ms), (domain (?:OK|failed)), (IP (?:OK|failed)), (\d+) KB/s\.$',
    ).firstMatch(trimmed);
    if (match != null) {
      final role = match.group(1)!;
      final server = match.group(2)!;
      final delay = match.group(3)!;
      final domain = match.group(4)!;
      final ip = match.group(5)!;
      final kbps = match.group(6)!;
      final prefix = role == 'current' ? '' : '$role ';
      return '$prefix$server >> $delay, $domain, $ip, $kbps KB/s';
    }

    match = RegExp(
      r'^Probe result for (.+): URLTest (n/a|\d+ms), (domain (?:OK|failed)), (IP (?:OK|failed|skipped)), (\d+) KB/s\.$',
    ).firstMatch(trimmed);
    if (match != null) {
      final server = match.group(1)!;
      final delay = match.group(2)!;
      final domain = match.group(3)!;
      final ip = match.group(4)!;
      final kbps = match.group(5)!;
      return '$server >> $delay, $domain, $ip, $kbps KB/s';
    }

    match = RegExp(
      r'^No fully confirmed server passed the detached pre-connect probe\. Using best-effort candidate (.+) and rechecking immediately after connect\.$',
    ).firstMatch(trimmed);
    if (match != null) {
      return 'no full pass, use best-effort ${match.group(1)}';
    }

    match = RegExp(
      r'^No candidate passed the detached pre-connect probe\. Continuing with the saved server and retrying after connect\.$',
    ).firstMatch(trimmed);
    if (match != null) {
      return 'no pass, keep saved server';
    }

    match = RegExp(
      r'^Auto-selector chose (.+) before connect after confirming end-to-end proxy traffic\.$',
    ).firstMatch(trimmed);
    if (match != null) {
      return 'pick ${match.group(1)} before connect';
    }

    match = RegExp(
      r'^Auto-selector chose (.+) before connect \((.+)ms, (.+) KB/s\)\.$',
    ).firstMatch(trimmed);
    if (match != null) {
      return 'pick ${match.group(1)} before connect (${match.group(2)}ms, ${match.group(3)} KB/s)';
    }

    match = RegExp(
      r'^Refreshing URLTest delays for (\d+) candidate servers\.$',
    ).firstMatch(trimmed);
    if (match != null) {
      return 'URLTest refresh: ${match.group(1)} servers';
    }

    match = RegExp(
      r'^Refreshing URLTest delays and checking the current server\.$',
    ).firstMatch(trimmed);
    if (match != null) {
      return 'refresh delays + check current';
    }

    match = RegExp(
      r'^Refreshing URLTest delays and probing servers\.$',
    ).firstMatch(trimmed);
    if (match != null) {
      return 'refresh delays + probe servers';
    }

    if (trimmed ==
        'URLTest refresh failed, continuing with end-to-end proxy probes only.') {
      return 'URLTest failed → probes only';
    }

    if (RegExp(
      r'^Probing current server .+ through the local proxy\.$',
    ).hasMatch(trimmed)) {
      return '';
    }

    if (RegExp(
      r'^Current server failed the probe\. Checking replacement .+ \(\d+/\d+\)\.$',
    ).hasMatch(trimmed)) {
      return '';
    }

    if (RegExp(r'^Probing contender .+ \(\d+/\d+\)\.$').hasMatch(trimmed)) {
      return '';
    }

    if (RegExp(
      r'^Probing candidate .+ \(\d+/\d+\) through the local proxy\.$',
    ).hasMatch(trimmed)) {
      return '';
    }

    match = RegExp(
      r'^Current server (.+) stayed selected after the latest (?:URLTest and )?proxy probe check\.$',
    ).firstMatch(trimmed);
    if (match != null) {
      return 'keep ${match.group(1)}';
    }

    match = RegExp(
      r'^Auto-selector switched from (.+) to (.+) after confirming better end-to-end health and latency\.$',
    ).firstMatch(trimmed);
    if (match != null) {
      return 'switch ${match.group(1)} -> ${match.group(2)}';
    }

    match = RegExp(
      r'^Auto-selector recovered from (.+) to (.+) after the current server failed the end-to-end proxy probe\.$',
    ).firstMatch(trimmed);
    if (match != null) {
      return 'recover ${match.group(1)} -> ${match.group(2)}';
    }

    match = RegExp(
      r'^Auto-selector chose (.+) using URLTest plus IP and domain probes through the local proxy\.$',
    ).firstMatch(trimmed);
    if (match != null) {
      return 'pick ${match.group(1)}';
    }

    match = RegExp(
      r'^Auto-selector chose (.+)\. Domain traffic worked, but the IP-only probe stayed partial\.$',
    ).firstMatch(trimmed);
    if (match != null) {
      return 'pick ${match.group(1)} (domain ok, ip partial)';
    }

    match = RegExp(
      r'^Auto-selector chose (.+) with partial confidence\. IP-only probe worked, domain probe did not\.$',
    ).firstMatch(trimmed);
    if (match != null) {
      return 'pick ${match.group(1)} (ip ok, domain fail)';
    }

    return trimmed
        .replaceAll('Automatic maintenance failed: ', 'failed: ')
        .replaceAll('Manual auto-select failed: ', 'failed: ')
        .replaceAll('Pre-connect auto-select failed: ', 'failed: ');
  }

  static String _shortenConnectionMessage(String message) {
    final trimmed = message.trim();

    RegExpMatch? match;

    match = RegExp(
      r'^Preparing sing-box runtime for profile (.+)\.$',
    ).firstMatch(trimmed);
    if (match != null) {
      return 'prepare runtime profile=${match.group(1)}';
    }

    match = RegExp(
      r'^Runtime config written to .+ controllerPort=(\d+) mixedPort=(\d+) mode=(\w+) selectedServer=(.+)\.$',
    ).firstMatch(trimmed);
    if (match != null) {
      return 'config ready mode=${match.group(3)} ctrl=${match.group(1)} mixed=${match.group(2)} server=${match.group(4)}';
    }

    match = RegExp(r'^Launching sing-box (.+): .+$').firstMatch(trimmed);
    if (match != null) {
      return 'launch sing-box ${match.group(1)}';
    }

    match = RegExp(
      r'^sing-box process started with PID (\d+)\.$',
    ).firstMatch(trimmed);
    if (match != null) {
      return 'pid ${match.group(1)} started';
    }

    match = RegExp(r'^Clash API is ready on (.+)\.$').firstMatch(trimmed);
    if (match != null) {
      return 'controller ready ${match.group(1)}';
    }

    match = RegExp(r'^Stopping sing-box PID (\d+)\.$').firstMatch(trimmed);
    if (match != null) {
      return 'stop pid ${match.group(1)}';
    }

    match = RegExp(
      r'^sing-box exited with code (-?\d+)\.$',
    ).firstMatch(trimmed);
    if (match != null) {
      return 'exit code ${match.group(1)}';
    }

    match = RegExp(
      r'^Stopped orphaned sing-box PID (\d+) from a previous app session\.$',
    ).firstMatch(trimmed);
    if (match != null) {
      return 'stopped orphan pid ${match.group(1)}';
    }

    match = RegExp(
      r'^Removing stale sing-box PID marker for (\d+)\.$',
    ).firstMatch(trimmed);
    if (match != null) {
      return 'remove stale pid marker ${match.group(1)}';
    }

    return trimmed
        .replaceAll('Failed to start sing-box process: ', 'start failed: ')
        .replaceAll('The Clash API did not start: ', 'controller failed: ')
        .replaceAll(
          'Stopping sing-box after startup failure.',
          'stop after startup failure',
        )
        .replaceAll(
          'Failed to enable the system proxy: ',
          'system proxy failed: ',
        )
        .replaceAll(
          'Failed to restore the system proxy: ',
          'restore proxy failed: ',
        )
        .replaceAll(
          'sing-box did not exit gracefully, forcing termination.',
          'force kill',
        );
  }

  static String _shortenSingboxRuntimeLine(String message) {
    var line = message.trim();
    line = line.replaceFirst(RegExp(r'^STD(?:OUT|ERR)\s+'), '');
    line = line.replaceFirst(RegExp(r'^(INFO|ERROR|WARN|DEBUG)\[\d+\]\s*'), '');
    line = line.replaceFirst(RegExp(r'^\[\d+\s+\d+ms\]\s*'), '');
    final summarizedConnectionFailure = _summarizeConnectionFailure(line);
    if (summarizedConnectionFailure != null) {
      return summarizedConnectionFailure;
    }
    line = line.replaceAll('outbound connection to ', '-> ');
    line = line.replaceAll('inbound connection from ', 'from ');
    line = line.replaceAll('inbound connection to ', 'to ');
    line = line.replaceAll('process connection from ', 'from ');
    line = line.replaceAll(
      'An established connection was aborted by the software in your host machine.',
      'host aborted the connection.',
    );
    return line;
  }

  static String? _summarizeConnectionFailure(String line) {
    final match = RegExp(
      r'^connection: open connection to (.+?) using outbound/[^\[]+\[(.+?)\]: (.+)$',
    ).firstMatch(line);
    if (match == null) {
      return null;
    }

    final destination = match.group(1)!;
    final tag = match.group(2)!;
    final detail = _summarizeConnectionFailureDetail(match.group(3)!);
    return '$tag -> $destination: $detail';
  }

  static String _summarizeConnectionFailureDetail(String detail) {
    final trimmed = detail.trim();
    if (trimmed == 'remote error: tls: unrecognized name') {
      return 'remote rejected SNI';
    }
    if (trimmed.contains(
      'initialize vision: vision: not a valid supported TLS connection: *v2raywebsocket.WebsocketConn',
    )) {
      return 'Vision incompatible with WebSocket transport';
    }
    if (trimmed.startsWith(
      'initialize vision: vision: not a valid supported TLS connection:',
    )) {
      return 'Vision incompatible with current transport';
    }
    return trimmed;
  }

  static String _runtimeSeverity(String message) {
    final trimmed = message.trim();
    final line = trimmed.replaceFirst(RegExp(r'^STD(?:OUT|ERR)\s+'), '');
    final match = RegExp(r'^(INFO|ERROR|WARN|DEBUG)\[').firstMatch(line);
    return match?.group(1) ?? 'INFO';
  }

  static bool _shouldSuppressSingboxRuntimeLine(
    String rawMessage,
    String shortened,
  ) {
    final line = rawMessage.trim().replaceFirst(
      RegExp(r'^STD(?:OUT|ERR)\s+'),
      '',
    );

    final isTrafficFlow =
        line.contains('inbound connection from ') ||
        line.contains('inbound connection to ') ||
        line.contains('outbound connection to ');
    if (isTrafficFlow) {
      return true;
    }

    final isBenignLocalAbort =
        line.contains('process connection from ') &&
        shortened.contains('host aborted the connection.');
    if (isBenignLocalAbort) {
      return true;
    }

    return false;
  }
}
