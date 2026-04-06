import 'package:gorion_clean/features/proxy/model/ip_info_entity.dart';
import 'package:gorion_clean/features/proxy/model/outbound_models.dart';
import 'package:gorion_clean/utils/server_display_text.dart';

typedef LatLon = (double, double);

const LatLon defaultMapFallbackLatLon = (51.5, 10.0);
const LatLon defaultSourceFallbackLatLon = (55.7558, 37.6173);

const Map<String, LatLon> _countryLatLon = {
  'AD': (42.5, 1.5),
  'AE': (24, 54),
  'AF': (33, 65),
  'AG': (17.05, -61.8),
  'AI': (18.25, -63.16666666),
  'AL': (41, 20),
  'AM': (40, 45),
  'AO': (-12.5, 18.5),
  'AQ': (-74.65, 4.48),
  'AR': (-34, -64),
  'AS': (-14.33333333, -170),
  'AT': (47.33333333, 13.33333333),
  'AU': (-27, 133),
  'AW': (12.5, -69.96666666),
  'AX': (60.116667, 19.9),
  'AZ': (40.5, 47.5),
  'BA': (44, 18),
  'BB': (13.16666666, -59.53333333),
  'BD': (24, 90),
  'BE': (50.83333333, 4),
  'BF': (13, -2),
  'BG': (43, 25),
  'BH': (26, 50.55),
  'BI': (-3.5, 30),
  'BJ': (9.5, 2.25),
  'BL': (18.5, -63.41666666),
  'BM': (32.33333333, -64.75),
  'BN': (4.5, 114.66666666),
  'BO': (-17, -65),
  'BQ': (12.15, -68.266667),
  'BR': (-10, -55),
  'BS': (24.25, -76),
  'BT': (27.5, 90.5),
  'BV': (-54.43333333, 3.4),
  'BW': (-22, 24),
  'BY': (53, 28),
  'BZ': (17.25, -88.75),
  'CA': (60, -95),
  'CC': (-12.5, 96.83333333),
  'CD': (0, 25),
  'CF': (7, 21),
  'CG': (-1, 15),
  'CH': (47, 8),
  'CI': (8, -5),
  'CK': (-21.23333333, -159.76666666),
  'CL': (-30, -71),
  'CM': (6, 12),
  'CN': (35, 105),
  'CO': (4, -72),
  'CR': (10, -84),
  'CU': (21.5, -80),
  'CV': (16, -24),
  'CW': (12.116667, -68.933333),
  'CX': (-10.5, 105.66666666),
  'CY': (35, 33),
  'CZ': (49.75, 15.5),
  'DE': (51, 9),
  'DJ': (11.5, 43),
  'DK': (56, 10),
  'DM': (15.41666666, -61.33333333),
  'DO': (19, -70.66666666),
  'DZ': (28, 3),
  'EC': (-2, -77.5),
  'EE': (59, 26),
  'EG': (27, 30),
  'EH': (24.5, -13),
  'ER': (15, 39),
  'ES': (40, -4),
  'ET': (8, 38),
  'FI': (64, 26),
  'FJ': (-18, 175),
  'FK': (-51.75, -59),
  'FM': (6.91666666, 158.25),
  'FO': (62, -7),
  'FR': (46, 2),
  'GA': (-1, 11.75),
  'GB': (54, -2),
  'GD': (12.11666666, -61.66666666),
  'GE': (42, 43.5),
  'GF': (4, -53),
  'GG': (49.46666666, -2.58333333),
  'GH': (8, -2),
  'GI': (36.13333333, -5.35),
  'GL': (72, -40),
  'GM': (13.46666666, -16.56666666),
  'GN': (11, -10),
  'GP': (16.25, -61.583333),
  'GQ': (2, 10),
  'GR': (39, 22),
  'GS': (-54.5, -37),
  'GT': (15.5, -90.25),
  'GU': (13.46666666, 144.78333333),
  'GW': (12, -15),
  'GY': (5, -59),
  'HK': (22.25, 114.16666666),
  'HM': (-53.1, 72.51666666),
  'HN': (15, -86.5),
  'HR': (45.16666666, 15.5),
  'HT': (19, -72.41666666),
  'HU': (47, 20),
  'ID': (-5, 120),
  'IE': (53, -8),
  'IL': (31.5, 34.75),
  'IM': (54.25, -4.5),
  'IN': (20, 77),
  'IO': (-6, 71.5),
  'IQ': (33, 44),
  'IR': (32, 53),
  'IS': (65, -18),
  'IT': (42.83333333, 12.83333333),
  'JE': (49.25, -2.16666666),
  'JM': (18.25, -77.5),
  'JO': (31, 36),
  'JP': (36, 138),
  'KE': (1, 38),
  'KG': (41, 75),
  'KH': (13, 105),
  'KI': (1.41666666, 173),
  'KM': (-12.16666666, 44.25),
  'KN': (17.33333333, -62.75),
  'KP': (40, 127),
  'KR': (37, 127.5),
  'KW': (29.5, 45.75),
  'KY': (19.5, -80.5),
  'KZ': (48, 68),
  'LA': (18, 105),
  'LB': (33.83333333, 35.83333333),
  'LC': (13.88333333, -60.96666666),
  'LI': (47.26666666, 9.53333333),
  'LK': (7, 81),
  'LR': (6.5, -9.5),
  'LS': (-29.5, 28.5),
  'LT': (56, 24),
  'LU': (49.75, 6.16666666),
  'LV': (57, 25),
  'LY': (25, 17),
  'MA': (32, -5),
  'MC': (43.73333333, 7.4),
  'MD': (47, 29),
  'ME': (42.5, 19.3),
  'MF': (18.08333333, -63.95),
  'MG': (-20, 47),
  'MH': (9, 168),
  'MK': (41.83333333, 22),
  'ML': (17, -4),
  'MM': (22, 98),
  'MN': (46, 105),
  'MO': (22.16666666, 113.55),
  'MP': (15.2, 145.75),
  'MQ': (14.666667, -61),
  'MR': (20, -12),
  'MS': (16.75, -62.2),
  'MT': (35.83333333, 14.58333333),
  'MU': (-20.28333333, 57.55),
  'MV': (3.25, 73),
  'MW': (-13.5, 34),
  'MX': (23, -102),
  'MY': (2.5, 112.5),
  'MZ': (-18.25, 35),
  'NA': (-22, 17),
  'NC': (-21.5, 165.5),
  'NE': (16, 8),
  'NF': (-29.03333333, 167.95),
  'NG': (10, 8),
  'NI': (13, -85),
  'NL': (52.5, 5.75),
  'NO': (62, 10),
  'NP': (28, 84),
  'NR': (-0.53333333, 166.91666666),
  'NU': (-19.03333333, -169.86666666),
  'NZ': (-41, 174),
  'OM': (21, 57),
  'PA': (9, -80),
  'PE': (-10, -76),
  'PF': (-15, -140),
  'PG': (-6, 147),
  'PH': (13, 122),
  'PK': (30, 70),
  'PL': (52, 20),
  'PM': (46.83333333, -56.33333333),
  'PN': (-25.06666666, -130.1),
  'PR': (18.25, -66.5),
  'PS': (31.9, 35.2),
  'PT': (39.5, -8),
  'PW': (7.5, 134.5),
  'PY': (-23, -58),
  'QA': (25.5, 51.25),
  'RE': (-21.15, 55.5),
  'RO': (46, 25),
  'RS': (44, 21),
  'RU': (60, 100),
  'RW': (-2, 30),
  'SA': (25, 45),
  'SB': (-8, 159),
  'SC': (-4.6574977, 55.4540146),
  'SD': (15, 30),
  'SE': (62, 15),
  'SG': (1.36666666, 103.8),
  'SH': (-15.95, -5.7),
  'SI': (46.11666666, 14.81666666),
  'SJ': (78, 20),
  'SK': (48.66666666, 19.5),
  'SL': (8.5, -11.5),
  'SM': (43.76666666, 12.41666666),
  'SN': (14, -14),
  'SO': (10, 49),
  'SR': (4, -56),
  'SS': (7, 30),
  'ST': (1, 7),
  'SV': (13.83333333, -88.91666666),
  'SX': (18.033333, -63.05),
  'SY': (35, 38),
  'SZ': (-26.5, 31.5),
  'TC': (21.75, -71.58333333),
  'TD': (15, 19),
  'TF': (-49.25, 69.167),
  'TG': (8, 1.16666666),
  'TH': (15, 100),
  'TJ': (39, 71),
  'TK': (-9, -172),
  'TL': (-8.83333333, 125.91666666),
  'TM': (40, 60),
  'TN': (34, 9),
  'TO': (-20, -175),
  'TR': (39, 35),
  'TT': (11, -61),
  'TV': (-8, 178),
  'TW': (23.5, 121),
  'TZ': (-6, 35),
  'UA': (49, 32),
  'UG': (1, 32),
  'UM': (0, 0),
  'US': (38, -97),
  'UY': (-33, -56),
  'UZ': (41, 64),
  'VA': (41.9, 12.45),
  'VC': (13.25, -61.2),
  'VE': (8, -66),
  'VG': (18.431383, -64.62305),
  'VI': (18.34, -64.93),
  'VN': (16.16666666, 107.83333333),
  'VU': (-16, 167),
  'WF': (-13.3, -176.2),
  'WS': (-13.58333333, -172.33333333),
  'XK': (42.5612909, 20.3403035),
  'YE': (15, 48),
  'YT': (-12.83333333, 45.16666666),
  'ZA': (-29, 24),
  'ZM': (-15, 30),
  'ZW': (-20, 30),
};

