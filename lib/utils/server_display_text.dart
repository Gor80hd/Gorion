String sanitizeServerDisplayText(
  String value, {
  bool replaceUnderscores = false,
}) {
  var sanitized = value.replaceAll(RegExp(r'§[^§]*'), '');
  if (replaceUnderscores) {
    sanitized = sanitized.replaceAll('_', ' ');
  }
  return sanitized.trim();
}

String normalizeServerDisplayText(
  String value, {
  bool replaceUnderscores = false,
}) {
  final sanitized = sanitizeServerDisplayText(
    value,
    replaceUnderscores: replaceUnderscores,
  );
  if (sanitized.isEmpty) {
    return '';
  }

  final countryCode = extractCountryCodeFromDisplayText(sanitized);
  if (countryCode == null) {
    return sanitized;
  }

  final stripped = stripCountryPrefixFromDisplayText(sanitized);
  if (stripped.isEmpty) {
    return sanitized;
  }

  final flag = countryCodeToFlagEmoji(countryCode);
  if (flag.isEmpty) {
    return stripped;
  }

  return '$flag $stripped';
}

String? extractCountryCodeFromDisplayText(String value) {
  final sanitized = sanitizeServerDisplayText(value);
  if (sanitized.isEmpty) {
    return null;
  }

  final bracketMatch = RegExp(r'^\[([A-Za-z]{2})\](?:\s+|$)').firstMatch(
    sanitized,
  );
  if (bracketMatch != null) {
    return _normalizeCountryCode(bracketMatch.group(1));
  }

  final leadingFlag = _extractLeadingFlagCountryCode(sanitized);
  if (leadingFlag != null) {
    return leadingFlag;
  }

  final plainPrefix = RegExp(r'^([A-Za-z]{2})([\s_\-:|/]+)(.+)$').firstMatch(
    sanitized,
  );
  if (plainPrefix == null) {
    return null;
  }

  final codeToken = plainPrefix.group(1)!;
  final normalizedCode = _normalizeCountryCode(codeToken);
  final separator = plainPrefix.group(2)!;
  final remainder = plainPrefix.group(3)!.trim();
  if (normalizedCode == null ||
      !_looksLikeCountryPrefixedLabel(codeToken, separator, remainder)) {
    return null;
  }

  return normalizedCode;
}

String stripCountryPrefixFromDisplayText(String value) {
  final sanitized = sanitizeServerDisplayText(value);
  if (sanitized.isEmpty) {
    return '';
  }

  final bracketMatch = RegExp(r'^\[[A-Za-z]{2}\](.*)$').firstMatch(sanitized);
  if (bracketMatch != null) {
    return bracketMatch.group(1)!.trimLeft();
  }

  final flagPrefixLength = _leadingFlagPrefixLength(sanitized);
  if (flagPrefixLength != null) {
    return sanitized.substring(flagPrefixLength).trimLeft();
  }

  final plainPrefix = RegExp(r'^([A-Za-z]{2})([\s_\-:|/]+)(.+)$').firstMatch(
    sanitized,
  );
  if (plainPrefix == null) {
    return sanitized;
  }

  final codeToken = plainPrefix.group(1)!;
  final separator = plainPrefix.group(2)!;
  final remainder = plainPrefix.group(3)!.trim();
  if (_normalizeCountryCode(codeToken) == null ||
      !_looksLikeCountryPrefixedLabel(codeToken, separator, remainder)) {
    return sanitized;
  }

  return remainder;
}

String countryCodeToFlagEmoji(String code) {
  final normalized = _normalizeCountryCode(code);
  if (normalized == null) {
    return '';
  }

  const base = 0x1F1E6 - 0x41;
  return String.fromCharCodes(
    normalized.codeUnits.map((codeUnit) => base + codeUnit),
  );
}

String? _normalizeCountryCode(String? code) {
  if (code == null) {
    return null;
  }

  final normalized = code.trim().toUpperCase();
  if (normalized.length != 2 || !_supportedCountryCodes.contains(normalized)) {
    return null;
  }
  return normalized;
}

String? _extractLeadingFlagCountryCode(String value) {
  final runes = value.runes.toList(growable: false);
  if (runes.length < 2 ||
      !_isRegionalIndicator(runes[0]) ||
      !_isRegionalIndicator(runes[1])) {
    return null;
  }

  final code = String.fromCharCodes([
    0x41 + runes[0] - 0x1F1E6,
    0x41 + runes[1] - 0x1F1E6,
  ]);
  return _normalizeCountryCode(code);
}

int? _leadingFlagPrefixLength(String value) {
  final runes = value.runes.toList(growable: false);
  if (runes.length < 2 ||
      !_isRegionalIndicator(runes[0]) ||
      !_isRegionalIndicator(runes[1])) {
    return null;
  }

  var offset = String.fromCharCodes([runes[0], runes[1]]).length;
  while (offset < value.length && value[offset] == ' ') {
    offset += 1;
  }
  return offset;
}

