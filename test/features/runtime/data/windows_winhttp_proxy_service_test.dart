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

  test('managed WinHTTP proxy server targets the local mixed inbound', () {
    expect(
      buildManagedWindowsWinHttpProxyServer(7038),
      '127.0.0.1:7038',
    );
  });
}
