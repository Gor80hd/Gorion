import 'dart:io';

import 'package:gorion_clean/features/runtime/model/runtime_mode.dart';
import 'package:gorion_clean/features/runtime/model/runtime_models.dart';
import 'package:gorion_clean/features/zapret/model/zapret_models.dart';
import 'package:path/path.dart' as p;

const gorionPrivilegedHelperArg = '--gorion-privileged-helper';
const gorionPrivilegedHelperTaskName = 'Gorion Privileged Helper';
const gorionPrivilegedHelperProvisionMarkerFileName =
    'gorion_privileged_helper.installed';
const gorionPrivilegedHelperStateFileName = 'gorion-privileged-helper.json';
const gorionPrivilegedHelperBootstrapFileName =
    'gorion-privileged-helper.bootstrap.json';
const gorionPrivilegedHelperStartupLockFileName =
    'gorion-privileged-helper.startup.lock';
const gorionPrivilegedHelperLoopbackHost = '127.0.0.1';
const gorionPrivilegedHelperLoopbackPort = 47653;
const gorionPrivilegedHelperAuthHeader = 'x-gorion-helper-token';
const gorionPrivilegedHelperBootstrapMaxAge = Duration(seconds: 30);

bool isPrivilegedHelperLaunch(List<String> args) {
  return args.any(
    (arg) =>
        arg.trim().toLowerCase() == gorionPrivilegedHelperArg.toLowerCase(),
  );
}

File privilegedHelperProvisionMarkerForExecutable(String executablePath) {
  return File(
    p.join(
      p.dirname(executablePath),
      gorionPrivilegedHelperProvisionMarkerFileName,
    ),
  );
}

File privilegedHelperStateFileForRuntimeDir(Directory runtimeDir) {
  return File(p.join(runtimeDir.path, gorionPrivilegedHelperStateFileName));
}

File privilegedHelperBootstrapFileForRuntimeDir(Directory runtimeDir) {
  return File(p.join(runtimeDir.path, gorionPrivilegedHelperBootstrapFileName));
}

File privilegedHelperStartupLockFileForRuntimeDir(Directory runtimeDir) {
  return File(p.join(runtimeDir.path, gorionPrivilegedHelperStartupLockFileName));
}

String? normalizedJsonString(dynamic value) {
  final trimmed = value?.toString().trim();
  if (trimmed == null || trimmed.isEmpty) {
    return null;
  }
  return trimmed;
}

Map<String, dynamic>? asJsonMap(dynamic value) {
  if (value is Map<String, dynamic>) {
    return value;
  }
  if (value is Map) {
    return Map<String, dynamic>.from(value.cast<String, dynamic>());
  }
  return null;
}

List<String> jsonStringList(dynamic value) {
  if (value is Iterable) {
    return value.map((entry) => entry.toString()).toList(growable: false);
  }
  return const <String>[];
}

class PrivilegedHelperConnectionInfo {
  const PrivilegedHelperConnectionInfo({
    this.token,
    this.host = gorionPrivilegedHelperLoopbackHost,
    this.port = gorionPrivilegedHelperLoopbackPort,
    this.pid,
    this.launchId,
    this.lastError,
  });

  final String? token;
  final String host;
  final int port;
  final int? pid;
  final String? launchId;
  final String? lastError;

  String get baseUrl => 'http://$host:$port';

  PrivilegedHelperConnectionInfo copyWith({
    String? token,
    String? host,
    int? port,
    int? pid,
    String? launchId,
    String? lastError,
    bool clearPid = false,
    bool clearLastError = false,
  }) {
    return PrivilegedHelperConnectionInfo(
      token: token ?? this.token,
      host: host ?? this.host,
      port: port ?? this.port,
      pid: clearPid ? null : pid ?? this.pid,
      launchId: launchId ?? this.launchId,
      lastError: clearLastError ? null : lastError ?? this.lastError,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'token': token,
      'host': host,
      'port': port,
      'pid': pid,
      'launchId': launchId,
      'lastError': lastError,
    };
  }

  factory PrivilegedHelperConnectionInfo.fromJson(Map<String, dynamic> json) {
    return PrivilegedHelperConnectionInfo(
      token: normalizedJsonString(json['token']),
      host:
          normalizedJsonString(json['host']) ??
          gorionPrivilegedHelperLoopbackHost,
      port:
          (json['port'] as num?)?.toInt() ?? gorionPrivilegedHelperLoopbackPort,
      pid: (json['pid'] as num?)?.toInt(),
      launchId: normalizedJsonString(json['launchId']),
      lastError: normalizedJsonString(json['lastError']),
    );
  }
}

class PrivilegedHelperBootstrapRequest {
  const PrivilegedHelperBootstrapRequest({
    required this.token,
    required this.launchId,
    required this.createdAt,
    this.clientPid,
  });

  final String token;
  final String launchId;
  final DateTime createdAt;
  final int? clientPid;

