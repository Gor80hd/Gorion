import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gorion_clean/features/auto_select/model/auto_select_state.dart';
import 'package:gorion_clean/features/home/application/dashboard_controller.dart';
import 'package:gorion_clean/features/runtime/model/runtime_models.dart';
import 'package:gorion_clean/utils/server_display_text.dart';

final autoServerSelectionStatusProvider = Provider<String?>((ref) {
  final snapshot = ref.watch(
    dashboardControllerProvider.select(
      (s) => (
        activity: s.autoSelectActivity,
        connectionStage: s.connectionStage,
        activeServerTag: s.activeServerTag,
      ),
    ),
  );
  return describeAutoSelectActivityStatus(
    snapshot.activity,
    connectionStage: snapshot.connectionStage,
    activeServerTag: snapshot.activeServerTag,
  );
});

String describeAutoSelectActivityLabel(String? label) {
  return switch (label?.trim()) {
    'Pre-connect auto-select' => 'Подбор перед подключением',
    'Manual auto-select' => 'Подбор лучшего сервера',
    'Automatic maintenance' => 'Проверка текущего подключения',
    final String value when value.isNotEmpty => value,
    _ => 'Автоподбор сервера',
  };
}

String? describeAutoSelectActivityStatus(
  AutoSelectActivityState activity, {
  ConnectionStage? connectionStage,
  String? activeServerTag,
}) {
  final summary = describeAutoSelectMessage(
    label: activity.label,
    message: activity.message,
  );
  if (connectionStage == ConnectionStage.connected) {
    if (summary != null && summary.startsWith('Подключаем ')) {
      return summary.replaceFirst('Подключаем ', 'Подключено ');
    }

    if (activity.active && activity.label != 'Pre-connect auto-select') {
      if (summary != null && summary.isNotEmpty) {
        return summary;
      }
    }

    final connectedServer = _serverName(activeServerTag ?? '');
    if (connectedServer.isNotEmpty) {
      return 'Подключено: $connectedServer';
    }

    if (summary != null && summary.isNotEmpty) {
      return summary;
    }

    return 'Подключено';
  }

  if (summary != null && summary.isNotEmpty) {
    return summary;
  }

  final label = activity.label?.trim();
  if (label == null || label.isEmpty) {
    return null;
  }
  return describeAutoSelectActivityLabel(label);
}

