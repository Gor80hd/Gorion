import 'package:flutter_test/flutter_test.dart';
import 'package:gorion_clean/features/proxy/model/ip_info_entity.dart';
import 'package:gorion_clean/features/proxy/utils/ip_info_display.dart';

void main() {
  group('bestIpInfoLocation', () {
    test('prefers city and region when both are available', () {
      const ipInfo = IpInfo(
        ip: '203.0.113.10',
        countryCode: 'DE',
        country: 'Germany',
        region: 'Hesse',
        city: 'Frankfurt am Main',
      );

      expect(bestIpInfoLocation(ipInfo), 'Frankfurt am Main, Hesse');
    });

    test('falls back to region and country when the city is missing', () {
      const ipInfo = IpInfo(
        ip: '203.0.113.11',
        countryCode: 'DE',
        country: 'Germany',
        region: 'Hesse',
      );

      expect(bestIpInfoLocation(ipInfo), 'Hesse, Germany');
    });

    test('falls back to country when only country-level data is available', () {
      const ipInfo = IpInfo(
        ip: '203.0.113.12',
        countryCode: 'DE',
        country: 'Germany',
      );

      expect(bestIpInfoLocation(ipInfo), 'Germany');
    });
  });

  group('describeIpInfo', () {
    test('returns the fallback when geo data is unavailable', () {
      expect(
        describeIpInfo(null, fallback: 'Определяем внешний адрес…'),
        'Определяем внешний адрес…',
      );
    });
  });
}