  Map<String, dynamic> toJson() {
    return {
      'token': token,
      'launchId': launchId,
      'createdAt': createdAt.toIso8601String(),
      'clientPid': clientPid,
    };
  }

  factory PrivilegedHelperBootstrapRequest.fromJson(Map<String, dynamic> json) {
    return PrivilegedHelperBootstrapRequest(
      token: normalizedJsonString(json['token']) ?? '',
      launchId: normalizedJsonString(json['launchId']) ?? '',
      createdAt:
          DateTime.tryParse(normalizedJsonString(json['createdAt']) ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      clientPid: (json['clientPid'] as num?)?.toInt(),
    );
  }
}

RuntimeMode runtimeModeFromJsonValue(dynamic value) {
  final normalized = normalizedJsonString(value)?.toLowerCase();
  for (final mode in RuntimeMode.values) {
    if (mode.name.toLowerCase() == normalized) {
      return mode;
    }
  }
  return RuntimeMode.mixed;
}

Map<String, dynamic>? runtimeSessionToJson(RuntimeSession? session) {
  if (session == null) {
    return null;
  }

  return {
    'profileId': session.profileId,
    'mode': session.mode.name,
    'binaryPath': session.binaryPath,
    'configPath': session.configPath,
    'controllerPort': session.controllerPort,
    'mixedPort': session.mixedPort,
    'secret': session.secret,
    'manualSelectorTag': session.manualSelectorTag,
    'autoGroupTag': session.autoGroupTag,
  };
}

RuntimeSession? runtimeSessionFromJson(dynamic value) {
  final json = asJsonMap(value);
  if (json == null) {
    return null;
  }

  return RuntimeSession(
    profileId: normalizedJsonString(json['profileId']) ?? '',
    mode: runtimeModeFromJsonValue(json['mode']),
    binaryPath: normalizedJsonString(json['binaryPath']) ?? '',
    configPath: normalizedJsonString(json['configPath']) ?? '',
    controllerPort: (json['controllerPort'] as num?)?.toInt() ?? 0,
    mixedPort: (json['mixedPort'] as num?)?.toInt() ?? 0,
    secret: normalizedJsonString(json['secret']) ?? '',
    manualSelectorTag: normalizedJsonString(json['manualSelectorTag']) ?? '',
    autoGroupTag: normalizedJsonString(json['autoGroupTag']) ?? '',
  );
}

Map<String, dynamic>? zapretRuntimeSessionToJson(
  ZapretRuntimeSession? session,
) {
  if (session == null) {
    return null;
  }

  return {
    'executablePath': session.executablePath,
    'workingDirectory': session.workingDirectory,
    'processId': session.processId,
    'startedAt': session.startedAt.toIso8601String(),
    'arguments': session.arguments,
    'commandPreview': session.commandPreview,
  };
}

ZapretRuntimeSession? zapretRuntimeSessionFromJson(dynamic value) {
  final json = asJsonMap(value);
  if (json == null) {
    return null;
  }

  final startedAtRaw = normalizedJsonString(json['startedAt']);
  return ZapretRuntimeSession(
    executablePath: normalizedJsonString(json['executablePath']) ?? '',
    workingDirectory: normalizedJsonString(json['workingDirectory']) ?? '',
    processId: (json['processId'] as num?)?.toInt() ?? 0,
    startedAt: DateTime.tryParse(startedAtRaw ?? '') ?? DateTime.now(),
    arguments: jsonStringList(json['arguments']),
    commandPreview: normalizedJsonString(json['commandPreview']) ?? '',
  );
}

class PrivilegedHelperRuntimeSnapshot {
  const PrivilegedHelperRuntimeSnapshot({required this.logs, this.session});

  final RuntimeSession? session;
  final List<String> logs;

  Map<String, dynamic> toJson() {
    return {'session': runtimeSessionToJson(session), 'logs': logs};
  }

  factory PrivilegedHelperRuntimeSnapshot.fromJson(Map<String, dynamic> json) {
    return PrivilegedHelperRuntimeSnapshot(
      session: runtimeSessionFromJson(json['session']),
      logs: jsonStringList(json['logs']),
    );
  }
}

class PrivilegedHelperZapretSnapshot {
  const PrivilegedHelperZapretSnapshot({
    required this.logs,
    this.session,
    this.lastExitCode,
  });

  final ZapretRuntimeSession? session;
  final List<String> logs;
  final int? lastExitCode;

  Map<String, dynamic> toJson() {
    return {
      'session': zapretRuntimeSessionToJson(session),
      'logs': logs,
      'lastExitCode': lastExitCode,
    };
  }

  factory PrivilegedHelperZapretSnapshot.fromJson(Map<String, dynamic> json) {
    return PrivilegedHelperZapretSnapshot(
      session: zapretRuntimeSessionFromJson(json['session']),
      logs: jsonStringList(json['logs']),
      lastExitCode: (json['lastExitCode'] as num?)?.toInt(),
    );
  }
}
