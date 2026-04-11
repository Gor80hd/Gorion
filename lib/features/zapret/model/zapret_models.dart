// ignore_for_file: use_null_aware_elements

import 'package:path/path.dart' as p;

String formatZapretConfigLabel(String fileName) {
  final trimmed = p.basename(fileName.trim());
  final normalized = trimmed.toLowerCase();
  for (final suffix in <String>['.conf', '.bat']) {
    if (normalized.endsWith(suffix)) {
      return trimmed.substring(0, trimmed.length - suffix.length);
    }
  }
  return trimmed;
}

enum ZapretPreset {
  recommended(
    'recommended',
    'Рекомендуемый',
    'Сбалансированный пресет для YouTube, голосового Discord и типичного заблокированного трафика.',
  ),
  youtube(
    'youtube',
    'YouTube',
    'Точечный пресет для YouTube через TLS и QUIC.',
  ),
  discord(
    'discord',
    'Голосовой Discord',
    'Низколатентный пресет для голосового Discord и сопутствующего медиатрафика.',
  ),
  combined(
    'combined',
    'Комбинированный усиленный',
    'Более широкий пресет, который совмещает правила для YouTube и Discord с общим резервным HTTPS-профилем.',
  );

  const ZapretPreset(this.jsonValue, this.label, this.description);

  final String jsonValue;
  final String label;
  final String description;

  static ZapretPreset fromJsonValue(dynamic value) {
    final normalized = value?.toString().trim().toLowerCase();
    for (final preset in values) {
      if (preset.jsonValue == normalized) {
        return preset;
      }
    }
    return ZapretPreset.recommended;
  }

  ZapretStrategyProfile get defaultStrategy => switch (this) {
    ZapretPreset.recommended => ZapretStrategyProfile.balancedDefault,
    ZapretPreset.youtube => ZapretStrategyProfile.balancedDefault,
    ZapretPreset.discord => ZapretStrategyProfile.balancedDefault,
    ZapretPreset.combined => ZapretStrategyProfile.combinedDefault,
  };
}

enum ZapretStrategyProfile {
  balancedDefault(
    'balanced-default',
    'Баланс',
    'Базовый профиль для YouTube и Discord без общего HTTPS fallback.',
  ),
  balancedStrong(
    'balanced-strong',
    'Баланс+',
    'Базовый профиль с более агрессивным TLS fallback и усиленными split-параметрами.',
  ),
  balancedSplit(
    'balanced-split',
    'Баланс split',
    'Базовый профиль с fake+fakedsplit по TLS-маркерам для сетей, где обычный multidisorder не проходит.',
  ),
  balancedDisorder(
    'balanced-disorder',
    'Баланс disorder',
    'Базовый профиль с fake+fakeddisorder и перестановкой сегментов для более жёсткого DPI.',
  ),
  combinedDefault(
    'combined-default',
    'Комбинированный',
    'YouTube, Discord и общий HTTPS fallback для типичного набора блокировок.',
  ),
  combinedStrong(
    'combined-strong',
    'Комбинированный+',
    'Расширенный профиль с усиленным fallback и более широким TLS/QUIC десинком.',
  ),
  combinedSplit(
    'combined-split',
    'Комбинированный split',
    'YouTube, Discord и общий HTTPS fallback с fake+fakedsplit по midsld.',
  ),
  combinedDisorder(
    'combined-disorder',
    'Комбинированный disorder',
    'YouTube, Discord и общий HTTPS fallback с fake+fakeddisorder для тяжёлых блокировок.',
  );

  const ZapretStrategyProfile(this.jsonValue, this.label, this.description);

  final String jsonValue;
  final String label;
  final String description;

  static ZapretStrategyProfile? fromJsonValue(dynamic value) {
    final normalized = value?.toString().trim().toLowerCase();
    for (final strategy in values) {
      if (strategy.jsonValue == normalized) {
        return strategy;
      }
    }
    return null;
  }
}

