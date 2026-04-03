enum RuntimeMode {
  mixed,
  systemProxy,
  tun;

  String get label => switch (this) {
    RuntimeMode.mixed => 'Local proxy',
    RuntimeMode.systemProxy => 'System proxy',
    RuntimeMode.tun => 'TUN',
  };

  String get description => switch (this) {
    RuntimeMode.mixed =>
      'Expose a local mixed inbound only. Browsers and apps must be pointed at the proxy manually after you connect.',
    RuntimeMode.systemProxy =>
      'Route traffic from apps that honor the Windows system proxy through the local mixed inbound automatically.',
    RuntimeMode.tun =>
      'Capture system traffic through a TUN interface. This also covers apps that ignore proxy settings, but may require elevated privileges.',
  };

  bool get usesSystemProxy => this == RuntimeMode.systemProxy;

  bool get usesTun => this == RuntimeMode.tun;
}
