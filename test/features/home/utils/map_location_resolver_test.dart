import 'package:flutter_test/flutter_test.dart';
import 'package:gorion_clean/features/home/utils/map_location_resolver.dart';
import 'package:gorion_clean/features/proxy/model/ip_info_entity.dart';
import 'package:gorion_clean/features/proxy/model/outbound_models.dart';

void main() {
  group('lookupCountryLatLon', () {
    test('resolves Denmark and Greece by country code', () {
      final denmark = lookupCountryLatLon('DK');
      final greece = lookupCountryLatLon('GR');

      expect(denmark.$1, closeTo(56.0, 0.001));
      expect(denmark.$2, closeTo(10.0, 0.001));
      expect(greece.$1, closeTo(39.0, 0.001));
      expect(greece.$2, closeTo(22.0, 0.001));
    });

    test('supports common two-letter aliases like UK', () {
      final unitedKingdom = lookupCountryLatLon('UK');

      expect(unitedKingdom.$1, closeTo(54.0, 0.001));
      expect(unitedKingdom.$2, closeTo(-2.0, 0.001));
      expect(extractMappableCountryCode('UK London relay'), 'GB');
    });

    test('maps Russia to Moscow when only country code is available', () {
      final russia = lookupCountryLatLon('RU');

      expect(russia.$1, closeTo(55.7558, 0.001));
      expect(russia.$2, closeTo(37.6173, 0.001));
    });
  });

  group('resolveDestinationLatLon', () {
    test('resolves Russian Denmark labels to Copenhagen', () {
      final latLon = resolveDestinationLatLon(
        OutboundInfo(tagDisplay: '🇩🇰 Дания, Копенгаген'),
        null,
      );

      expect(latLon.$1, closeTo(55.6761, 0.001));
      expect(latLon.$2, closeTo(12.5683, 0.001));
    });

    test('resolves Greece labels to Athens', () {
      final latLon = resolveDestinationLatLon(
        OutboundInfo(tagDisplay: '🇬🇷 Athens #1'),
        null,
      );

      expect(latLon.$1, closeTo(37.9838, 0.001));
      expect(latLon.$2, closeTo(23.7275, 0.001));
    });

    test('falls back to routed country before any random placement', () {
      final latLon = resolveDestinationLatLon(
        OutboundInfo(tagDisplay: 'edge relay without region hint'),
        'GR',
      );

      expect(latLon.$1, closeTo(39.0, 0.001));
      expect(latLon.$2, closeTo(22.0, 0.001));
    });
  });

  group('resolveSourceLatLon', () {
    test('uses source city and country details when available', () {
      final latLon = resolveSourceLatLon(
        const IpInfo(
          ip: '203.0.113.10',
          countryCode: 'DK',
          country: 'Denmark',
          region: 'Capital Region',
          city: 'Copenhagen',
        ),
      );

      expect(latLon.$1, closeTo(55.6761, 0.001));
      expect(latLon.$2, closeTo(12.5683, 0.001));
    });
  });
}