enum ZapretFlowsealVariant {
  simpleFake(
    'simplefake',
    'SimpleFake',
    'Чистый fake без split/disorder follow-up, как в рабочих Flowseal SIMPLE FAKE профилях.',
  ),
  simpleFakeMaxRu(
    'simplefake-maxru',
    'SimpleFake MaxRu',
    'Чистый fake; для общего HTTPS-блока использует max.ru blob без tls_mod, как в SIMPLE FAKE ALT2.',
  ),
  simpleFake4Pda(
    'simplefake-4pda',
    'SimpleFake 4PDA',
    'Чистый fake; для общего HTTPS-блока использует 4pda/max.ru blob без tls_mod, как в ALT10.',
  ),
  fakedsplit(
    'fakedsplit',
    'FakeSplit',
    'fake + fakedsplit с наложением seqovl на TLS-маркере.',
  ),
  multisplit(
    'multisplit',
    'MultiSplit',
    'Flowseal-style fake + multisplit с seqovl pattern на TLS fake blob.',
  ),
  multisplitMaxRu(
    'multisplit-maxru',
    'MultiSplit MaxRu',
    'Flowseal-style fake + multisplit; для общего HTTPS-блока использует max.ru blob, как в ALT11.',
  ),
  hostfakesplit(
    'hostfakesplit',
    'HostFakeSplit',
    'fake + hostfakesplit с подменой host/SNI и altorder.',
  ),
  multidisorder(
    'multidisorder',
    'MultiDisorder',
    'fake + multidisorder с перестановкой сегментов по midsld.',
  );

  const ZapretFlowsealVariant(this.jsonValue, this.label, this.description);

  final String jsonValue;
  final String label;
  final String description;

  static ZapretFlowsealVariant fromJsonValue(dynamic value) {
    final normalized = value?.toString().trim().toLowerCase();
    for (final variant in values) {
      if (variant.jsonValue == normalized) {
        return variant;
      }
    }
    return ZapretFlowsealVariant.simpleFake;
  }
}

class ZapretCustomProfile {
  factory ZapretCustomProfile({
    ZapretFlowsealBlockProfile? youtube,
    ZapretFlowsealBlockProfile? discord,
    ZapretFlowsealBlockProfile? generic,
    ZapretFlowsealVariant youtubeVariant = ZapretFlowsealVariant.simpleFake,
    ZapretFlowsealVariant discordVariant = ZapretFlowsealVariant.simpleFake,
    ZapretFlowsealVariant genericVariant = ZapretFlowsealVariant.simpleFake,
  }) {
    return ZapretCustomProfile._(
      youtube:
          youtube ??
          ZapretFlowsealBlockProfile(enabled: true, variant: youtubeVariant),
      discord:
          discord ??
          ZapretFlowsealBlockProfile(enabled: true, variant: discordVariant),
      generic:
          generic ??
          ZapretFlowsealBlockProfile(enabled: true, variant: genericVariant),
    );
  }

  const ZapretCustomProfile._({
    required this.youtube,
    required this.discord,
    required this.generic,
  });

  final ZapretFlowsealBlockProfile youtube;
  final ZapretFlowsealBlockProfile discord;
  final ZapretFlowsealBlockProfile generic;

  ZapretFlowsealVariant get youtubeVariant => youtube.variant;
  ZapretFlowsealVariant get discordVariant => discord.variant;
  ZapretFlowsealVariant get genericVariant => generic.variant;

  bool get youtubeEnabled => youtube.enabled;
  bool get discordEnabled => discord.enabled;
  bool get genericEnabled => generic.enabled;

