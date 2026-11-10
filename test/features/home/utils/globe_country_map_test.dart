import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gorion/features/home/utils/globe_country_codes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('globe country map asset', () {
    test('country index resolves ISO codes case-insensitively', () {
      expect(globeCountryIndexFor('DE'), greaterThan(0));
      expect(globeCountryIndexFor('de'), greaterThan(0));
      expect(globeCountryIndexFor('SG'), greaterThan(0));
      expect(globeCountryIndexFor(null), 0);
      expect(globeCountryIndexFor('XX'), 0);
    });

    test('map png encodes land pixels for common server countries', () async {
      final data = await rootBundle.load(
        'assets/images/world_map_countries.png',
      );
      final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
      final frame = await codec.getNextFrame();
      final image = frame.image;
      final rawData = await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      expect(rawData, isNotNull);

      final bytes = rawData!.buffer.asUint8List();
      final width = image.width;
      final height = image.height;
      expect(width, 2048);
      expect(height, 1024);

      int pixelForLatLon(double lat, double lon) {
        final x = (((lon + 180) / 360) * (width - 1)).round();
        final y = (((90 - lat) / 180) * (height - 1)).round();
        return bytes[((y * width) + x) * 4];
      }

      // Berlin, Germany.
      expect(pixelForLatLon(52.52, 13.405), globeCountryIndexFor('DE'));
      // Tokyo, Japan.
      expect(pixelForLatLon(35.68, 139.69), globeCountryIndexFor('JP'));
      // New York, USA.
      expect(pixelForLatLon(40.71, -74.0), globeCountryIndexFor('US'));
      // Middle of the Pacific is ocean.
      expect(pixelForLatLon(-25.0, -150.0), 0);

      image.dispose();
    });
  });
}
