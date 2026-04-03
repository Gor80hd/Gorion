import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gorion_clean/features/runtime/data/clash_api_client.dart';

void main() {
  late HttpServer server;
  late ClashApiClient client;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      switch (request.uri.path) {
        case '/proxies':
          request.response.headers.contentType = ContentType(
            'text',
            'plain',
            charset: 'utf-8',
          );
          request.response.write(
            jsonEncode({
              'proxies': {
                'gorion-manual': {
                  'name': 'gorion-manual',
                  'now': 'node-a',
                  'history': const [],
                },
                'node-a': {
                  'name': 'node-a',
                  'history': [
                    {'time': '2026-04-03T18:55:11.0992671+03:00', 'delay': 123},
                  ],
                },
                'node-b': {'name': 'node-b', 'history': const []},
              },
            }),
          );
          await request.response.close();
          return;
        case '/group/gorion-auto/delay':
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({'node-a': 91, 'node-b': 137, 'ignored': 'n/a'}),
          );
          await request.response.close();
          return;
        default:
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
      }
    });

    client = ClashApiClient(
      baseUrl: 'http://${server.address.address}:${server.port}',
      secret: 'test-secret',
    );
  });

  tearDown(() async {
    await server.close(force: true);
  });

  test('fetchSnapshot decodes text/plain JSON proxy payloads', () async {
    final snapshot = await client.fetchSnapshot(selectorTag: 'gorion-manual');

    expect(snapshot.selectedTag, 'node-a');
    expect(snapshot.delayByTag, {'node-a': 123});
  });

  test('measureGroupDelay keeps numeric delay entries only', () async {
    final delays = await client.measureGroupDelay(
      groupTag: 'gorion-auto',
      testUrl: 'https://www.gstatic.com/generate_204',
      timeoutMs: 2000,
    );

    expect(delays, {'node-a': 91, 'node-b': 137});
  });
}