  static ZapretCustomProfile fromLegacy({
    required ZapretPreset preset,
    required ZapretStrategyProfile strategy,
  }) {
    final youtubeVariant = switch (strategy) {
      ZapretStrategyProfile.balancedStrong ||
      ZapretStrategyProfile.combinedStrong => ZapretFlowsealVariant.multisplit,
      ZapretStrategyProfile.balancedDisorder ||
      ZapretStrategyProfile.combinedDisorder =>
        ZapretFlowsealVariant.multidisorder,
      _ => ZapretFlowsealVariant.simpleFake,
    };
    final discordVariant = switch (strategy) {
      ZapretStrategyProfile.balancedDisorder ||
      ZapretStrategyProfile.combinedDisorder =>
        ZapretFlowsealVariant.multidisorder,
      ZapretStrategyProfile.balancedSplit ||
      ZapretStrategyProfile.combinedSplit =>
        ZapretFlowsealVariant.hostfakesplit,
      _ =>
        preset == ZapretPreset.youtube
            ? ZapretFlowsealVariant.simpleFake
            : ZapretFlowsealVariant.simpleFake,
    };
    final genericVariant = switch (strategy) {
      ZapretStrategyProfile.balancedStrong ||
      ZapretStrategyProfile.combinedStrong => ZapretFlowsealVariant.multisplit,
      ZapretStrategyProfile.balancedDisorder ||
      ZapretStrategyProfile.combinedDisorder =>
        ZapretFlowsealVariant.multidisorder,
      _ =>
        preset == ZapretPreset.combined
            ? ZapretFlowsealVariant.simpleFakeMaxRu
            : ZapretFlowsealVariant.simpleFake,
    };
    return ZapretCustomProfile(
      youtube: ZapretFlowsealBlockProfile(
        enabled: true,
        variant: youtubeVariant,
      ),
      discord: ZapretFlowsealBlockProfile(
        enabled: true,
        variant: discordVariant,
      ),
      generic: ZapretFlowsealBlockProfile(
        enabled: true,
        variant: genericVariant,
      ),
    );
  }

  String get summaryLabel {
    return 'YT ${youtube.summaryLabel} • Discord ${discord.summaryLabel} • HTTPS ${generic.summaryLabel}';
  }

  ZapretCustomProfile copyWith({
    ZapretFlowsealBlockProfile? youtube,
    ZapretFlowsealBlockProfile? discord,
    ZapretFlowsealBlockProfile? generic,
    ZapretFlowsealVariant? youtubeVariant,
    ZapretFlowsealVariant? discordVariant,
    ZapretFlowsealVariant? genericVariant,
    bool? youtubeEnabled,
    bool? discordEnabled,
    bool? genericEnabled,
  }) {
    return ZapretCustomProfile(
      youtube:
          youtube ??
          this.youtube.copyWith(
            enabled: youtubeEnabled,
            variant: youtubeVariant,
          ),
      discord:
          discord ??
          this.discord.copyWith(
            enabled: discordEnabled,
            variant: discordVariant,
          ),
      generic:
          generic ??
          this.generic.copyWith(
            enabled: genericEnabled,
            variant: genericVariant,
          ),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'youtube': youtube.toJson(),
      'discord': discord.toJson(),
      'generic': generic.toJson(),
    };
  }

  factory ZapretCustomProfile.fromJson(Map<String, dynamic> json) {
    ZapretFlowsealBlockProfile parseBlock(String key, String legacyKey) {
      final nested = json[key];
      if (nested is Map<String, dynamic>) {
        return ZapretFlowsealBlockProfile.fromJson(nested);
      }
      if (nested is Map) {
        return ZapretFlowsealBlockProfile.fromJson(
          Map<String, dynamic>.from(nested.cast<String, dynamic>()),
        );
      }
      return ZapretFlowsealBlockProfile(
        enabled: true,
        variant: ZapretFlowsealVariant.fromJsonValue(json[legacyKey]),
      );
    }

    return ZapretCustomProfile(
      youtube: parseBlock('youtube', 'youtubeVariant'),
      discord: parseBlock('discord', 'discordVariant'),
      generic: parseBlock('generic', 'genericVariant'),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ZapretCustomProfile &&
        other.youtube == youtube &&
        other.discord == discord &&
        other.generic == generic;
  }

  @override
  int get hashCode => Object.hash(youtube, discord, generic);
}

class ZapretFlowsealBlockProfile {
  const ZapretFlowsealBlockProfile({
    required this.enabled,
    required this.variant,
  });

