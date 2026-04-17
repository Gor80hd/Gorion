import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gorion_clean/features/settings/data/launch_at_startup_service.dart';

void main() {
  group('DesktopLaunchAtStartupService', () {
    test(
      'enables the startup entry and removes the legacy scheduled task',
      () async {
        final processRunner = _FakeProcessRunner();
        final startupEntryService = _FakeLaunchAtStartupService(enabled: false);
        final service = DesktopLaunchAtStartupService(
          appName: 'Gorion',
          appPath: r'C:\Program Files\Gorion\gorion_clean.exe',
          processRunner: processRunner.call,
          startupEntryService: startupEntryService,
        );

        processRunner.queue(0);

        final enabled = await service.setEnabled(true);

        expect(enabled, isTrue);
        expect(startupEntryService.setEnabledCalls, [true]);
        expect(processRunner.invocations, hasLength(1));
        expect(
          processRunner.invocations.single.arguments.last,
          contains('Unregister-ScheduledTask'),
        );
      },
    );

    test('reports enabled after migrating legacy startup entry', () async {
      final processRunner = _FakeProcessRunner();
      final startupEntryService = _FakeLaunchAtStartupService(enabled: false);
      final service = DesktopLaunchAtStartupService(
        appName: 'Gorion',
        appPath: r'C:\Program Files\Gorion\gorion_clean.exe',
        processRunner: processRunner.call,
        startupEntryService: startupEntryService,
      );

      processRunner.queue(0);
      processRunner.queue(0);

      final enabled = await service.isEnabled();

      expect(enabled, isTrue);
      expect(startupEntryService.setEnabledCalls, [true]);
      expect(processRunner.invocations, hasLength(2));
      expect(
        processRunner.invocations.first.arguments.last,
        contains('Get-ScheduledTask'),
      );
      expect(
        processRunner.invocations.last.arguments.last,
        contains('Unregister-ScheduledTask'),
      );
    });

    test(
      'disabling autostart removes the startup entry and legacy task',
      () async {
        final processRunner = _FakeProcessRunner();
        final startupEntryService = _FakeLaunchAtStartupService(enabled: true);
        final service = DesktopLaunchAtStartupService(
          appName: 'Gorion',
          appPath: r'C:\Program Files\Gorion\gorion_clean.exe',
          processRunner: processRunner.call,
          startupEntryService: startupEntryService,
        );

        processRunner.queue(0);

        final disabled = await service.setEnabled(false);

        expect(disabled, isTrue);
        expect(startupEntryService.setEnabledCalls, [false]);
        expect(processRunner.invocations, hasLength(1));
        expect(
          processRunner.invocations.single.arguments.last,
          contains('Unregister-ScheduledTask'),
        );
      },
    );

    test(
      'keeps reporting enabled when a legacy scheduled task exists',
      () async {
        final processRunner = _FakeProcessRunner();
        final startupEntryService = _FakeLaunchAtStartupService(
          enabled: false,
          setEnabledResult: false,
        );
        final service = DesktopLaunchAtStartupService(
          appName: 'Gorion',
          appPath: r'C:\Program Files\Gorion\gorion_clean.exe',
          processRunner: processRunner.call,
          startupEntryService: startupEntryService,
        );

        processRunner.queue(0);

        final enabled = await service.isEnabled();

        expect(enabled, isTrue);
        expect(startupEntryService.setEnabledCalls, [true]);
        expect(processRunner.invocations, hasLength(1));
        expect(
          processRunner.invocations.single.arguments.last,
          contains('Get-ScheduledTask'),
        );
      },
    );

    test('ignores legacy scheduled task cleanup failures on enable', () async {
      final processRunner = _FakeProcessRunner();
      final startupEntryService = _FakeLaunchAtStartupService(enabled: false);
      final service = DesktopLaunchAtStartupService(
        appName: 'Gorion',
        appPath: r'C:\Program Files\Gorion\gorion_clean.exe',
        processRunner: processRunner.call,
        startupEntryService: startupEntryService,
      );

      processRunner.queue(1, stderr: 'Access is denied');

      final enabled = await service.setEnabled(true);

      expect(enabled, isTrue);
      expect(startupEntryService.setEnabledCalls, [true]);
      expect(processRunner.invocations, hasLength(1));
    });
  });
}

class _FakeLaunchAtStartupService implements LaunchAtStartupService {
  _FakeLaunchAtStartupService({
    required this.enabled,
    this.setEnabledResult = true,
  });

  bool enabled;
  final bool setEnabledResult;
  final List<bool> setEnabledCalls = <bool>[];

  @override
  Future<bool> isEnabled() async {
    return enabled;
  }

  @override
  Future<bool> setEnabled(bool enabled) async {
    setEnabledCalls.add(enabled);
    if (setEnabledResult) {
      this.enabled = enabled;
    }
    return setEnabledResult;
  }
}

class _FakeProcessRunner {
  final List<_ProcessInvocation> invocations = <_ProcessInvocation>[];
  final List<ProcessResult> _results = <ProcessResult>[];

  void queue(int exitCode, {String stdout = '', String stderr = ''}) {
    _results.add(ProcessResult(0, exitCode, stdout, stderr));
  }

  Future<ProcessResult> call(String executable, List<String> arguments) async {
    invocations.add(
      _ProcessInvocation(executable: executable, arguments: List.of(arguments)),
    );
    if (_results.isEmpty) {
      throw StateError('No queued process result for $executable.');
    }
    return _results.removeAt(0);
  }
}

class _ProcessInvocation {
  const _ProcessInvocation({required this.executable, required this.arguments});

  final String executable;
  final List<String> arguments;
}