String? describeAutoSelectMessage({String? label, String? message}) {
  final trimmed = message?.trim();
  if (trimmed == null || trimmed.isEmpty) {
    return null;
  }

  RegExpMatch? match;

  match = RegExp(
    r'^Loading saved auto-select state and preparing candidate probes\.$',
  ).firstMatch(trimmed);
  if (match != null) {
    return 'Готовим список серверов';
  }

  match = RegExp(
    r'^Reusing recent successful server (.+) before probing new candidates\.$',
  ).firstMatch(trimmed);
  if (match != null) {
    return 'Берём недавний рабочий сервер: ${_serverName(match.group(1)!)}';
  }

  match = RegExp(
    r'^Preparing detached probes for (\d+) server candidates before starting sing-box\.$',
  ).firstMatch(trimmed);
  if (match != null) {
    return 'Подбираем сервер перед подключением';
  }

  match = RegExp(
    r'^Probing (.+) \((\d+)/(\d+)\) in a detached sing-box runtime\.$',
  ).firstMatch(trimmed);
  if (match != null) {
    return 'Проверяем ${_serverName(match.group(1)!)} (${match.group(2)}/${match.group(3)})';
  }

  match = RegExp(
    r'^No fully confirmed server passed the detached pre-connect probe\. Using best-effort candidate (.+) and rechecking immediately after connect\.$',
  ).firstMatch(trimmed);
  if (match != null) {
    return 'Берём ${_serverName(match.group(1)!)} и перепроверим после подключения';
  }

  if (trimmed ==
      'No candidate passed the detached pre-connect probe. Continuing with the saved server and retrying after connect.') {
    return 'Оставляем сохранённый сервер и перепроверим после подключения';
  }

  match = RegExp(
    r'^Auto-selector chose (.+) before connect after confirming end-to-end proxy traffic\.$',
  ).firstMatch(trimmed);
  if (match != null) {
    return 'Подключаем ${_serverName(match.group(1)!)}';
  }

  match = RegExp(
    r'^Auto-selector chose (.+) before connect \((.+)ms, (.+) KB/s\)\.$',
  ).firstMatch(trimmed);
  if (match != null) {
    return 'Подключаем ${_serverName(match.group(1)!)}';
  }

  if (trimmed == 'Refreshing URLTest delays and checking the current server.') {
    return 'Проверяем текущий сервер';
  }

  if (trimmed == 'Refreshing URLTest delays and probing servers.') {
    return 'Проверяем доступные серверы';
  }

  match = RegExp(
    r'^Refreshing URLTest delays for (\d+) candidate servers\.$',
  ).firstMatch(trimmed);
  if (match != null) {
    return 'Обновляем пинг у ${match.group(1)} серверов';
  }

  match = RegExp(
    r'^Current server (.+) passed a live-proxy health check recently — skipping re-probe\.$',
  ).firstMatch(trimmed);
  if (match != null) {
    return 'Текущий сервер недавно уже прошёл проверку: ${_serverName(match.group(1)!)}';
  }

  match = RegExp(
    r'^Current server (.+) health assumed OK from recent cache\.$',
  ).firstMatch(trimmed);
  if (match != null) {
    return 'Оставляем текущий сервер: ${_serverName(match.group(1)!)}';
  }

  match = RegExp(
    r'^Probing current server (.+) through the local proxy\.$',
  ).firstMatch(trimmed);
  if (match != null) {
    return 'Проверяем текущий сервер: ${_serverName(match.group(1)!)}';
  }

  match = RegExp(
    r'^Current server failed the probe\. Checking replacement (.+) \((\d+)/(\d+)\)\.$',
  ).firstMatch(trimmed);
  if (match != null) {
    return 'Ищем замену: ${_serverName(match.group(1)!)} (${match.group(2)}/${match.group(3)})';
  }

  match = RegExp(
    r'^Probing contender (.+) \((\d+)/(\d+)\)\.$',
  ).firstMatch(trimmed);
  if (match != null) {
    return 'Сравниваем с ${_serverName(match.group(1)!)} (${match.group(2)}/${match.group(3)})';
  }

  match = RegExp(
    r'^Probing candidate (.+) \((\d+)/(\d+)\) through the local proxy\.$',
  ).firstMatch(trimmed);
  if (match != null) {
    return 'Проверяем ${_serverName(match.group(1)!)} (${match.group(2)}/${match.group(3)})';
  }

  match = RegExp(
    r'^Keeping (.+) because the automatic switch cooldown is still active\.$',
  ).firstMatch(trimmed);
  if (match != null) {
    return 'Оставляем ${_serverName(match.group(1)!)}: ещё рано переключать';
  }

  match = RegExp(
    r'^Current server (.+) stayed selected because the last automatic switch was too recent\.$',
  ).firstMatch(trimmed);
  if (match != null) {
    return 'Оставляем текущий сервер: ${_serverName(match.group(1)!)}';
  }

  match = RegExp(
    r'^Current server (.+) stayed selected after the latest (?:URLTest and )?proxy probe check\.$',
  ).firstMatch(trimmed);
  if (match != null) {
    return 'Оставляем текущий сервер: ${_serverName(match.group(1)!)}';
  }

  match = RegExp(
    r'^Auto-selector switched from (.+) to (.+) after confirming better end-to-end health(?: and latency)?\.$',
  ).firstMatch(trimmed);
  if (match != null) {
    return 'Переключаемся на ${_serverName(match.group(2)!)}';
  }

  match = RegExp(
    r'^Auto-selector recovered from (.+) to (.+) after the current server failed the end-to-end proxy probe\.$',
  ).firstMatch(trimmed);
  if (match != null) {
    return 'Текущий сервер не прошёл проверку, переключаемся на ${_serverName(match.group(2)!)}';
  }

  match = RegExp(
    r'^Current server (.+) failed the latest end-to-end proxy probe, and no reachable replacement was confirmed\.$',
  ).firstMatch(trimmed);
  if (match != null) {
    return 'Текущий сервер не прошёл проверку, но замена не найдена: ${_serverName(match.group(1)!)}';
  }

  match = RegExp(
    r'^Auto-selector chose (.+) using URLTest plus IP and domain probes through the local proxy\.$',
  ).firstMatch(trimmed);
  if (match != null) {
    return 'Выбрали лучший сервер ${_serverName(match.group(1)!)}';
  }

  match = RegExp(
    r'^Auto-selector chose (.+) using IP and domain probes through the local proxy after URLTest refresh was unavailable\.$',
  ).firstMatch(trimmed);
  if (match != null) {
    return 'Выбрали сервер ${_serverName(match.group(1)!)}';
  }

  match = RegExp(
    r'^Auto-selector chose (.+)\. Domain traffic worked, but the IP-only probe stayed partial\.$',
  ).firstMatch(trimmed);
  if (match != null) {
    return 'Выбрали ${_serverName(match.group(1)!)}; IP-проверка частичная';
  }

  match = RegExp(
    r'^Auto-selector chose (.+) with partial confidence\. IP-only probe worked, domain probe did not\.$',
  ).firstMatch(trimmed);
  if (match != null) {
    return 'Выбрали ${_serverName(match.group(1)!)}; доменная проверка не прошла';
  }

  if (trimmed ==
      'Could not read the current selected server from Clash API, probing candidates directly.') {
    return 'Не удалось прочитать текущий сервер, проверяем кандидатов напрямую';
  }

  if (trimmed ==
      'URLTest refresh failed, continuing with end-to-end proxy probes only.') {
    return 'Не удалось обновить пинг, продолжаем прямую проверку';
  }

  if (trimmed ==
      'No candidate passed an end-to-end proxy probe. TCP-only success is ignored by design.') {
    return 'Ни один сервер не прошёл полную проверку';
  }

  match = RegExp(
    r'^check (current|contender|recovery|candidate) (.+): (n/a|\d+ms), (domain (?:OK|failed)), (IP (?:OK|failed)), (\d+) KB/s\.$',
  ).firstMatch(trimmed);
  if (match != null) {
    final role = match.group(1)!;
    final server = _serverName(match.group(2)!);
    return switch (role) {
      'current' => 'Проверили текущий сервер: $server',
      'recovery' => 'Проверили замену: $server',
      'contender' => 'Проверили кандидата: $server',
      _ => 'Проверили сервер: $server',
    };
  }

  return trimmed
      .replaceAll(
        'Automatic maintenance failed: ',
        'Ошибка автоматической проверки: ',
      )
      .replaceAll('Manual auto-select failed: ', 'Ошибка подбора сервера: ')
      .replaceAll(
        'Pre-connect auto-select failed: ',
        'Ошибка подбора перед подключением: ',
      );
}

