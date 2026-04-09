import 'package:gorion_clean/features/zapret/model/zapret_models.dart';

class ZapretSettings {
  const ZapretSettings({
    this.installDirectory = '',
    this.preset = ZapretPreset.recommended,
    this.strategyProfile,
    this.customProfile,
    this.gameFilterEnabled = false,
    this.ipSetFilterMode = ZapretIpSetFilterMode.none,
    this.startOnAppLaunch = false,
    this.autoStopOnTun = true,
  });

  final String installDirectory;
  final ZapretPreset preset;
  final ZapretStrategyProfile? strategyProfile;
  final ZapretCustomProfile? customProfile;
  final bool gameFilterEnabled;
  final ZapretIpSetFilterMode ipSetFilterMode;
  final bool startOnAppLaunch;
  final bool autoStopOnTun;

  String get normalizedInstallDirectory => installDirectory.trim();

  bool get hasInstallDirectory => normalizedInstallDirectory.isNotEmpty;

  bool get hasCustomProfile => customProfile != null;

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
    ZapretPreset? preset,
    ZapretStrategyProfile? strategyProfile,
    bool clearStrategyProfile = false,
    ZapretCustomProfile? customProfile,
    bool clearCustomProfile = false,
    bool? gameFilterEnabled,
    ZapretIpSetFilterMode? ipSetFilterMode,
    bool? startOnAppLaunch,
    bool? autoStopOnTun,
  }) {
    return ZapretSettings(
      installDirectory: (installDirectory ?? this.installDirectory).trim(),
      preset: preset ?? this.preset,
      strategyProfile: clearStrategyProfile
          ? null
          : strategyProfile ?? this.strategyProfile,
      customProfile: clearCustomProfile
          ? null
          : customProfile ?? this.customProfile,
      gameFilterEnabled: gameFilterEnabled ?? this.gameFilterEnabled,
      ipSetFilterMode: ipSetFilterMode ?? this.ipSetFilterMode,
      startOnAppLaunch: startOnAppLaunch ?? this.startOnAppLaunch,
      autoStopOnTun: autoStopOnTun ?? this.autoStopOnTun,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'installDirectory': normalizedInstallDirectory,
      'preset': preset.jsonValue,
      'strategyProfile': strategyProfile?.jsonValue,
      'customProfile': customProfile?.toJson(),
      'gameFilterEnabled': gameFilterEnabled,
      'ipSetFilterMode': ipSetFilterMode.jsonValue,
      'startOnAppLaunch': startOnAppLaunch,
      'autoStopOnTun': autoStopOnTun,
    };
  }

  factory ZapretSettings.fromJson(Map<String, dynamic> json) {
    return ZapretSettings(
      installDirectory: json['installDirectory']?.toString().trim() ?? '',
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
      gameFilterEnabled: json['gameFilterEnabled'] as bool? ?? false,
      ipSetFilterMode: ZapretIpSetFilterMode.fromJsonValue(
        json['ipSetFilterMode'],
      ),
      startOnAppLaunch: json['startOnAppLaunch'] as bool? ?? false,
      autoStopOnTun: json['autoStopOnTun'] as bool? ?? true,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ZapretSettings &&
        other.normalizedInstallDirectory == normalizedInstallDirectory &&
        other.preset == preset &&
        other.strategyProfile == strategyProfile &&
        other.customProfile == customProfile &&
        other.gameFilterEnabled == gameFilterEnabled &&
        other.ipSetFilterMode == ipSetFilterMode &&
        other.startOnAppLaunch == startOnAppLaunch &&
        other.autoStopOnTun == autoStopOnTun;
  }

  @override
  int get hashCode => Object.hash(
    normalizedInstallDirectory,
    preset,
    strategyProfile,
    customProfile,
    gameFilterEnabled,
    ipSetFilterMode,
    startOnAppLaunch,
    autoStopOnTun,
  );
}
