import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gorion_clean/features/auto_select/utils/auto_select_network_probe.dart';

void main() {
  test('probeHttpViaLocalProxy accepts a 204 response from the proxy path', () async {
    final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => proxy.close(force: true));
    proxy.listen((request) async {
      request.response.statusCode = HttpStatus.noContent;
      await request.response.close();
    });

    final ok = await probeHttpViaLocalProxy(
      mixedPort: proxy.port,
      url: Uri.parse('http://probe.test/success'),
      timeout: const Duration(seconds: 2),
    );

    expect(ok, isTrue);
  });

  test(
    'probeHttpViaLocalProxy rejects an error response even when the proxy returns a body',
    () async {
      final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => proxy.close(force: true));
      proxy.listen((request) async {
        request.response.statusCode = HttpStatus.badGateway;
        request.response.write('blocked by upstream');
        await request.response.close();
      });

      final ok = await probeHttpViaLocalProxy(
        mixedPort: proxy.port,
        url: Uri.parse('http://probe.test/failure'),
        timeout: const Duration(seconds: 2),
      );

      expect(ok, isFalse);
    },
  );

  test('probeHttpViaLocalProxy does not send a dedicated User-Agent header', () async {
    final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => proxy.close(force: true));

    String? seenUserAgent;
    proxy.listen((request) async {
      seenUserAgent = request.headers.value(HttpHeaders.userAgentHeader);
      request.response.statusCode = HttpStatus.noContent;
      await request.response.close();
    });

    final ok = await probeHttpViaLocalProxy(
      mixedPort: proxy.port,
      url: Uri.parse('http://probe.test/headers'),
      timeout: const Duration(seconds: 2),
    );

    expect(ok, isTrue);
    expect(seenUserAgent, isNull);
  });

  test('probeHttpViaLocalProxyTargets falls back to a later working URL', () async {
    final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => proxy.close(force: true));
    proxy.listen((request) async {
      if (request.uri.path == '/blocked') {
        request.response.statusCode = HttpStatus.badGateway;
      } else {
        request.response.statusCode = HttpStatus.noContent;
      }
      await request.response.close();
    });

    final ok = await probeHttpViaLocalProxyTargets(
      mixedPort: proxy.port,
      urls: [
        Uri.parse('http://probe.test/blocked'),
        Uri.parse('http://probe.test/recovered'),
      ],
      timeout: const Duration(seconds: 2),
    );

    expect(ok, isTrue);
  });

  test(
    'measureDownloadThroughputViaLocalProxyTargets falls back to a later working URL',
    () async {
      final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => proxy.close(force: true));
      proxy.listen((request) async {
        if (request.uri.path == '/blocked') {
          request.response.statusCode = HttpStatus.badGateway;
          await request.response.close();
          return;
        }

        request.response.statusCode = HttpStatus.ok;
        request.response.add(List<int>.filled(64 * 1024, 7));
        await request.response.close();
      });

      final throughput = await measureDownloadThroughputViaLocalProxyTargets(
        mixedPort: proxy.port,
        urls: [
          Uri.parse('http://probe.test/blocked'),
          Uri.parse('http://probe.test/throughput'),
        ],
        timeout: const Duration(seconds: 2),
      );

      expect(throughput, greaterThan(0));
    },
  );
}