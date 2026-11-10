import 'dart:io';

import 'package:gorion_clean/core/process/process_exception_utils.dart';
import 'package:gorion_clean/features/home/application/dashboard_state.dart';
import 'package:gorion_clean/features/runtime/model/runtime_mode.dart';
import 'package:gorion_clean/features/runtime/model/runtime_models.dart';

// User-facing status and error texts shown on the dashboard.

String pluralizeRu(int value, String one, String few, String many) {
  final mod10 = value % 10;
  final mod100 = value % 100;
  if (mod10 == 1 && mod100 != 11) {
    return one;
  }
  if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) {
    return few;
  }
  return many;
}

String describeAutoSelectBestServerCheckInterval(int minutes) {
  final hours = minutes ~/ 60;
  final remainingMinutes = minutes % 60;
  if (hours > 0 && remainingMinutes > 0) {
    return '$hours ${pluralizeRu(hours, 'час', 'часа', 'часов')} '
        '$remainingMinutes '
        '${pluralizeRu(remainingMinutes, 'минута', 'минуты', 'минут')}';
  }
  if (hours > 0) {
    return '$hours ${pluralizeRu(hours, 'час', 'часа', 'часов')}';
  }
  return '$minutes ${pluralizeRu(minutes, 'минута', 'минуты', 'минут')}';
}

String formatLiveServerPingInterval(int seconds) {
  if (seconds < 60) {
    return '$seconds сек';
  }
  final minutes = seconds ~/ 60;
  final remainingSeconds = seconds % 60;
  if (remainingSeconds == 0) {
    return '$minutes мин';
  }
  return '$minutes мин $remainingSeconds сек';
}

String fullInternetAccessFailureMessage({required String serverName}) {
  final normalizedName = serverName.trim();
  if (normalizedName.isEmpty) {
    return 'Подключение не удалось: сервер недоступен.';
  }
  return 'Подключение не удалось: $normalizedName недоступен.';
}

String internetAccessVerificationErrorMessage() {
  return 'Подключение не удалось: сервер недоступен.';
}

String connectedStatus(RuntimeSession session) {
  return switch (normalizeRuntimeMode(session.mode)) {
    RuntimeMode.mixed =>
      'Подключение через локальный прокси активно на ${session.mixedProxyAddress}. Используйте этот адрес в приложениях вручную или переключитесь на системный прокси/TUN.',
    RuntimeMode.systemProxy =>
      'Подключение через системный прокси активно. Трафик приложений, которые используют системный прокси, теперь идёт через ${session.mixedProxyAddress}.',
    RuntimeMode.tun =>
      'Подключение через TUN активно. Системный трафик маршрутизируется через sing-box, а mixed-inbound остаётся доступен на ${session.mixedProxyAddress}.',
  };
}

String disconnectedStatus(RuntimeSession? previousSession) {
  return switch (previousSession == null
      ? null
      : normalizeRuntimeMode(previousSession.mode)) {
    RuntimeMode.systemProxy =>
      'Локальный runtime sing-box остановлен, прежние системные настройки прокси восстановлены.',
    RuntimeMode.tun ||
    RuntimeMode.mixed ||
    null => 'Локальный runtime sing-box остановлен.',
  };
}

String modeSelectionStatus(RuntimeMode mode) {
  return switch (normalizeRuntimeMode(mode)) {
    RuntimeMode.mixed =>
      'Выбран режим локального прокси. После подключения укажите mixed-inbound в приложениях вручную.',
    RuntimeMode.systemProxy =>
      'Выбран режим системного прокси. Подключитесь, чтобы направить через него браузеры и приложения, которые используют системный прокси.',
    RuntimeMode.tun =>
      'Выбран режим TUN. Подключитесь, чтобы направить системный трафик через sing-box.',
  };
}

String connectionErrorMessage(Object error, RuntimeMode mode) {
  if (error is ProcessException && isProcessElevationRequired(error)) {
    return 'Запуск TUN требует прав администратора. Подтвердите системный запрос или перезапустите Gorion с правами администратора.';
  }

  final message = error.toString();
  return switch (normalizeRuntimeMode(mode)) {
    RuntimeMode.tun =>
      '$message Режим TUN может требовать повышенных прав на этой платформе.',
    _ => message,
  };
}