  final bool enabled;
  final ZapretFlowsealVariant variant;

  String get summaryLabel => enabled ? variant.label : 'Off';

  String get description {
    if (!enabled) {
      return 'Блок отключён.';
    }
    return variant.description;
  }

  ZapretFlowsealBlockProfile copyWith({
    bool? enabled,
    ZapretFlowsealVariant? variant,
  }) {
    return ZapretFlowsealBlockProfile(
      enabled: enabled ?? this.enabled,
      variant: variant ?? this.variant,
    );
  }

  Map<String, dynamic> toJson() {
    return {'enabled': enabled, 'variant': variant.jsonValue};
  }

  factory ZapretFlowsealBlockProfile.fromJson(Map<String, dynamic> json) {
    return ZapretFlowsealBlockProfile(
      enabled: json['enabled'] as bool? ?? true,
      variant: ZapretFlowsealVariant.fromJsonValue(
        json['variant'] ?? json['youtubeVariant'] ?? json['discordVariant'],
      ),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ZapretFlowsealBlockProfile &&
        other.enabled == enabled &&
        other.variant == variant;
  }

  @override
  int get hashCode => Object.hash(enabled, variant);
}

enum ZapretIpSetFilterMode {
  none('none', 'Без IPSet'),
  any('any', 'Любой найденный');

  const ZapretIpSetFilterMode(this.jsonValue, this.label);

  final String jsonValue;
  final String label;

  static ZapretIpSetFilterMode fromJsonValue(dynamic value) {
    final normalized = value?.toString().trim().toLowerCase();
    for (final mode in values) {
      if (mode.jsonValue == normalized) {
        return mode;
      }
    }
    return ZapretIpSetFilterMode.none;
  }
}

enum ZapretGameFilterMode {
  disabled('disabled', 'Отключён', '12', '12'),
  all('all', 'TCP и UDP', '1024-65535', '1024-65535'),
  tcp('tcp', 'Только TCP', '1024-65535', '12'),
  udp('udp', 'Только UDP', '12', '1024-65535');

  const ZapretGameFilterMode(
    this.jsonValue,
    this.label,
    this.tcpValue,
    this.udpValue,
  );

  final String jsonValue;
  final String label;
  final String tcpValue;
  final String udpValue;

  bool get enabled => this != ZapretGameFilterMode.disabled;

  static ZapretGameFilterMode fromJsonValue(dynamic value) {
    if (value is bool) {
      return value ? ZapretGameFilterMode.all : ZapretGameFilterMode.disabled;
    }

    final normalized = value?.toString().trim().toLowerCase();
    for (final mode in values) {
      if (mode.jsonValue == normalized) {
        return mode;
      }
    }

    return switch (normalized) {
      'true' => ZapretGameFilterMode.all,
      'false' ||
      'none' ||
      'off' ||
      'disable' ||
      'disabled' => ZapretGameFilterMode.disabled,
      _ => ZapretGameFilterMode.disabled,
    };
  }
}

class ZapretConfigOption {
  const ZapretConfigOption({required this.fileName, required this.path});

  final String fileName;
  final String path;

  String get label => formatZapretConfigLabel(fileName);

  @override
  bool operator ==(Object other) {
    return other is ZapretConfigOption &&
        other.fileName == fileName &&
        other.path == path;
  }

  @override
  int get hashCode => Object.hash(fileName, path);
}

enum ZapretStage {
  stopped,
  starting,
  running,
  stopping,
  failed,
  pausedByTun;

