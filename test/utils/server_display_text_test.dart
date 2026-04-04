import 'package:flutter_test/flutter_test.dart';
import 'package:gorion_clean/utils/server_display_text.dart';

void main() {
  group('normalizeServerDisplayText', () {
    test('converts bracketed country prefixes into flag labels', () {
      expect(
        normalizeServerDisplayText('[NO] Норвегия, Осло'),
        '🇳🇴 Норвегия, Осло',
      );
    });

    test('converts plain country prefixes when the label looks like a location', () {
      expect(
        normalizeServerDisplayText('no Норвегия, Осло'),
        '🇳🇴 Норвегия, Осло',
      );
      expect(
        normalizeServerDisplayText('US New York'),
        '🇺🇸 New York',
      );
    });

    test('keeps existing flag labels unchanged', () {
      expect(
        normalizeServerDisplayText('🇳🇱 Amsterdam'),
        '🇳🇱 Amsterdam',
      );
    });

    test('does not treat arbitrary lowercase words as country prefixes', () {
      expect(normalizeServerDisplayText('my server'), 'my server');
    });
  });
}