import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:gorion/features/runtime/data/system_proxy_service.dart';
import 'package:gorion/features/runtime/model/runtime_mode.dart';

const saved = MacosServiceProxyState(
  service: 'Wi-Fi',
  web: MacosProxyEndpointState(enabled: false),
  secureWeb: MacosProxyEndpointState(enabled: false),
  socks: MacosProxyEndpointState(enabled: false),
  bypassDomains: [],
);
const managed = MacosServiceProxyState(
  service: 'Wi-Fi',
  web: MacosProxyEndpointState(enabled: true, server: '127.0.0.1', port: 7038),
  secureWeb: MacosProxyEndpointState(
    enabled: true,
    server: 'corp.proxy',
    port: 3128,
  ),
  socks: MacosProxyEndpointState(enabled: false),
  bypassDomains: ['user.example'],
);
void log(String line, {bool isError = false}) {}

class FailingBackend extends MacosSystemProxyBackend {
  bool applied = false;
  MacosServiceProxyState? initialState;
  bool failRestore = true;
  @override
  Future<List<String>> listActiveServices() async => ['Wi-Fi'];
  @override
  Future<MacosServiceProxyState> readService(String service) async =>
      applied ? managed : (initialState ?? saved);
  @override
  Future<void> applyManaged(
    String service, {
    required int mixedPort,
    required bool bypassSteam,
    required List<String> existingBypassDomains,
  }) async {
    applied = true;
    throw StateError('Partial write');
  }

  @override
  Future<void> restoreService(
    MacosServiceProxyState saved, {
    MacosServiceProxyState? current,
    int? managedPort,
    List<String>? managedBypassDomains,
  }) async {
    if (failRestore) throw StateError('Restore unavailable');
    applied = false;
  }
}

void main() {
  test('failed rollback survives reconnect and can be retried', () async {
    final dir = await Directory.systemTemp.createTemp('gorion-recovery-');
    addTearDown(() => dir.delete(recursive: true));
    final backend = FailingBackend();
    final service = SystemProxyService(macosBackend: backend);
    final journal = File('${dir.path}/system-proxy.json');
    await expectLater(
      service.enable(
        mode: RuntimeMode.systemProxy,
        runtimeDir: dir,
        mixedPort: 7038,
        onLog: log,
      ),
      throwsStateError,
    );
    expect(await journal.exists(), isTrue);
    final original = await journal.readAsString();
    await expectLater(
      service.enable(
        mode: RuntimeMode.systemProxy,
        runtimeDir: dir,
        mixedPort: 7039,
        onLog: log,
      ),
      throwsStateError,
    );
    expect(await journal.readAsString(), original);
    backend.failRestore = false;
    await service.restore(runtimeDir: dir, lease: null, onLog: log);
    expect(await journal.exists(), isFalse);
    expect(backend.applied, isFalse);
  }, testOn: 'mac-os');

  test(
    'restore preserves foreign endpoints and edited bypass domains',
    () async {
      final calls = <List<String>>[];
      final backend = MacosSystemProxyBackend(
        processRunner:
            (
              executable,
              arguments, {
              timeout = const Duration(seconds: 10),
            }) async {
              calls.add(arguments);
              return ProcessResult(0, 0, '', '');
            },
      );
      await backend.restoreService(
        saved,
        current: managed,
        managedPort: 7038,
        managedBypassDomains: ['*.local'],
      );
      expect(calls, [
        ['-setwebproxy', 'Wi-Fi', '', '0'],
        ['-setwebproxystate', 'Wi-Fi', 'off'],
      ]);
    },
  );
  test(
    'one failed endpoint does not prevent cleanup of other endpoints',
    () async {
      final calls = <List<String>>[];
      final backend = MacosSystemProxyBackend(
        processRunner:
            (
              executable,
              arguments, {
              timeout = const Duration(seconds: 10),
            }) async {
              calls.add(arguments);
              return ProcessResult(
                0,
                arguments.first == '-setwebproxy' ? 1 : 0,
                '',
                '',
              );
            },
      );
      await expectLater(
        backend.restoreService(saved),
        throwsA(isA<ProcessException>()),
      );
      expect(calls, contains(equals(['-setwebproxystate', 'Wi-Fi', 'off'])));
      expect(
        calls,
        contains(equals(['-setsocksfirewallproxystate', 'Wi-Fi', 'off'])),
      );
      expect(calls.last, ['-setproxybypassdomains', 'Wi-Fi', 'Empty']);
    },
  );

  test(
    'restores saved automatic proxy switches without replacing the PAC URL',
    () async {
      final calls = <List<String>>[];
      final backend = MacosSystemProxyBackend(
        processRunner:
            (
              executable,
              arguments, {
              timeout = const Duration(seconds: 10),
            }) async {
              calls.add(arguments);
              return ProcessResult(0, 0, '', '');
            },
      );
      const original = MacosServiceProxyState(
        service: 'Wi-Fi',
        web: MacosProxyEndpointState(enabled: false),
        secureWeb: MacosProxyEndpointState(enabled: false),
        socks: MacosProxyEndpointState(enabled: false),
        bypassDomains: [],
        autoConfigEnabled: true,
        autoConfigUrl: 'https://corp.example/proxy.pac',
        autoDiscoveryEnabled: true,
      );
      const current = MacosServiceProxyState(
        service: 'Wi-Fi',
        web: MacosProxyEndpointState(enabled: false),
        secureWeb: MacosProxyEndpointState(enabled: false),
        socks: MacosProxyEndpointState(enabled: false),
        bypassDomains: [],
        autoConfigUrl: 'https://corp.example/proxy.pac',
      );
      await backend.restoreService(
        original,
        current: current,
        managedPort: 7038,
      );
      expect(calls, [
        ['-setautoproxystate', 'Wi-Fi', 'on'],
        ['-setproxyautodiscovery', 'Wi-Fi', 'on'],
      ]);
    },
  );

  test(
    'authenticated proxy is rejected before writing or replacing credentials',
    () async {
      final dir = await Directory.systemTemp.createTemp('gorion-auth-proxy-');
      addTearDown(() => dir.delete(recursive: true));
      final backend = FailingBackend()
        ..initialState = const MacosServiceProxyState(
          service: 'Wi-Fi',
          web: MacosProxyEndpointState(
            enabled: true,
            authenticated: true,
            server: 'corp.proxy',
            port: 3128,
          ),
          secureWeb: MacosProxyEndpointState(enabled: false),
          socks: MacosProxyEndpointState(enabled: false),
          bypassDomains: [],
        );
      await expectLater(
        SystemProxyService(macosBackend: backend).enable(
          mode: RuntimeMode.systemProxy,
          runtimeDir: dir,
          mixedPort: 7038,
          onLog: log,
        ),
        throwsUnsupportedError,
      );
      expect(backend.applied, isFalse);
      expect(await File('${dir.path}/system-proxy.json').exists(), isFalse);
    },
    testOn: 'mac-os',
  );

  test('guard-disabled endpoint still belongs to the recovery journal', () {
    const endpoint = MacosProxyEndpointState(
      enabled: false,
      server: '127.0.0.1',
      port: 7038,
    );
    expect(endpoint.pointsTo(7038), isTrue);
    expect(endpoint.pointsTo(7039), isFalse);
  });
}