  String get label => switch (this) {
    ZapretStage.stopped => 'Остановлен',
    ZapretStage.starting => 'Запуск',
    ZapretStage.running => 'Работает',
    ZapretStage.stopping => 'Остановка',
    ZapretStage.failed => 'Ошибка',
    ZapretStage.pausedByTun => 'Пауза из-за TUN',
  };
}

enum ZapretProbeKind {
  http11,
  tls12,
  tls13,
  http11Get,
  tls12Get,
  tls13Get,
  websocket,
  ping,
}

class ZapretProbeTarget {
  const ZapretProbeTarget({
    required this.id,
    required this.label,
    required this.kind,
    required this.address,
    this.requiredForSuccess = true,
  });

  final String id;
  final String label;
  final ZapretProbeKind kind;
  final String address;
  final bool requiredForSuccess;
}

class ZapretProbeResult {
  const ZapretProbeResult({
    required this.target,
    required this.success,
    this.latencyMs,
    this.details,
  });

  final ZapretProbeTarget target;
  final bool success;
  final int? latencyMs;
  final String? details;

  String get summary {
    final suffix = latencyMs == null ? null : '$latencyMs ms';
    final detailText = details == null || details!.trim().isEmpty
        ? null
        : details!.trim();
    final description = [
      if (suffix != null) suffix,
      if (detailText != null) detailText,
    ].join(' • ');
    if (description.isEmpty) {
      return '${target.label}: ${success ? 'ok' : 'fail'}';
    }
    return '${target.label}: ${success ? 'ok' : 'fail'} • $description';
  }
}

class ZapretProbeReport {
  const ZapretProbeReport({required this.results});

  final List<ZapretProbeResult> results;

  Iterable<ZapretProbeResult> get requiredResults {
    return results.where((result) => result.target.requiredForSuccess);
  }

  Iterable<ZapretProbeResult> get passedRequiredResults {
    return requiredResults.where((result) => result.success);
  }

  Iterable<ZapretProbeResult> get failedRequiredResults {
    return requiredResults.where((result) => !result.success);
  }

  int get requiredTotalCount {
    return requiredResults.length;
  }

  int get requiredPassedCount {
    return passedRequiredResults.length;
  }

  bool get allRequiredPassed {
    return requiredResults.every((result) => result.success);
  }

  String get summary {
    if (requiredTotalCount == 0) {
      return 'Нет обязательных проверок.';
    }

    final failedLabels = failedRequiredResults
        .map((result) => result.target.label)
        .join(', ');
    if (failedLabels.isEmpty) {
      return 'Обязательные проверки пройдены: $requiredPassedCount/$requiredTotalCount.';
    }
    return 'Пройдено $requiredPassedCount/$requiredTotalCount; не прошли: $failedLabels.';
  }
}

class ZapretConfigTestResult {
  const ZapretConfigTestResult({
    required this.config,
    required this.report,
    this.launchError,
  });

  final ZapretConfigOption config;
  final ZapretProbeReport report;
  final String? launchError;

  bool get launchSucceeded => launchError == null;

  bool get failedTesting {
    return launchSucceeded && successCount == 0;
  }

  bool get partiallyWorking {
    return launchSucceeded && successCount > 0 && !fullyWorking;
  }

  bool get fullyWorking {
    return launchSucceeded &&
        report.requiredTotalCount > 0 &&
        report.allRequiredPassed;
  }

  int get successCount => report.requiredPassedCount;

  int get failureCount =>
      report.requiredTotalCount - report.requiredPassedCount;

  int get pingSuccessCount {
    return report.results
        .where(
          (result) =>
              !result.target.requiredForSuccess &&
              result.target.kind == ZapretProbeKind.ping &&
              result.success,
        )
        .length;
  }

  int? get averageLatencyMs {
    final latencies = report.passedRequiredResults
        .map((result) => result.latencyMs)
        .whereType<int>()
        .toList();
    if (latencies.isEmpty) {
      return null;
    }
    final total = latencies.reduce((left, right) => left + right);
    return (total / latencies.length).round();
  }

