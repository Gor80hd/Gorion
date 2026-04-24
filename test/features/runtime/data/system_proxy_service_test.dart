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
    expect(override, isNot(contains('steampowered.com')));
    expect(
      override.split(';'),
      orderedEquals(managedWindowsSystemProxyOverrideEntries),
    );
  });

  test('managed Windows system proxy override can bypass Steam', () {
    final override = buildManagedWindowsSystemProxyOverride(bypassSteam: true);

    expect(override, contains('192.168.*;*.steampowered.com'));
    expect(override, contains('*.steamcommunity.com'));
    expect(override, contains('steamcontent.com'));
    expect(override, endsWith('valvesoftware.com'));
    expect(
      override.split(';'),
      orderedEquals([
        ...managedWindowsSystemProxyOverrideEntries,
        ...managedWindowsSteamProxyOverrideEntries,
      ]),
    );
  });

  test(
    'windowsProxyServerPointsToManagedEndpoint accepts per-protocol loopback normalization',
    () {
      expect(
        windowsProxyServerPointsToManagedEndpoint(
          currentProxyServer: 'http=localhost:7038;https=127.0.0.1:7038',
          managedProxyServer: '127.0.0.1:7038',
        ),
        isTrue,
      );
    },
  );

  test(
    'windowsProxyServerPointsToManagedEndpoint rejects a different loopback port',
    () {
      expect(
        windowsProxyServerPointsToManagedEndpoint(
          currentProxyServer: 'http=127.0.0.1:7040;https=127.0.0.1:7040',
          managedProxyServer: '127.0.0.1:7038',
        ),
        isFalse,
      );
    },
  );

  test(
    'windowsProxyBypassListsMatch ignores order and casing for equivalent lists',
    () {
      expect(
        windowsProxyBypassListsMatch(
          currentBypassList: 'LOCALHOST;127.*;<local>',
          managedBypassList: '<local>;localhost;127.*',
        ),
        isTrue,
      );
    },
  );

  test('windowsProxyBypassListsMatch rejects a missing bypass entry', () {
    expect(
      windowsProxyBypassListsMatch(
        currentBypassList: 'localhost;127.*',
        managedBypassList: '<local>;localhost;127.*',
      ),
      isFalse,
    );
  });
}
