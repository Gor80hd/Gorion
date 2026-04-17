import 'package:flutter_test/flutter_test.dart';
import 'package:gorion_clean/features/runtime/data/system_proxy_service.dart';

void main() {
  test('managed Windows system proxy server uses a single host port pair', () {
    expect(buildManagedWindowsSystemProxyServer(7038), '127.0.0.1:7038');
  });

  test('managed Windows system proxy override includes local subnets', () {
    final override = buildManagedWindowsSystemProxyOverride();

    expect(override, startsWith('<local>;localhost;127.*;10.*;'));
    expect(override, contains('172.16.*;172.17.*;172.18.*'));
    expect(override, contains('172.29.*;172.30.*;172.31.*'));
    expect(override, endsWith('192.168.*'));
    expect(
      override.split(';'),
      orderedEquals(managedWindowsSystemProxyOverrideEntries),
    );
  });
}
