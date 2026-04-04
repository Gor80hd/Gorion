class IpInfo {
  const IpInfo({
    required this.ip,
    required this.countryCode,
    this.region,
    this.city,
    this.timezone,
    this.asn,
    this.org,
  });

  final String ip;
  final String countryCode;
  final String? region;
  final String? city;
  final String? timezone;
  final String? asn;
  final String? org;
}