const Map<String, String> _countryCodeAliases = {'EL': 'GR', 'UK': 'GB'};

const Map<String, LatLon> _locationKeywords = {
  'lithuania': (55.2, 23.9),
  'литва': (55.2, 23.9),
  'vilnius': (54.6872, 25.2797),
  'вильнюс': (54.6872, 25.2797),
  'belgium': (50.8, 4.5),
  'бельгия': (50.8, 4.5),
  'brussels': (50.8503, 4.3517),
  'брюссель': (50.8503, 4.3517),
  'romania': (45.9, 24.9),
  'румыния': (45.9, 24.9),
  'bucharest': (44.4268, 26.1025),
  'бухарест': (44.4268, 26.1025),
  'slovakia': (48.7, 19.7),
  'словакия': (48.7, 19.7),
  'bratislava': (48.1486, 17.1077),
  'братислава': (48.1486, 17.1077),
  'germany': (51.1, 10.4),
  'германия': (51.1, 10.4),
  'frankfurt': (50.1109, 8.6821),
  'франкфурт': (50.1109, 8.6821),
  'switzerland': (46.8, 8.2),
  'швейцария': (46.8, 8.2),
  'zurich': (47.3769, 8.5417),
  'цюрих': (47.3769, 8.5417),
  'united kingdom': (55.4, -3.4),
  'great britain': (55.4, -3.4),
  'britain': (55.4, -3.4),
  'великобритания': (55.4, -3.4),
  'london': (51.5074, -0.1278),
  'лондон': (51.5074, -0.1278),
  'south korea': (35.9, 127.8),
  'korea': (35.9, 127.8),
  'южная корея': (35.9, 127.8),
  'seoul': (37.5665, 126.978),
  'сеул': (37.5665, 126.978),
  'canada': (56.1, -106.3),
  'канада': (56.1, -106.3),
  'toronto': (43.6532, -79.3832),
  'торонто': (43.6532, -79.3832),
  'netherlands': (52.1, 5.3),
  'amsterdam': (52.3676, 4.9041),
  'france': (46.2, 2.2),
  'paris': (48.8566, 2.3522),
  'us': (38.9, -77.0),
  'usa': (38.9, -77.0),
  'united states': (38.9, -77.0),
  'new york': (40.7128, -74.006),
  'los angeles': (34.0549, -118.2426),
  'russia': (55.7, 37.6),
  'moscow': (55.7558, 37.6173),
  'iran': (32.4, 53.7),
  'tehran': (35.6892, 51.389),
  'turkey': (38.9, 35.2),
  'istanbul': (41.0082, 28.9784),
  'japan': (36.2, 138.3),
  'tokyo': (35.6762, 139.6503),
  'china': (35.9, 104.5),
  'singapore': (1.3521, 103.8198),
  'australia': (-25.3, 133.8),
  'brazil': (-14.2, -51.9),
  'india': (20.6, 78.9),
  'poland': (51.9, 19.1),
  'sweden': (60.1, 18.6),
  'norway': (60.5, 8.5),
  'austria': (47.5, 14.6),
  'ukraine': (48.4, 31.2),
  'finland': (61.9, 25.7),
  'italy': (41.9, 12.5),
  'spain': (40.5, -3.7),
  'portugal': (39.4, -8.2),
  'uae': (23.4, 53.8),
  'dubai': (25.2048, 55.2708),
  'hong kong': (22.3193, 114.1694),
  'taiwan': (23.7, 121.0),
  'denmark': (56.0, 10.0),
  'дания': (56.0, 10.0),
  'danmark': (56.0, 10.0),
  'copenhagen': (55.6761, 12.5683),
  'копенгаген': (55.6761, 12.5683),
  'greece': (39.0, 22.0),
  'греция': (39.0, 22.0),
  'hellas': (39.0, 22.0),
  'athens': (37.9838, 23.7275),
  'афины': (37.9838, 23.7275),
};

