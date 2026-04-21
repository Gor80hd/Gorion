import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gorion_clean/core/windows/windows_elevation_service.dart';
import 'package:gorion_clean/features/settings/data/launch_at_startup_service.dart';
import 'package:gorion_clean/features/settings/model/desktop_settings.dart';

void main() {
  group('DesktopLaunchAtStartupService', () {
    test(
      'enables the standard startup entry and removes the legacy scheduled task',
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
        expect(startupEntryService.setEnabledCalls, [
          (enabled: true, priority: LaunchAtStartupPriority.standard),
        ]);
        expect(processRunner.invocations, hasLength(1));
        expect(
          processRunner.invocations.single.arguments.last,
          contains('Unregister-ScheduledTask'),
        );
      },
    );

    test('reports enabled after detecting a legacy run entry', () async {
      final processRunner = _FakeProcessRunner();
      final startupEntryService = _FakeLaunchAtStartupService(enabled: false);
      final service = DesktopLaunchAtStartupService(
        appName: 'Gorion',
        appPath: r'C:\Program Files\Gorion\gorion_clean.exe',
        args: const [gorionLaunchAtStartupArg],
        processRunner: processRunner.call,
        startupEntryService: startupEntryService,
      );

      processRunner.queue(1);
      processRunner.queue(0);

      final enabled = await service.isEnabled();

      expect(enabled, isTrue);
      expect(startupEntryService.setEnabledCalls, isEmpty);
      expect(processRunner.invocations, hasLength(2));
      expect(
        processRunner.invocations.first.arguments.last,
        contains('Get-ScheduledTask'),
      );
      expect(
        processRunner.invocations.last.arguments.last,
        contains(r'CurrentVersion\Run'),
      );
    });

    test('reports first priority when a scheduled task exists', () async {
      final processRunner = _FakeProcessRunner();
      final startupEntryService = _FakeLaunchAtStartupService(enabled: false);
      final service = DesktopLaunchAtStartupService(
        appName: 'Gorion',
        appPath: r'C:\Program Files\Gorion\gorion_clean.exe',
        processRunner: processRunner.call,
        startupEntryService: startupEntryService,
      );

      processRunner.queue(0);

      final priority = await service.getPriority();

      expect(priority, LaunchAtStartupPriority.first);
      expect(startupEntryService.setEnabledCalls, isEmpty);
      expect(processRunner.invocations, hasLength(1));
      expect(
        processRunner.invocations.single.arguments.last,
        contains('Get-ScheduledTask'),
      );
    });

    test(
      'enables the scheduled task and disables the startup entry in first mode',
      () async {
        final processRunner = _FakeProcessRunner();
        final startupEntryService = _FakeLaunchAtStartupService(enabled: true);
        final service = DesktopLaunchAtStartupService(
          appName: 'Gorion',
          appPath: r'C:\Program Files\Gorion\gorion_clean.exe',
          args: const [gorionLaunchAtStartupArg],
          processRunner: processRunner.call,
          startupEntryService: startupEntryService,
        );

        processRunner.queue(0);

        final enabled = await service.setEnabled(
          true,
          priority: LaunchAtStartupPriority.first,
        );

        expect(enabled, isTrue);
        expect(startupEntryService.setEnabledCalls, [
          (enabled: false, priority: LaunchAtStartupPriority.standard),
        ]);
        expect(processRunner.invocations, hasLength(1));
        expect(
          processRunner.invocations.single.arguments.last,
          contains('Register-ScheduledTask'),
        );
        expect(
          processRunner.invocations.single.arguments.last,
          contains('New-ScheduledTaskTrigger -AtLogOn'),
        );
      },
    );

    test(
      'disabling autostart removes both the startup entry and scheduled task',
      () async {
        final processRunner = _FakeProcessRunner();
        final startupEntryService = _FakeLaunchAtStartupService(
          enabled: true,
          priority: LaunchAtStartupPriority.first,
        );
        final service = DesktopLaunchAtStartupService(
          appName: 'Gorion',
          appPath: r'C:\Program Files\Gorion\gorion_clean.exe',
          processRunner: processRunner.call,
          startupEntryService: startupEntryService,
        );

        processRunner.queue(0);

        final disabled = await service.setEnabled(false);

        expect(disabled, isTrue);
        expect(startupEntryService.setEnabledCalls, [
          (enabled: false, priority: LaunchAtStartupPriority.standard),
        ]);
        expect(processRunner.invocations, hasLength(1));
        expect(
          processRunner.invocations.single.arguments.last,
          contains('Unregister-ScheduledTask'),
        );
      },
    );

    test('keeps the current mode when scheduled task cleanup fails', () async {
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
      expect(startupEntryService.setEnabledCalls, [
        (enabled: true, priority: LaunchAtStartupPriority.standard),
      ]);
      expect(processRunner.invocations, hasLength(1));
    });
  });
}

class _FakeLaunchAtStartupService implements LaunchAtStartupService {
  _FakeLaunchAtStartupService({
    required this.enabled,
    this.priority = LaunchAtStartupPriority.standard,
  });

  bool enabled;
  LaunchAtStartupPriority priority;
  final List<({bool enabled, LaunchAtStartupPriority priority})>
  setEnabledCalls = <({bool enabled, LaunchAtStartupPriority priority})>[];

  @override
  Future<bool> isEnabled() async {
    return enabled;
  }

  @override
  Future<LaunchAtStartupPriority> getPriority() async {
    return priority;
  }

  @override
  Future<bool> setEnabled(
    bool enabled, {
    LaunchAtStartupPriority priority = LaunchAtStartupPriority.standard,
  }) async {
    setEnabledCalls.add((enabled: enabled, priority: priority));
    this.enabled = enabled;
    if (enabled) {
      this.priority = priority;
    }
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
