import 'package:gorion_clean/features/zapret/model/zapret_models.dart';

class ZapretSettings {
  const ZapretSettings({
    this.installDirectory = '',
    this.configFileName = 'general.conf',
    ZapretGameFilterMode? gameFilterMode,
    bool gameFilterEnabled = false,
    this.preset = ZapretPreset.recommended,
    this.strategyProfile,
    this.customProfile,
    this.ipSetFilterMode = ZapretIpSetFilterMode.none,
    this.startOnAppLaunch = false,
  }) : gameFilterMode =
           gameFilterMode ??
           (gameFilterEnabled
               ? ZapretGameFilterMode.all
               : ZapretGameFilterMode.disabled);

  final String installDirectory;
  final String configFileName;
  final ZapretGameFilterMode gameFilterMode;
  final ZapretPreset preset;
  final ZapretStrategyProfile? strategyProfile;
  final ZapretCustomProfile? customProfile;
  final ZapretIpSetFilterMode ipSetFilterMode;
  final bool startOnAppLaunch;
  // This guard is always enabled; we still serialize it for compatibility.
  final bool autoStopOnTun = true;

  String get normalizedInstallDirectory => installDirectory.trim();

  String get normalizedConfigFileName => configFileName.trim();

  bool get hasInstallDirectory => normalizedInstallDirectory.isNotEmpty;

  bool get hasCustomProfile => customProfile != null;

  bool get gameFilterEnabled => gameFilterMode.enabled;

  String get effectiveConfigFileName {
    return normalizedConfigFileName.isEmpty
        ? 'general.conf'
        : normalizedConfigFileName;
  }

  String get effectiveConfigLabel =>
      formatZapretConfigLabel(effectiveConfigFileName);

  ZapretCustomProfile get effectiveCustomProfile {
    return customProfile ??
        ZapretCustomProfile.fromLegacy(
          preset: preset,
          strategy: effectiveStrategy,
        );
  }

  ZapretStrategyProfile get effectiveStrategy {
    return strategyProfile ?? preset.defaultStrategy;
  }

  ZapretSettings copyWith({
    String? installDirectory,
    String? configFileName,
    ZapretGameFilterMode? gameFilterMode,
    ZapretPreset? preset,
    ZapretStrategyProfile? strategyProfile,
    bool clearStrategyProfile = false,
    ZapretCustomProfile? customProfile,
    bool clearCustomProfile = false,
    bool? gameFilterEnabled,
    ZapretIpSetFilterMode? ipSetFilterMode,
    bool? startOnAppLaunch,
  }) {
    return ZapretSettings(
      installDirectory: (installDirectory ?? this.installDirectory).trim(),
      configFileName: (configFileName ?? this.configFileName).trim(),
      gameFilterMode:
          gameFilterMode ??
          (gameFilterEnabled == null
              ? this.gameFilterMode
              : gameFilterEnabled
              ? ZapretGameFilterMode.all
              : ZapretGameFilterMode.disabled),
      preset: preset ?? this.preset,
      strategyProfile: clearStrategyProfile
          ? null
          : strategyProfile ?? this.strategyProfile,
      customProfile: clearCustomProfile
          ? null
          : customProfile ?? this.customProfile,
      ipSetFilterMode: ipSetFilterMode ?? this.ipSetFilterMode,
      startOnAppLaunch: startOnAppLaunch ?? this.startOnAppLaunch,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'installDirectory': normalizedInstallDirectory,
      'configFileName': effectiveConfigFileName,
      'gameFilterMode': gameFilterMode.jsonValue,
      'gameFilterEnabled': gameFilterEnabled,
      'preset': preset.jsonValue,
      'strategyProfile': strategyProfile?.jsonValue,
      'customProfile': customProfile?.toJson(),
      'ipSetFilterMode': ipSetFilterMode.jsonValue,
      'startOnAppLaunch': startOnAppLaunch,
      'autoStopOnTun': autoStopOnTun,
    };
  }

  factory ZapretSettings.fromJson(Map<String, dynamic> json) {
    return ZapretSettings(
      installDirectory: json['installDirectory']?.toString().trim() ?? '',
      configFileName:
          json['configFileName']?.toString().trim() ?? 'general.conf',
      gameFilterMode: ZapretGameFilterMode.fromJsonValue(
        json['gameFilterMode'] ?? json['gameFilterEnabled'],
      ),
      preset: ZapretPreset.fromJsonValue(json['preset']),
      strategyProfile: ZapretStrategyProfile.fromJsonValue(
        json['strategyProfile'],
      ),
      customProfile: switch (json['customProfile']) {
        final Map<String, dynamic> value => ZapretCustomProfile.fromJson(value),
        final Map value => ZapretCustomProfile.fromJson(
          Map<String, dynamic>.from(value.cast<String, dynamic>()),
        ),
        _ => null,
      },
      ipSetFilterMode: ZapretIpSetFilterMode.fromJsonValue(
        json['ipSetFilterMode'],
      ),
      startOnAppLaunch: json['startOnAppLaunch'] as bool? ?? false,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ZapretSettings &&
        other.normalizedInstallDirectory == normalizedInstallDirectory &&
        other.effectiveConfigFileName == effectiveConfigFileName &&
        other.gameFilterMode == gameFilterMode &&
        other.preset == preset &&
        other.strategyProfile == strategyProfile &&
        other.customProfile == customProfile &&
        other.ipSetFilterMode == ipSetFilterMode &&
        other.startOnAppLaunch == startOnAppLaunch &&
        other.autoStopOnTun == autoStopOnTun;
  }

  @override
  int get hashCode => Object.hash(
    normalizedInstallDirectory,
    effectiveConfigFileName,
    gameFilterMode,
    preset,
    strategyProfile,
    customProfile,
    ipSetFilterMode,
    startOnAppLaunch,
    autoStopOnTun,
  );
}
