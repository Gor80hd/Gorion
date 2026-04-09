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
  fakedsplit(
    'fakedsplit',
    'FakeSplit',
    'fake + fakedsplit с наложением seqovl на TLS-маркере.',
  ),
  multisplit(
    'multisplit',
    'MultiSplit',
    'multisplit с отдельным seqovl pattern без лишних follow-up блоков.',
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
    return ZapretFlowsealVariant.fakedsplit;
  }
}

class ZapretCustomProfile {
  const ZapretCustomProfile({
    this.youtubeVariant = ZapretFlowsealVariant.fakedsplit,
    this.discordVariant = ZapretFlowsealVariant.fakedsplit,
    this.genericVariant = ZapretFlowsealVariant.fakedsplit,
  });

  final ZapretFlowsealVariant youtubeVariant;
  final ZapretFlowsealVariant discordVariant;
  final ZapretFlowsealVariant genericVariant;

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
      _ => ZapretFlowsealVariant.fakedsplit,
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
            ? ZapretFlowsealVariant.fakedsplit
            : ZapretFlowsealVariant.hostfakesplit,
    };
    final genericVariant = switch (strategy) {
      ZapretStrategyProfile.balancedStrong ||
      ZapretStrategyProfile.combinedStrong => ZapretFlowsealVariant.multisplit,
      ZapretStrategyProfile.balancedDisorder ||
      ZapretStrategyProfile.combinedDisorder =>
        ZapretFlowsealVariant.multidisorder,
      _ =>
        preset == ZapretPreset.combined
            ? ZapretFlowsealVariant.multidisorder
            : ZapretFlowsealVariant.fakedsplit,
    };
    return ZapretCustomProfile(
      youtubeVariant: youtubeVariant,
      discordVariant: discordVariant,
      genericVariant: genericVariant,
    );
  }

  String get summaryLabel {
    return 'YT ${youtubeVariant.label} • Discord ${discordVariant.label} • HTTPS ${genericVariant.label}';
  }

  ZapretCustomProfile copyWith({
    ZapretFlowsealVariant? youtubeVariant,
    ZapretFlowsealVariant? discordVariant,
    ZapretFlowsealVariant? genericVariant,
  }) {
    return ZapretCustomProfile(
      youtubeVariant: youtubeVariant ?? this.youtubeVariant,
      discordVariant: discordVariant ?? this.discordVariant,
      genericVariant: genericVariant ?? this.genericVariant,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'youtubeVariant': youtubeVariant.jsonValue,
      'discordVariant': discordVariant.jsonValue,
      'genericVariant': genericVariant.jsonValue,
    };
  }

  factory ZapretCustomProfile.fromJson(Map<String, dynamic> json) {
    return ZapretCustomProfile(
      youtubeVariant: ZapretFlowsealVariant.fromJsonValue(
        json['youtubeVariant'],
      ),
      discordVariant: ZapretFlowsealVariant.fromJsonValue(
        json['discordVariant'],
      ),
      genericVariant: ZapretFlowsealVariant.fromJsonValue(
        json['genericVariant'],
      ),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ZapretCustomProfile &&
        other.youtubeVariant == youtubeVariant &&
        other.discordVariant == discordVariant &&
        other.genericVariant == genericVariant;
  }

  @override
  int get hashCode =>
      Object.hash(youtubeVariant, discordVariant, genericVariant);
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

enum ZapretProbeKind { http, ping }

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
    final suffix = latencyMs == null ? null : '${latencyMs} ms';
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
    required this.workingDirectory,
    required this.arguments,
    required this.requiredFiles,
    required this.preview,
    required this.summary,
  });

  final String workingDirectory;
  final List<String> arguments;
  final List<String> requiredFiles;
  final String preview;
  final String summary;
}
