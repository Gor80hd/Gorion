import 'dart:io';

class RegionDetector {
  /// Returns: 'IR' | 'AF' | 'CN' | 'TR' | 'RU' | 'BR' | 'US'
  static String detect() {
    final now = DateTime.now();
    final offset = now.timeZoneOffset.inMinutes;
    final tz = now.timeZoneName.toLowerCase().trim();

    if (offset == 210) return 'IR';

    if (offset == 270) {
      final (_, country) = _parseLocale();
      return country == 'IR' ? 'IR' : 'AF';
    }

    final fromName = _fromTzName(tz, offset);
    if (fromName != null) return fromName;

    final candidates = _candidatesForOffset(offset);
    if (candidates.isEmpty) return 'US';

    return _resolveByLocale(candidates);
  }

  static String? _fromTzName(String tz, int offset) {
    if (tz.contains('/')) {
      final city = tz.split('/').last.replaceAll(' ', '_');
      final r = _ianaCities[city];
      if (r != null) return r;
    }

    if (tz == 'irst' || tz == 'irdt' || tz.contains('iran')) return 'IR';

    if (tz == 'aft' || tz.contains('afghanistan')) return 'AF';

    if (tz == 'trt' || tz.contains('turkey') || tz.contains('istanbul')) {
      return 'TR';
    }

    if (tz.contains('china') || tz.contains('beijing')) return 'CN';
    if (tz == 'cst' && offset == 480) return 'CN';

    if (_matchesRussiaTz(tz)) return 'RU';
    if (_matchesBrazilTz(tz)) return 'BR';

    return null;
  }

  static bool _matchesRussiaTz(String tz) {
    if (tz.contains('russia') || tz.contains('moscow')) return true;
    const abbrs = {'msk', 'yekt', 'omst', 'krat', 'irkt', 'yakt', 'vlat', 'magt', 'pett', 'sakt', 'sret'};
    if (abbrs.contains(tz)) return true;
    const winKeys = [
      'ekaterinburg', 'kaliningrad', 'yakutsk', 'vladivostok', 'magadan',
      'sakhalin', 'kamchatka', 'astrakhan', 'saratov', 'volgograd', 'altai',
      'tomsk', 'transbaikal', 'n. central asia', 'north asia',
    ];
    return winKeys.any(tz.contains);
  }

  static bool _matchesBrazilTz(String tz) {
    if (tz == 'brt' || tz == 'brst') return true;
    if (tz.contains('brazil') || tz.contains('brasilia')) return true;
    const winKeys = ['e. south america', 'central brazilian', 'tocantins', 'bahia'];
    return winKeys.any(tz.contains);
  }

  static Set<String> _candidatesForOffset(int offset) {
    final candidates = <String>{};
    if (offset == 180) candidates.add('TR');
    if (offset == 480) candidates.add('CN');
    if (_ruOffsets.contains(offset)) candidates.add('RU');
    if (_brOffsets.contains(offset)) candidates.add('BR');
    return candidates;
  }

  static const _ruOffsets = {120, 180, 240, 300, 360, 420, 480, 540, 600, 660, 720};
  static const _brOffsets = {-120, -180, -240, -300};

  static String _resolveByLocale(Set<String> candidates) {
    final (lang, country) = _parseLocale();
    if (country != null && candidates.contains(country)) return country;
    final regionFromLang = _langToRegion[lang];
    if (regionFromLang != null && candidates.contains(regionFromLang)) return regionFromLang;
    return 'US';
  }

  static (String, String?) _parseLocale() {
    try {
      final parts = Platform.localeName.split(RegExp(r'[_\-.]'));
      final lang = parts.first.toLowerCase();
      String? country;
      for (final part in parts.skip(1)) {
        if (part.length == 2) {
          country = part.toUpperCase();
          break;
        }
      }
      return (lang, country);
    } catch (_) {
      return ('en', null);
    }
  }

  static const _langToRegion = <String, String>{
    'fa': 'IR', 'ps': 'AF', 'tr': 'TR', 'zh': 'CN', 'ru': 'RU', 'pt': 'BR',
  };

  static const _ianaCities = <String, String>{
    'tehran': 'IR', 'kabul': 'AF', 'istanbul': 'TR',
    'shanghai': 'CN', 'chongqing': 'CN', 'urumqi': 'CN', 'harbin': 'CN',
    'moscow': 'RU', 'kaliningrad': 'RU', 'samara': 'RU', 'yekaterinburg': 'RU',
    'omsk': 'RU', 'novosibirsk': 'RU', 'barnaul': 'RU', 'tomsk': 'RU',
    'krasnoyarsk': 'RU', 'irkutsk': 'RU', 'chita': 'RU', 'yakutsk': 'RU',
    'vladivostok': 'RU', 'magadan': 'RU', 'sakhalin': 'RU', 'kamchatka': 'RU',
    'anadyr': 'RU', 'volgograd': 'RU', 'saratov': 'RU', 'astrakhan': 'RU',
    'sao_paulo': 'BR', 'fortaleza': 'BR', 'recife': 'BR', 'manaus': 'BR',
    'belem': 'BR', 'cuiaba': 'BR', 'bahia': 'BR', 'rio_branco': 'BR',
    'noronha': 'BR', 'porto_velho': 'BR', 'campo_grande': 'BR',
  };
}
