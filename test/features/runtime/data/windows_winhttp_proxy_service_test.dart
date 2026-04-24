import 'package:flutter_test/flutter_test.dart';
import 'package:gorion_clean/features/runtime/data/windows_winhttp_proxy_service.dart';

void main() {
  test('parseWinHttpShowProxyOutput detects direct access', () {
    const output = '''
Current WinHTTP proxy settings:

    Direct access (no proxy server).
''';

    final settings = parseWinHttpShowProxyOutput(output);

    expect(settings.isDirect, isTrue);
    expect(settings.proxyServer, isNull);
    expect(settings.bypassList, isNull);
  });

  test('parseWinHttpShowProxyOutput reads proxy server and bypass list', () {
    const output = '''
Current WinHTTP proxy settings:

    Proxy Server(s) :  http=127.0.0.1:7038;https=127.0.0.1:7038
    Bypass List     :  localhost;127.*;<local>
''';

    final settings = parseWinHttpShowProxyOutput(output);

    expect(settings.isDirect, isFalse);
    expect(settings.proxyServer, 'http=127.0.0.1:7038;https=127.0.0.1:7038');
    expect(settings.bypassList, 'localhost;127.*;<local>');
  });

  test('parseWinHttpShowProxyOutput falls back to localized field labels', () {
    const output = '''
Текущие параметры прокси WinHTTP:

    Сервер(ы) прокси :  http=127.0.0.1:7038;https=127.0.0.1:7038
    Список исключений:  localhost;127.*;<local>
''';

    final settings = parseWinHttpShowProxyOutput(output);

    expect(settings.isDirect, isFalse);
    expect(settings.proxyServer, 'http=127.0.0.1:7038;https=127.0.0.1:7038');
    expect(settings.bypassList, 'localhost;127.*;<local>');
  });

  test('managed WinHTTP proxy server targets the local mixed inbound', () {
    expect(buildManagedWindowsWinHttpProxyServer(7038), '127.0.0.1:7038');
  });

  test('managed WinHTTP proxy bypass can include Steam', () {
    final bypassList = buildManagedWindowsWinHttpBypassList(bypassSteam: true);

    expect(bypassList, contains('*.steampowered.com'));
    expect(bypassList, contains('steamcommunity.com'));
    expect(bypassList, endsWith('valvesoftware.com'));
  });

  test(
    'WinHTTP managed proxy detection accepts equivalent per-protocol loopback endpoints',
    () {
      final current = WindowsWinHttpProxySettings(
        proxyServer: 'http=localhost:7038;https=127.0.0.1:7038',
        bypassList: buildManagedWindowsWinHttpBypassList(),
      );
      final managed = WindowsWinHttpProxySettings(
        proxyServer: '127.0.0.1:7038',
        bypassList: buildManagedWindowsWinHttpBypassList(),
      );

      expect(current.isManagedBy(managed), isTrue);
    },
  );

  test('WinHTTP managed proxy detection rejects a different bypass list', () {
    final current = WindowsWinHttpProxySettings(
      proxyServer: 'http=localhost:7038;https=127.0.0.1:7038',
      bypassList: '${buildManagedWindowsWinHttpBypassList()};intranet.local',
    );
    final managed = WindowsWinHttpProxySettings(
      proxyServer: '127.0.0.1:7038',
      bypassList: buildManagedWindowsWinHttpBypassList(),
    );

    expect(current.isManagedBy(managed), isFalse);
  });

  test('WinHTTP managed proxy detection accepts reordered bypass entries', () {
    final reorderedBypassList = [
      ...buildManagedWindowsWinHttpBypassList().split(';').reversed,
    ].join(';').replaceFirst('localhost', 'LOCALHOST');
    final current = WindowsWinHttpProxySettings(
      proxyServer: 'http=localhost:7038;https=127.0.0.1:7038',
      bypassList: reorderedBypassList,
    );
    final managed = WindowsWinHttpProxySettings(
      proxyServer: '127.0.0.1:7038',
      bypassList: buildManagedWindowsWinHttpBypassList(),
    );

    expect(current.isManagedBy(managed), isTrue);
  });
}
