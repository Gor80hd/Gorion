import 'package:gorion_clean/features/proxy/model/ip_info_entity.dart';

String describeIpInfo(IpInfo? ipInfo, {required String fallback}) {
  final location = bestIpInfoLocation(ipInfo);
  return location ?? fallback;
}

String? bestIpInfoLocation(IpInfo? ipInfo) {
  if (ipInfo == null) {
    return null;
  }

  final city = _normalizePart(ipInfo.city);
  final region = _normalizePart(ipInfo.region);
  final country = _normalizePart(ipInfo.country);
  final organization = _normalizePart(ipInfo.org);
  final countryCode = _normalizePart(ipInfo.countryCode);

  if (city != null && region != null && !_sameText(city, region)) {
    return '$city, $region';
  }
  if (city != null && country != null && !_sameText(city, country)) {
    return '$city, $country';
  }
  if (region != null && country != null && !_sameText(region, country)) {
    return '$region, $country';
  }

  return city ?? region ?? country ?? organization ?? countryCode;
}

String? _normalizePart(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) {
    return null;
  }
  if (trimmed.toLowerCase() == 'null') {
    return null;
  }
  return trimmed;
}

bool _sameText(String left, String right) {
  return left.trim().toLowerCase() == right.trim().toLowerCase();
}