  int? get totalLatencyMs {
    final latencies = report.passedRequiredResults
        .map((result) => result.latencyMs)
        .whereType<int>()
        .toList();
    if (latencies.isEmpty) {
      return null;
    }
    return latencies.reduce((left, right) => left + right);
  }

  String get scoreLabel {
    final latency = averageLatencyMs;
    final latencyLabel = latency == null
        ? 'нет замеров'
        : 'в среднем $latency ms';
    if (!launchSucceeded) {
      return 'Не запустился';
    }
    return '$successCount/${report.requiredTotalCount} основных проверок • ping ok: $pingSuccessCount • $latencyLabel';
  }

  String get summary {
    if (launchError case final message?) {
      return '${config.label}: не запустился • $message';
    }
    if (fullyWorking) {
      return '${config.label}: всё прошло • $scoreLabel';
    }
    if (failedTesting) {
      return '${config.label}: провал тестирования • $scoreLabel';
    }
    final failedLabels = report.failedRequiredResults
        .map((result) => result.target.label)
        .join(', ');
    final suffix = failedLabels.isEmpty
        ? scoreLabel
        : '$scoreLabel • сбои: $failedLabels';
    return '${config.label}: частично • $suffix';
  }
}

class ZapretConfigTestSuite {
  const ZapretConfigTestSuite({
    required this.targets,
    required this.results,
    required this.targetsPath,
    this.ignoredTargetCount = 0,
  });

  final List<ZapretProbeTarget> targets;
  final List<ZapretConfigTestResult> results;
  final String targetsPath;
  final int ignoredTargetCount;

  ZapretConfigTestResult? get bestResult {
    if (results.isEmpty) {
      return null;
    }
    return results.first;
  }

  ZapretConfigTestResult? get bestWorkingResult {
    for (final result in results) {
      if (result.fullyWorking) {
        return result;
      }
    }
    return null;
  }

  Iterable<ZapretConfigTestResult> get fullyWorkingResults {
    return results.where((result) => result.fullyWorking);
  }

  Iterable<ZapretConfigTestResult> get alternativeWorkingResults {
    final bestWorking = bestWorkingResult;
    return fullyWorkingResults.where((result) => result != bestWorking);
  }

  Iterable<ZapretConfigTestResult> get partialResults {
    return results.where((result) => result.partiallyWorking);
  }

  Iterable<ZapretConfigTestResult> get failedToLaunchResults {
    return results.where((result) => !result.launchSucceeded);
  }

  String get summary {
    final bestWorking = bestWorkingResult;
    if (bestWorking != null) {
      return 'Лучший конфиг: ${bestWorking.config.label}. Полностью прошли ${fullyWorkingResults.length}/${results.length}.';
    }

    final fallback = bestResult;
    if (fallback == null) {
      return 'Тесты не дали результатов.';
    }

    if (!fallback.launchSucceeded || fallback.failedTesting) {
      return 'Тестирование провалено: ни один конфиг не прошёл основные проверки.';
    }

    return 'Полностью рабочий конфиг не найден. Лучший доступный вариант: ${fallback.config.label} (${fallback.successCount}/${fallback.report.requiredTotalCount}).';
  }
}

class ZapretRuntimeSession {
  const ZapretRuntimeSession({
    required this.executablePath,
    required this.workingDirectory,
    required this.processId,
    required this.startedAt,
    required this.arguments,
    required this.commandPreview,
  });

  final String executablePath;
  final String workingDirectory;
  final int processId;
  final DateTime startedAt;
  final List<String> arguments;
  final String commandPreview;
}

class ZapretLaunchConfiguration {
  const ZapretLaunchConfiguration({
    required this.executablePath,
    required this.workingDirectory,
    required this.arguments,
    required this.requiredFiles,
    required this.preview,
    required this.summary,
  });

  final String executablePath;
  final String workingDirectory;
  final List<String> arguments;
  final List<String> requiredFiles;
  final String preview;
  final String summary;
}
