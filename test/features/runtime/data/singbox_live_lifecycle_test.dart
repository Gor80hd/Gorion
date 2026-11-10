import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:gorion_clean/features/runtime/data/runtime_engine.dart';
import 'package:gorion_clean/features/runtime/data/singbox_runtime_service.dart';
import 'package:gorion_clean/features/runtime/data/singbox_runtime_support.dart';
import 'package:gorion_clean/features/runtime/model/runtime_mode.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  test(
    'real core restarts, serializes stop, and reports unexpected exit',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'gorion-core-lifecycle-',
      );
      overrideGorionRuntimeRoot(dir.path);
      final service = SingboxRuntimeService();
      addTearDown(() async {
        await service.stop();
        overrideGorionRuntimeRoot(null);
        await dir.delete(recursive: true);
      });
      const config =
          '{"outbounds":[{"type":"socks","tag":"test","server":"127.0.0.1","server_port":9}]}';
      Future<void> start({RuntimeExitCallback? onExit}) async {
        await service.start(
          profileId: 'test',
          templateConfig: config,
          urlTestUrl: 'http://127.0.0.1:9',
          mode: RuntimeMode.mixed,
          onExit: onExit,
        );
      }

      await start();
      expect(service.session, isNotNull);
      await Future.wait([service.stop(), start(), service.stop()]);
      expect(service.session, isNull);
      final exited = Completer<void>();
      await start(
        onExit: (_, code) {
          if (!exited.isCompleted) exited.complete();
        },
      );
      final marker = File('${dir.path}/runtime-process.json');
      final childPid =
          (jsonDecode(await marker.readAsString()) as Map)['pid'] as int;
      Process.killPid(childPid, ProcessSignal.sigkill);
      await exited.future.timeout(const Duration(seconds: 10));
      expect(service.session, isNull);
      expect(await marker.exists(), isFalse);
    },
    testOn: 'mac-os',
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
