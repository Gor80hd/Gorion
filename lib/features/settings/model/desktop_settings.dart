enum LaunchAtStartupPriority {
  standard('standard'),
  first('first');

  const LaunchAtStartupPriority(this.jsonValue);

  final String jsonValue;

  static LaunchAtStartupPriority fromJsonValue(Object? value) {
    return switch (value) {
      'first' => LaunchAtStartupPriority.first,
      _ => LaunchAtStartupPriority.standard,
    };
  }
}

class DesktopSettings {
  const DesktopSettings({
    this.launchMinimized = false,
    this.keepRunningInTrayOnClose = true,
    this.autoConnectOnLaunch = false,
    this.launchAtStartupPriority = LaunchAtStartupPriority.standard,
  });

  final bool launchMinimized;
  final bool keepRunningInTrayOnClose;
  final bool autoConnectOnLaunch;
  final LaunchAtStartupPriority launchAtStartupPriority;

  DesktopSettings copyWith({
    bool? launchMinimized,
    bool? keepRunningInTrayOnClose,
    bool? autoConnectOnLaunch,
    LaunchAtStartupPriority? launchAtStartupPriority,
  }) {
    return DesktopSettings(
      launchMinimized: launchMinimized ?? this.launchMinimized,
      keepRunningInTrayOnClose:
          keepRunningInTrayOnClose ?? this.keepRunningInTrayOnClose,
      autoConnectOnLaunch: autoConnectOnLaunch ?? this.autoConnectOnLaunch,
      launchAtStartupPriority:
          launchAtStartupPriority ?? this.launchAtStartupPriority,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'launchMinimized': launchMinimized,
      'keepRunningInTrayOnClose': keepRunningInTrayOnClose,
      'autoConnectOnLaunch': autoConnectOnLaunch,
      'launchAtStartupPriority': launchAtStartupPriority.jsonValue,
    };
  }

  factory DesktopSettings.fromJson(Map<String, dynamic> json) {
    return DesktopSettings(
      launchMinimized: json['launchMinimized'] as bool? ?? false,
      keepRunningInTrayOnClose:
          json['keepRunningInTrayOnClose'] as bool? ?? true,
      autoConnectOnLaunch: json['autoConnectOnLaunch'] as bool? ?? false,
      launchAtStartupPriority: LaunchAtStartupPriority.fromJsonValue(
        json['launchAtStartupPriority'],
      ),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is DesktopSettings &&
        other.launchMinimized == launchMinimized &&
        other.keepRunningInTrayOnClose == keepRunningInTrayOnClose &&
        other.autoConnectOnLaunch == autoConnectOnLaunch &&
        other.launchAtStartupPriority == launchAtStartupPriority;
  }

  @override
  int get hashCode => Object.hash(
    launchMinimized,
    keepRunningInTrayOnClose,
    autoConnectOnLaunch,
    launchAtStartupPriority,
  );
}
