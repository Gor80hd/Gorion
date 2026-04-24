import 'package:flutter_test/flutter_test.dart';
import 'package:gorion_clean/features/update/model/app_version.dart';

void main() {
  test('parses GitHub-style version tags', () {
    expect(normalizeAppVersionLabel('v1.6.2'), '1.6.2');
    expect(normalizeAppVersionLabel('Gorion-v2.0.1+42'), '2.0.1');
    expect(normalizeAppVersionLabel('1.7'), '1.7.0');
  });

  test('compares app versions semantically', () {
    final current = AppVersion.tryParse('1.5.0')!;
    final patch = AppVersion.tryParse('v1.5.1')!;
    final major = AppVersion.tryParse('2.0.0')!;
    final beta = AppVersion.tryParse('1.6.0-beta.1')!;
    final stable = AppVersion.tryParse('1.6.0')!;

    expect(patch.compareTo(current), greaterThan(0));
    expect(major.compareTo(patch), greaterThan(0));
    expect(beta.compareTo(stable), lessThan(0));
    expect(stable.compareTo(beta), greaterThan(0));
  });
}