bool hasCountryLatLon(String? countryCode) =>
    tryLookupCountryLatLon(countryCode) != null;

LatLon? tryLookupCountryLatLon(String? countryCode) {
  final normalized = _normalizeCountryCode(countryCode);
  if (normalized == null) {
    return null;
  }
  return _countryLatLon[normalized];
}

LatLon lookupCountryLatLon(
  String? countryCode, {
  LatLon fallback = defaultMapFallbackLatLon,
}) {
  return tryLookupCountryLatLon(countryCode) ?? fallback;
}

String? extractMappableCountryCode(String value) {
  final displayCode = _normalizeCountryCode(
    extractCountryCodeFromDisplayText(value),
  );
  if (displayCode != null) {
    return displayCode;
  }

  final flagCode = _extractCountryCodeFromFlag(value);
  if (flagCode != null) {
    return flagCode;
  }

  final match = RegExp(
    r'\[([A-Za-z]{2})\]|\b([A-Za-z]{2})\b',
  ).firstMatch(value);
  return _normalizeCountryCode(match?.group(1) ?? match?.group(2));
}

LatLon? extractLocationLatLonFromText(String value) {
  final normalized = _normalizeLocationText(value);
  if (normalized.isEmpty) {
    return null;
  }

  final haystack = ' $normalized ';
  LatLon? bestMatch;
  var bestMatchLength = -1;
  for (final entry in _locationKeywords.entries) {
    if (haystack.contains(' ${entry.key} ')) {
      final keyLength = entry.key.length;
      if (keyLength > bestMatchLength) {
        bestMatch = entry.value;
        bestMatchLength = keyLength;
      }
    }
  }
  return bestMatch;
}

