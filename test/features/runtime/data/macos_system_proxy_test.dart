import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gorion/features/runtime/data/system_proxy_service.dart';
import 'package:gorion/features/runtime/model/runtime_mode.dart';

class _FakeProcessRunner {
  _FakeProcessRunner(this.handler);

  final Map<String, String> Function(List<String> arguments) handler;
  final List<List<String>> calls = [];

  Future<ProcessResult> call(
    String executable,
    List<String> arguments, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    calls.add(arguments);
    final response = handler(arguments);
    return ProcessResult(
      0,
      0,
      response['stdout'] ?? '',
      response['stderr'] ?? '',
    );
  }
}

void main() {
  group('MacosSystemProxyBackend', () {
    test(
      'listActiveServices skips the header note and disabled services',
      () async {
        final runner = _FakeProcessRunner((arguments) {
          return {
            'stdout':
                'An asterisk (*) denotes that a network service is disabled.\n'
                'AX88179B\n*Bluetooth PAN\nWi-Fi\niPhone USB\n',
          };
        });
        final backend = MacosSystemProxyBackend(processRunner: runner.call);

        expect(
          await backend.listActiveServices(),
          orderedEquals(['AX88179B', 'Wi-Fi', 'iPhone USB']),
        );
        expect(runner.calls.single, ['-listallnetworkservices']);
      },
    );

    test('readService parses endpoints and bypass domains', () async {
      final runner = _FakeProcessRunner((arguments) {
        return switch (arguments.first) {
          '-getwebproxy' => {
            'stdout':
                'Enabled: Yes\nServer: 127.0.0.1\nPort: 7890\nAuthenticated Proxy Enabled: 0\n',
          },
          '-getsecurewebproxy' => {
            'stdout': 'Enabled: No\nServer: \nPort: 0\n',
          },
          '-getsocksfirewallproxy' => {
            'stdout':
                'Enabled: Yes\nServer: 10.0.0.2\nPort: 1080\nAuthenticated Proxy Enabled: 0\n',
          },
          '-getproxybypassdomains' => {'stdout': '*.local\n169.254/16\n'},
          _ => {'stdout': ''},
        };
      });
      final backend = MacosSystemProxyBackend(processRunner: runner.call);

      final state = await backend.readService('Wi-Fi');

      expect(state.web.enabled, isTrue);
      expect(state.web.server, '127.0.0.1');
      expect(state.web.port, 7890);
      expect(state.secureWeb.enabled, isFalse);
      expect(state.socks.server, '10.0.0.2');
      expect(state.bypassDomains, orderedEquals(['*.local', '169.254/16']));
    });

    test('readService treats the empty bypass hint as an empty list', () async {
      final runner = _FakeProcessRunner((arguments) {
        return switch (arguments.first) {
          '-getproxybypassdomains' => {
            'stdout': "There aren't any bypass domains set.\n",
          },
          _ => {'stdout': 'Enabled: No\nServer: \nPort: 0\n'},
        };
      });
      final backend = MacosSystemProxyBackend(processRunner: runner.call);

      final state = await backend.readService('Wi-Fi');

      expect(state.bypassDomains, isEmpty);
    });

    test(
      'applyManaged points web, secure web and socks at the mixed port',
      () async {
        final runner = _FakeProcessRunner((_) => {'stdout': ''});
        final backend = MacosSystemProxyBackend(processRunner: runner.call);

        await backend.applyManaged(
          'Wi-Fi',
          mixedPort: 7038,
          bypassSteam: true,
          existingBypassDomains: ['corp.example'],
        );

        expect(runner.calls, hasLength(6));
        expect(
          runner.calls[0],
          orderedEquals(['-setwebproxy', 'Wi-Fi', '127.0.0.1', '7038']),
        );
        expect(
          runner.calls[1],
          orderedEquals(['-setsecurewebproxy', 'Wi-Fi', '127.0.0.1', '7038']),
        );
        expect(
          runner.calls[2],
          orderedEquals([
            '-setsocksfirewallproxy',
            'Wi-Fi',
            '127.0.0.1',
            '7038',
          ]),
        );
        final bypass = runner.calls[3];
        expect(bypass[0], '-setproxybypassdomains');
        expect(bypass, contains('corp.example'));
        expect(bypass, contains('*.local'));
        expect(bypass, contains('steampowered.com'));
      },
    );

    test('restoreService re-enables a previously enabled endpoint', () async {
      final runner = _FakeProcessRunner((_) => {'stdout': ''});
      final backend = MacosSystemProxyBackend(processRunner: runner.call);

      const saved = MacosServiceProxyState(
        service: 'Wi-Fi',
        web: MacosProxyEndpointState(
          enabled: true,
          server: '10.0.0.5',
          port: 8080,
        ),
        secureWeb: MacosProxyEndpointState(enabled: false),
        socks: MacosProxyEndpointState(enabled: false),
        bypassDomains: ['*.local'],
      );

      await backend.restoreService(saved);

      expect(
        runner.calls[0],
        orderedEquals(['-setwebproxy', 'Wi-Fi', '10.0.0.5', '8080']),
      );
      // A previously disabled endpoint gets its stored values cleared and
      // is explicitly turned back off (`-set*proxy` enables as a side effect).
      expect(
        runner.calls[1],
        orderedEquals(['-setsecurewebproxy', 'Wi-Fi', '', '0']),
      );
      expect(
        runner.calls[2],
        orderedEquals(['-setsecurewebproxystate', 'Wi-Fi', 'off']),
      );
      expect(
        runner.calls[5],
        orderedEquals(['-setproxybypassdomains', 'Wi-Fi', '*.local']),
      );
    });

    test(
      'restoreService clears the bypass list with the empty marker',
      () async {
        final runner = _FakeProcessRunner((_) => {'stdout': ''});
        final backend = MacosSystemProxyBackend(processRunner: runner.call);

        const saved = MacosServiceProxyState(
          service: 'Wi-Fi',
          web: MacosProxyEndpointState(enabled: false),
          secureWeb: MacosProxyEndpointState(enabled: false),
          socks: MacosProxyEndpointState(enabled: false),
          bypassDomains: [],
        );

        await backend.restoreService(saved);

        expect(
          runner.calls.last,
          orderedEquals(['-setproxybypassdomains', 'Wi-Fi', 'Empty']),
        );
      },
    );

    test(
      'isServiceManaged requires a loopback endpoint on the managed port',
      () {
        const backend = MacosSystemProxyBackend();

        const managed = MacosServiceProxyState(
          service: 'Wi-Fi',
          web: MacosProxyEndpointState(
            enabled: true,
            server: '127.0.0.1',
            port: 7038,
          ),
          secureWeb: MacosProxyEndpointState(enabled: false),
          socks: MacosProxyEndpointState(enabled: false),
          bypassDomains: [],
        );
        const foreign = MacosServiceProxyState(
          service: 'Wi-Fi',
          web: MacosProxyEndpointState(
            enabled: true,
            server: '10.0.0.9',
            port: 7038,
          ),
          secureWeb: MacosProxyEndpointState(enabled: false),
          socks: MacosProxyEndpointState(enabled: false),
          bypassDomains: [],
        );
        const otherPort = MacosServiceProxyState(
          service: 'Wi-Fi',
          web: MacosProxyEndpointState(
            enabled: true,
            server: '127.0.0.1',
            port: 9999,
          ),
          secureWeb: MacosProxyEndpointState(enabled: false),
          socks: MacosProxyEndpointState(enabled: false),
          bypassDomains: [],
        );

        expect(backend.isServiceManaged(managed, managedPort: 7038), isTrue);
        expect(backend.isServiceManaged(foreign, managedPort: 7038), isFalse);
        expect(backend.isServiceManaged(otherPort, managedPort: 7038), isFalse);
      },
    );

    test('marker roundtrip preserves the per-service state', () {
      const state = MacosServiceProxyState(
        service: 'Thunderbolt Bridge',
        web: MacosProxyEndpointState(
          enabled: true,
          server: '192.168.1.5',
          port: 3128,
        ),
        secureWeb: MacosProxyEndpointState(enabled: false),
        socks: MacosProxyEndpointState(
          enabled: true,
          server: '::1',
          port: 1080,
        ),
        bypassDomains: ['*.local', 'corp.example'],
      );

      final restored = MacosServiceProxyState.fromJson(state.toJson());

      expect(restored.service, state.service);
      expect(restored.web.server, '192.168.1.5');
      expect(restored.web.port, 3128);
      expect(restored.secureWeb.enabled, isFalse);
      expect(restored.socks.enabled, isTrue);
      expect(restored.bypassDomains, orderedEquals(state.bypassDomains));
    });
  });

  group('SystemProxyService on macOS', () {
    test(
      'enable writes the marker before applying and restore replays the saved state',
      () async {
        final tempDir = await Directory.systemTemp.createTemp('gorion-proxy-');
        addTearDown(() async {
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        });

        final appliedServices = <String>[];
        final restoredServices = <String>[];
        final logLines = <String>[];
        void onLog(String line, {bool isError = false}) => logLines.add(line);

        final backend = _FakeMacosBackend(
          onApply: appliedServices.add,
          onRestore: restoredServices.add,
        );
        final service = SystemProxyService(macosBackend: backend);

        final lease = await service.enable(
          mode: RuntimeMode.systemProxy,
          runtimeDir: tempDir,
          mixedPort: 7038,
          onLog: onLog,
        );

        expect(lease, isNotNull);
        expect(File('${tempDir.path}/system-proxy.json').existsSync(), isTrue);
        expect(appliedServices, isNotEmpty);

        await service.restore(runtimeDir: tempDir, lease: lease, onLog: onLog);
        expect(File('${tempDir.path}/system-proxy.json').existsSync(), isFalse);
        expect(restoredServices, orderedEquals(['Wi-Fi']));
      },
      testOn: 'mac-os',
    );
  });
}

class _FakeMacosBackend extends MacosSystemProxyBackend {
  _FakeMacosBackend({this.onApply, this.onRestore});

  final void Function(String service)? onApply;
  final void Function(String service)? onRestore;

  @override
  Future<List<String>> listActiveServices() async => ['Wi-Fi'];

  @override
  Future<MacosServiceProxyState> readService(String service) async {
    return const MacosServiceProxyState(
      service: 'Wi-Fi',
      web: MacosProxyEndpointState(enabled: false),
      secureWeb: MacosProxyEndpointState(enabled: false),
      socks: MacosProxyEndpointState(enabled: false),
      bypassDomains: ['*.local'],
    );
  }

  @override
  Future<void> applyManaged(
    String service, {
    required int mixedPort,
    required bool bypassSteam,
    required List<String> existingBypassDomains,
  }) async {
    onApply?.call(service);
  }

  @override
  bool isServiceManaged(
    MacosServiceProxyState current, {
    required int managedPort,
  }) => true;

  @override
  Future<void> restoreService(
    MacosServiceProxyState saved, {
    MacosServiceProxyState? current,
    int? managedPort,
    List<String>? managedBypassDomains,
  }) async {
    onRestore?.call(saved.service);
  }
}
