import 'package:flutter_test/flutter_test.dart';
import 'package:gorion_clean/features/auto_select/model/auto_select_state.dart';

void main() {
  test('default domain probe config resolves to the built-in fallback catalog', () {
    final resolved = resolveAutoSelectDomainProbeUrls(
      defaultAutoSelectDomainProbeUrl,
      rotationKey: 'profile-1::domain',
    );

    expect(resolved, hasLength(defaultAutoSelectDomainProbeUrls.length));
    expect(resolved.toSet(), defaultAutoSelectDomainProbeUrls.toSet());
  });

  test('custom domain probe config stays pinned to the configured override', () {
    final resolved = resolveAutoSelectDomainProbeUrls(
      'https://example.com/custom-check',
      rotationKey: 'profile-1::domain',
    );

    expect(resolved, ['https://example.com/custom-check']);
  });

  test('default throughput probe config resolves to the built-in fallback catalog', () {
    final resolved = resolveAutoSelectThroughputProbeUrls(
      defaultAutoSelectThroughputProbeUrl,
      rotationKey: 'profile-1::throughput',
    );

    expect(
      resolved.toSet(),
      defaultAutoSelectThroughputProbeUrls.toSet(),
    );
  });

  test('resolveAutoSelectUrlTestUrl keeps custom overrides untouched', () {
    final url = resolveAutoSelectUrlTestUrl(
      'https://example.com/custom-urltest',
      rotationKey: 'profile-1::urltest',
    );

    expect(url, 'https://example.com/custom-urltest');
  });

  test('resolveAutoSelectUrlTestUrl picks one target from the default catalog', () {
    final url = resolveAutoSelectUrlTestUrl(
      defaultAutoSelectDomainProbeUrl,
      rotationKey: 'profile-1::urltest',
    );

    expect(defaultAutoSelectDomainProbeUrls, contains(url));
  });
}