class IpInfo {
  const IpInfo({
    required this.ip,
    required this.countryCode,
    this.country,
    this.region,
    this.city,
    this.timezone,
    this.asn,
    this.org,
  });

  final String ip;
  final String countryCode;
  final String? country;
  final String? region;
  final String? city;
  final String? timezone;
  final String? asn;
  final String? org;
}
