class DesktopSettings {
  const DesktopSettings({
    this.launchMinimized = false,
    this.keepRunningInTrayOnClose = true,
    this.autoConnectOnLaunch = false,
  });

  final bool launchMinimized;
  final bool keepRunningInTrayOnClose;
  final bool autoConnectOnLaunch;

  DesktopSettings copyWith({
    bool? launchMinimized,
    bool? keepRunningInTrayOnClose,
    bool? autoConnectOnLaunch,
  }) {
    return DesktopSettings(
      launchMinimized: launchMinimized ?? this.launchMinimized,
      keepRunningInTrayOnClose:
          keepRunningInTrayOnClose ?? this.keepRunningInTrayOnClose,
      autoConnectOnLaunch: autoConnectOnLaunch ?? this.autoConnectOnLaunch,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'launchMinimized': launchMinimized,
      'keepRunningInTrayOnClose': keepRunningInTrayOnClose,
      'autoConnectOnLaunch': autoConnectOnLaunch,
    };
  }

  factory DesktopSettings.fromJson(Map<String, dynamic> json) {
    return DesktopSettings(
      launchMinimized: json['launchMinimized'] as bool? ?? false,
      keepRunningInTrayOnClose:
          json['keepRunningInTrayOnClose'] as bool? ?? true,
      autoConnectOnLaunch: json['autoConnectOnLaunch'] as bool? ?? false,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is DesktopSettings &&
        other.launchMinimized == launchMinimized &&
        other.keepRunningInTrayOnClose == keepRunningInTrayOnClose &&
        other.autoConnectOnLaunch == autoConnectOnLaunch;
  }

  @override
  int get hashCode => Object.hash(
    launchMinimized,
    keepRunningInTrayOnClose,
    autoConnectOnLaunch,
  );
}