LatLon resolveDestinationLatLon(
  OutboundInfo? selectedProxy,
  String? destCountry,
) {
  final routedLatLon = tryLookupCountryLatLon(destCountry);
  if (selectedProxy == null) {
    return routedLatLon ?? defaultMapFallbackLatLon;
  }

  final rawName = selectedProxy.tagDisplay.isNotEmpty
      ? selectedProxy.tagDisplay
      : selectedProxy.tag;

  final keywordLatLon = extractLocationLatLonFromText(rawName);
  if (keywordLatLon != null) {
    return keywordLatLon;
  }

  final countryCode = extractMappableCountryCode(rawName);
  if (countryCode != null) {
    return lookupCountryLatLon(countryCode);
  }

  if (routedLatLon != null) {
    return routedLatLon;
  }

  final sanitizedName = sanitizeServerDisplayText(
    rawName,
    replaceUnderscores: true,
  );
  final sanitizedLatLon = extractLocationLatLonFromText(sanitizedName);
  if (sanitizedLatLon != null) {
    return sanitizedLatLon;
  }

  return defaultMapFallbackLatLon;
}

LatLon resolveSourceLatLon(IpInfo? ipInfo) {
  if (ipInfo == null) {
    return defaultSourceFallbackLatLon;
  }

  final locationParts = [
    ipInfo.city,
    ipInfo.region,
    ipInfo.country,
    ipInfo.countryCode,
  ].whereType<String>().join(', ');
  final keywordLatLon = extractLocationLatLonFromText(locationParts);
  if (keywordLatLon != null) {
    return keywordLatLon;
  }

  return lookupCountryLatLon(
    ipInfo.countryCode,
    fallback: defaultSourceFallbackLatLon,
  );
}

String _normalizeLocationText(String value) {
  return value
      .toLowerCase()
      .replaceAll(RegExp(r'[_\-|/:,;()\[\]{}\.]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

String? _extractCountryCodeFromFlag(String value) {
  final runes = value.runes.toList(growable: false);
  for (var index = 0; index < runes.length - 1; index++) {
    final first = runes[index];
    final second = runes[index + 1];
    final isFirstIndicator = first >= 0x1F1E6 && first <= 0x1F1FF;
    final isSecondIndicator = second >= 0x1F1E6 && second <= 0x1F1FF;
    if (!isFirstIndicator || !isSecondIndicator) {
      continue;
    }

    final code = String.fromCharCodes([
      0x41 + first - 0x1F1E6,
      0x41 + second - 0x1F1E6,
    ]);
    final normalized = _normalizeCountryCode(code);
    if (normalized != null) {
      return normalized;
    }
  }

  return null;
}

String? _normalizeCountryCode(String? countryCode) {
  if (countryCode == null) {
    return null;
  }

  final normalized = countryCode.trim().toUpperCase();
  if (normalized.length != 2) {
    return null;
  }

  final resolved = _countryCodeAliases[normalized] ?? normalized;
  if (!_countryLatLon.containsKey(resolved)) {
    return null;
  }
  return resolved;
}