String describeAutoSelectTraceLine(String line) {
  final match = RegExp(
    r'^(\d{2}:\d{2}:\d{2}) \[(.+?)\] (.+)$',
  ).firstMatch(line);
  if (match == null) {
    return line;
  }

  final timestamp = match.group(1)!;
  final label = match.group(2);
  final message = match.group(3);
  final phase = describeAutoSelectActivityLabel(label);
  final summary =
      describeAutoSelectMessage(label: label, message: message) ?? message;
  return '$timestamp [$phase] $summary';
}

String _serverName(String value) {
  return normalizeServerDisplayText(value);
}

class AutoServerSelectionProgress {
  const AutoServerSelectionProgress({this.value});
  final double? value;

  @override
  bool operator ==(Object other) =>
      other is AutoServerSelectionProgress && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

final autoServerSelectionProgressProvider =
    Provider<AutoServerSelectionProgress?>((ref) {
      final activity = ref.watch(
        dashboardControllerProvider.select((s) => s.autoSelectActivity),
      );
      if (!activity.active) return null;
      return AutoServerSelectionProgress(value: activity.progressValue);
    });

class RecentAutoSelectedServer {
  const RecentAutoSelectedServer({required this.tag, required this.until});
  final String tag;
  final DateTime until;
  bool get isActive => until.isAfter(DateTime.now());
}

final recentAutoSelectedServerProvider =
    StateProvider<RecentAutoSelectedServer?>((ref) => null);
