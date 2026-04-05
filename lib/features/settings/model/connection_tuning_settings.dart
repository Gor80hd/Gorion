class ConnectionTuningSettings {
  const ConnectionTuningSettings({
    this.forceChromeUtls = false,
    this.sniDonor = '',
    this.forceVisionFlow = false,
    this.forceXudpPacketEncoding = false,
    this.enableMultiplex = false,
    this.enableTlsRecordFragment = false,
  });

  final bool forceChromeUtls;
  final String sniDonor;
  final bool forceVisionFlow;
  final bool forceXudpPacketEncoding;
  final bool enableMultiplex;
  final bool enableTlsRecordFragment;

  String get normalizedSniDonor => sniDonor.trim();

  bool get hasOverrides {
    return forceChromeUtls ||
        normalizedSniDonor.isNotEmpty ||
        forceVisionFlow ||
        forceXudpPacketEncoding ||
        enableMultiplex ||
        enableTlsRecordFragment;
  }

  ConnectionTuningSettings copyWith({
    bool? forceChromeUtls,
    String? sniDonor,
    bool? forceVisionFlow,
    bool? forceXudpPacketEncoding,
    bool? enableMultiplex,
    bool? enableTlsRecordFragment,
  }) {
    return ConnectionTuningSettings(
      forceChromeUtls: forceChromeUtls ?? this.forceChromeUtls,
      sniDonor: (sniDonor ?? this.sniDonor).trim(),
      forceVisionFlow: forceVisionFlow ?? this.forceVisionFlow,
      forceXudpPacketEncoding:
          forceXudpPacketEncoding ?? this.forceXudpPacketEncoding,
      enableMultiplex: enableMultiplex ?? this.enableMultiplex,
      enableTlsRecordFragment:
          enableTlsRecordFragment ?? this.enableTlsRecordFragment,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'forceChromeUtls': forceChromeUtls,
      'sniDonor': normalizedSniDonor,
      'forceVisionFlow': forceVisionFlow,
      'forceXudpPacketEncoding': forceXudpPacketEncoding,
      'enableMultiplex': enableMultiplex,
      'enableTlsRecordFragment': enableTlsRecordFragment,
    };
  }

  factory ConnectionTuningSettings.fromJson(Map<String, dynamic> json) {
    return ConnectionTuningSettings(
      forceChromeUtls: json['forceChromeUtls'] as bool? ?? false,
      sniDonor: json['sniDonor']?.toString().trim() ?? '',
      forceVisionFlow: json['forceVisionFlow'] as bool? ?? false,
      forceXudpPacketEncoding:
          json['forceXudpPacketEncoding'] as bool? ?? false,
      enableMultiplex: json['enableMultiplex'] as bool? ?? false,
      enableTlsRecordFragment:
          json['enableTlsRecordFragment'] as bool? ?? false,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ConnectionTuningSettings &&
        other.forceChromeUtls == forceChromeUtls &&
        other.normalizedSniDonor == normalizedSniDonor &&
        other.forceVisionFlow == forceVisionFlow &&
        other.forceXudpPacketEncoding == forceXudpPacketEncoding &&
        other.enableMultiplex == enableMultiplex &&
        other.enableTlsRecordFragment == enableTlsRecordFragment;
  }

  @override
  int get hashCode => Object.hash(
    forceChromeUtls,
    normalizedSniDonor,
    forceVisionFlow,
    forceXudpPacketEncoding,
    enableMultiplex,
    enableTlsRecordFragment,
  );
}
