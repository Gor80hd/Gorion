import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gorion_clean/features/settings/data/launch_at_startup_service.dart';

void main() {
  group('DesktopLaunchAtStartupService', () {
    test(
      'creates elevated scheduled task and disables legacy run entry',
      () async {
        final processRunner = _FakeProcessRunner();
        final legacyService = _FakeLaunchAtStartupService(enabled: true);
        final service = DesktopLaunchAtStartupService(
          appName: 'Gorion',
          appPath: r'C:\Program Files\Gorion\gorion_clean.exe',
          processRunner: processRunner.call,
          legacyRunEntryService: legacyService,
        );

        processRunner.queue(0);

        final enabled = await service.setEnabled(true);

        expect(enabled, isTrue);
        expect(legacyService.setEnabledCalls, [false]);
        expect(processRunner.invocations, hasLength(1));
        expect(
          processRunner.invocations.single.arguments.last,
          contains('Register-ScheduledTask'),
        );
        expect(
          processRunner.invocations.single.arguments.last,
          contains('RunLevel Highest'),
        );
      },
    );

    test('reports enabled after migrating legacy startup entry', () async {
      final processRunner = _FakeProcessRunner();
      final legacyService = _FakeLaunchAtStartupService(enabled: true);
      final service = DesktopLaunchAtStartupService(
        appName: 'Gorion',
        appPath: r'C:\Program Files\Gorion\gorion_clean.exe',
        processRunner: processRunner.call,
        legacyRunEntryService: legacyService,
      );

      processRunner.queue(1);
      processRunner.queue(0);

      final enabled = await service.isEnabled();

      expect(enabled, isTrue);
      expect(legacyService.setEnabledCalls, [false]);
      expect(processRunner.invocations, hasLength(2));
      expect(
        processRunner.invocations.first.arguments.last,
        contains('Get-ScheduledTask'),
      );
      expect(
        processRunner.invocations.last.arguments.last,
        contains('Register-ScheduledTask'),
      );
    });

    test(
      'disabling autostart removes scheduled task and legacy run entry',
      () async {
        final processRunner = _FakeProcessRunner();
        final legacyService = _FakeLaunchAtStartupService(enabled: true);
        final service = DesktopLaunchAtStartupService(
          appName: 'Gorion',
          appPath: r'C:\Program Files\Gorion\gorion_clean.exe',
          processRunner: processRunner.call,
          legacyRunEntryService: legacyService,
        );

        processRunner.queue(0);

        final disabled = await service.setEnabled(false);

        expect(disabled, isTrue);
        expect(legacyService.setEnabledCalls, [false]);
        expect(processRunner.invocations, hasLength(1));
        expect(
          processRunner.invocations.single.arguments.last,
          contains('Unregister-ScheduledTask'),
        );
      },
    );

    test('quotes Windows arguments for scheduled task actions', () async {
      final processRunner = _FakeProcessRunner();
      final legacyService = _FakeLaunchAtStartupService(enabled: false);
      final service = DesktopLaunchAtStartupService(
        appName: 'Gorion',
        appPath: r'C:\Program Files\Gorion\gorion_clean.exe',
        args: const ['--profile=Main Node', '--title=He said "hi"'],
        processRunner: processRunner.call,
        legacyRunEntryService: legacyService,
      );

      processRunner.queue(0);

      await service.setEnabled(true);

      final script = processRunner.invocations.single.arguments.last;
      expect(script, contains('-Argument'));
      expect(script, contains('"--profile=Main Node"'));
      expect(script, contains(r'"--title=He said \"hi\""'));
    });
  });
}

class _FakeLaunchAtStartupService implements LaunchAtStartupService {
  _FakeLaunchAtStartupService({required this.enabled});

  bool enabled;
  final List<bool> setEnabledCalls = <bool>[];

  @override
  Future<bool> isEnabled() async {
    return enabled;
  }

  @override
  Future<bool> setEnabled(bool enabled) async {
    setEnabledCalls.add(enabled);
    this.enabled = enabled;
    return true;
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