bool _looksLikeCountryPrefixedLabel(
  String codeToken,
  String separator,
  String remainder,
) {
  if (remainder.isEmpty) {
    return false;
  }

  final isUppercasePrefix = codeToken == codeToken.toUpperCase();
  if (isUppercasePrefix) {
    return true;
  }

  final hasStructuredSeparator = separator.contains('_') ||
      separator.contains('-') ||
      separator.contains(':') ||
      separator.contains('|') ||
      separator.contains('/');
  if (hasStructuredSeparator) {
    return true;
  }

  final firstRune = remainder.runes.first;
  final isAsciiLowercase = firstRune >= 0x61 && firstRune <= 0x7A;
  return !isAsciiLowercase;
}

bool _isRegionalIndicator(int value) =>
    value >= 0x1F1E6 && value <= 0x1F1FF;

const Set<String> _supportedCountryCodes = {
  'AD',
  'AE',
  'AF',
  'AG',
  'AI',
  'AL',
  'AM',
  'AO',
  'AQ',
  'AR',
  'AS',
  'AT',
  'AU',
  'AW',
  'AX',
  'AZ',
  'BA',
  'BB',
  'BD',
  'BE',
  'BF',
  'BG',
  'BH',
  'BI',
  'BJ',
  'BL',
  'BM',
  'BN',
  'BO',
  'BQ',
  'BR',
  'BS',
  'BT',
  'BV',
  'BW',
  'BY',
  'BZ',
  'CA',
  'CC',
  'CD',
  'CF',
  'CG',
  'CH',
  'CI',
  'CK',
  'CL',
  'CM',
  'CN',
  'CO',
  'CR',
  'CU',
  'CV',
  'CW',
  'CX',
  'CY',
  'CZ',
  'DE',
  'DJ',
  'DK',
  'DM',
  'DO',
  'DZ',
  'EC',
  'EE',
  'EG',
  'EH',
  'ER',
  'ES',
  'ET',
  'EU',
  'FI',
  'FJ',
  'FK',
  'FM',
  'FO',
  'FR',
  'GA',
  'GB',
  'GD',
  'GE',
  'GF',
  'GG',
  'GH',
  'GI',
  'GL',
  'GM',
  'GN',
  'GP',
  'GQ',
  'GR',
  'GS',
  'GT',
  'GU',
  'GW',
  'GY',
  'HK',
  'HM',
  'HN',
  'HR',
  'HT',
  'HU',
  'ID',
  'IE',
  'IL',
  'IM',
  'IN',
  'IO',
  'IQ',
  'IR',
  'IS',
  'IT',
  'JE',
  'JM',
  'JO',
  'JP',
  'KE',
  'KG',
  'KH',
  'KI',
  'KM',
  'KN',
  'KP',
  'KR',
  'KW',
  'KY',
  'KZ',
  'LA',
  'LB',
  'LC',
  'LI',
  'LK',
  'LR',
  'LS',
  'LT',
  'LU',
  'LV',
  'LY',
  'MA',
  'MC',
  'MD',
  'ME',
  'MF',
  'MG',
  'MH',
  'MK',
  'ML',
  'MM',
  'MN',
  'MO',
  'MP',
  'MQ',
  'MR',
  'MS',
  'MT',
  'MU',
  'MV',
  'MW',
  'MX',
  'MY',
  'MZ',
  'NA',
  'NC',
  'NE',
  'NF',
  'NG',
  'NI',
  'NL',
  'NO',
  'NP',
  'NR',
  'NU',
  'NZ',
  'OM',
  'PA',
  'PE',
  'PF',
  'PG',
  'PH',
  'PK',
  'PL',
  'PM',
  'PN',
  'PR',
  'PS',
  'PT',
  'PW',
  'PY',
  'QA',
  'RE',
  'RO',
  'RS',
  'RU',
  'RW',
  'SA',
  'SB',
  'SC',
  'SD',
  'SE',
  'SG',
  'SH',
  'SI',
  'SJ',
  'SK',
  'SL',
  'SM',
  'SN',
  'SO',
  'SR',
  'SS',
  'ST',
  'SV',
  'SX',
  'SY',
  'SZ',
  'TC',
  'TD',
  'TF',
  'TG',
  'TH',
  'TJ',
  'TK',
  'TL',
  'TM',
  'TN',
  'TO',
  'TR',
  'TT',
  'TV',
  'TW',
  'TZ',
  'UA',
  'UG',
  'UM',
  'UN',
  'US',
  'UY',
  'UZ',
  'VA',
  'VC',
  'VE',
  'VG',
  'VI',
  'VN',
  'VU',
  'WF',
  'WS',
  'XK',
  'YE',
  'YT',
  'ZA',
  'ZM',
  'ZW',
};