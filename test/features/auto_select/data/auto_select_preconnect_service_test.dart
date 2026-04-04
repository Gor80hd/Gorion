import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gorion_clean/features/auto_select/data/auto_select_preconnect_service.dart';
import 'package:gorion_clean/features/auto_select/data/auto_select_settings_repository.dart';
import 'package:gorion_clean/features/profiles/model/profile_models.dart';

void main() {
  late Directory tempDir;
  late AutoSelectSettingsRepository settingsRepository;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('gorion-preconnect-auto-');
    settingsRepository = AutoSelectSettingsRepository(
      storageRootLoader: () async => tempDir,
    );
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'reuses a recent successful server before probing new candidates',
    () async {
      await settingsRepository.setRecentSuccessfulAutoConnect(
        profileId: 'profile-1',
        serverTag: 'server-b',
      );
      var probeCalls = 0;
      final service = AutoSelectPreconnectService(
        settingsRepository: settingsRepository,
        probeCandidate:
            ({
              required profileId,
              required templateConfig,
              required candidate,
              required settings,
            }) async {
              probeCalls += 1;
              return AutoSelectPreconnectProbeResult(
                serverTag: candidate.tag,
                urlTestDelay: 42,
                domainProbeOk: true,
                ipProbeOk: true,
                throughputBytesPerSecond: 64 * 1024,
              );
            },
      );

      final outcome = await service.prepare(
        profile: _buildProfile(),
        templateConfig: _templateConfig(['server-a', 'server-b', 'server-c']),
      );

      expect(outcome, isNotNull);
      expect(outcome!.selectedServerTag, 'server-b');
      expect(outcome.reusedRecentSuccessfulSelection, isTrue);
      expect(outcome.requiresImmediatePostConnectCheck, isFalse);
      expect(outcome.probes, isEmpty);
      expect(probeCalls, 0);
    },
  );

  test(
    'applies exclusions and prefers throughput when delays are equivalent',
    () async {
      await settingsRepository.updateExcludedServer(
        profileId: 'profile-1',
        serverTag: 'server-c',
        excluded: true,
      );
      final probedTags = <String>[];
      final service = AutoSelectPreconnectService(
        settingsRepository: settingsRepository,
        probeCandidate:
            ({
              required profileId,
              required templateConfig,
              required candidate,
              required settings,
            }) async {
              probedTags.add(candidate.tag);
              return switch (candidate.tag) {
                'server-a' => const AutoSelectPreconnectProbeResult(
                  serverTag: 'server-a',
                  urlTestDelay: 40,
                  domainProbeOk: true,
                  ipProbeOk: true,
                  throughputBytesPerSecond: 28 * 1024,
                ),
                'server-b' => const AutoSelectPreconnectProbeResult(
                  serverTag: 'server-b',
                  urlTestDelay: 55,
                  domainProbeOk: true,
                  ipProbeOk: true,
                  throughputBytesPerSecond: 96 * 1024,
                ),
                _ => const AutoSelectPreconnectProbeResult(
                  serverTag: 'server-c',
                  urlTestDelay: 20,
                  domainProbeOk: true,
                  ipProbeOk: true,
                  throughputBytesPerSecond: 128 * 1024,
                ),
              };
            },
      );

      final outcome = await service.prepare(
        profile: _buildProfile(),
        templateConfig: _templateConfig(['server-a', 'server-b', 'server-c']),
      );

      expect(outcome, isNotNull);
      expect(outcome!.selectedServerTag, 'server-b');
      expect(outcome.requiresImmediatePostConnectCheck, isFalse);
      expect(outcome.probes.first.serverTag, 'server-b');
      expect(probedTags, ['server-a', 'server-b']);
    },
  );

  test(
    'accepts a candidate by URLTest plus throughput even when domain and IP probes fail',
    () async {
      final service = AutoSelectPreconnectService(
        settingsRepository: settingsRepository,
        probeCandidate:
            ({
              required profileId,
              required templateConfig,
              required candidate,
              required settings,
            }) async {
              return switch (candidate.tag) {
                'server-a' => const AutoSelectPreconnectProbeResult(
                  serverTag: 'server-a',
                  urlTestDelay: 80,
                  domainProbeOk: false,
                  ipProbeOk: false,
                  throughputBytesPerSecond: 96 * 1024,
                ),
                _ => const AutoSelectPreconnectProbeResult(
                  serverTag: 'server-b',
                  urlTestDelay: null,
                  domainProbeOk: true,
                  ipProbeOk: false,
                  throughputBytesPerSecond: 0,
                ),
              };
            },
      );

      final outcome = await service.prepare(
        profile: _buildProfile(serverTags: ['server-a', 'server-b']),
        templateConfig: _templateConfig(['server-a', 'server-b']),
      );

      expect(outcome, isNotNull);
      expect(outcome!.selectedServerTag, 'server-a');
      expect(outcome.requiresImmediatePostConnectCheck, isFalse);
    },
  );

  test('prefers higher throughput across a moderate delay gap', () async {
    final service = AutoSelectPreconnectService(
      settingsRepository: settingsRepository,
      probeCandidate:
          ({
            required profileId,
            required templateConfig,
            required candidate,
            required settings,
          }) async {
            return switch (candidate.tag) {
              'server-a' => const AutoSelectPreconnectProbeResult(
                serverTag: 'server-a',
                urlTestDelay: 25,
                domainProbeOk: true,
                ipProbeOk: true,
                throughputBytesPerSecond: 40 * 1024,
              ),
              _ => const AutoSelectPreconnectProbeResult(
                serverTag: 'server-b',
                urlTestDelay: 95,
                domainProbeOk: true,
                ipProbeOk: true,
                throughputBytesPerSecond: 120 * 1024,
              ),
            };
          },
    );

    final outcome = await service.prepare(
      profile: _buildProfile(serverTags: ['server-a', 'server-b']),
      templateConfig: _templateConfig(['server-a', 'server-b']),
    );

    expect(outcome, isNotNull);
    expect(outcome!.selectedServerTag, 'server-b');
  });

  test(
    'prioritizes the recent auto-selected server before other candidates',
    () async {
      await settingsRepository.setRecentAutoSelectedServer(
        profileId: 'profile-1',
        serverTag: 'server-c',
      );
      final probedTags = <String>[];
      final service = AutoSelectPreconnectService(
        settingsRepository: settingsRepository,
        probeCandidate:
            ({
              required profileId,
              required templateConfig,
              required candidate,
              required settings,
            }) async {
              probedTags.add(candidate.tag);
              return AutoSelectPreconnectProbeResult(
                serverTag: candidate.tag,
                urlTestDelay: null,
                domainProbeOk: false,
                ipProbeOk: false,
                throughputBytesPerSecond: 0,
              );
            },
      );

      await service.prepare(
        profile: _buildProfile(),
        templateConfig: _templateConfig(['server-a', 'server-b', 'server-c']),
      );

      expect(probedTags.first, 'server-c');
    },
  );

  test('caps the preconnect probe plan at sixteen candidates', () async {
    final probedTags = <String>[];
    final tags = [for (var index = 0; index < 20; index += 1) 'server-$index'];
    final service = AutoSelectPreconnectService(
      settingsRepository: settingsRepository,
      probeCandidate:
          ({
            required profileId,
            required templateConfig,
            required candidate,
            required settings,
          }) async {
            probedTags.add(candidate.tag);
            return AutoSelectPreconnectProbeResult(
              serverTag: candidate.tag,
              urlTestDelay: 400,
              domainProbeOk: false,
              ipProbeOk: false,
              throughputBytesPerSecond: 0,
            );
          },
    );

    final outcome = await service.prepare(
      profile: _buildProfile(serverTags: tags),
      templateConfig: _templateConfig(tags),
    );

    expect(outcome, isNull);
    expect(probedTags, hasLength(16));
  });

  test('reports preconnect progress while probing candidates', () async {
    final progressMessages = <String>[];
    final progressFrames = <String>[];
    final service = AutoSelectPreconnectService(
      settingsRepository: settingsRepository,
      probeCandidate:
          ({
            required profileId,
            required templateConfig,
            required candidate,
            required settings,
          }) async {
            return switch (candidate.tag) {
              'server-a' => const AutoSelectPreconnectProbeResult(
                serverTag: 'server-a',
                urlTestDelay: 35,
                domainProbeOk: true,
                ipProbeOk: true,
                throughputBytesPerSecond: 96 * 1024,
              ),
              _ => const AutoSelectPreconnectProbeResult(
                serverTag: 'server-b',
                urlTestDelay: 180,
                domainProbeOk: true,
                ipProbeOk: true,
                throughputBytesPerSecond: 48 * 1024,
              ),
            };
          },
    );

    final outcome = await service.prepare(
      profile: _buildProfile(serverTags: ['server-a', 'server-b']),
      templateConfig: _templateConfig(['server-a', 'server-b']),
      onProgress: (event) {
        progressMessages.add(event.message);
        progressFrames.add('${event.completedSteps}/${event.totalSteps}');
      },
    );

    expect(outcome, isNotNull);
    expect(outcome!.selectedServerTag, 'server-a');
    expect(progressMessages.first, contains('Preparing detached probes'));
    expect(
      progressMessages.any((message) => message.contains('Probing server-a')),
      isTrue,
    );
    expect(progressMessages.last, contains('Auto-selector chose server-a'));
    expect(progressFrames.last, '4/4');
  });

  test('builds the preconnect summary from the selected server tag', () async {
    final service = AutoSelectPreconnectService(
      settingsRepository: settingsRepository,
      probeCandidate:
          ({
            required profileId,
            required templateConfig,
            required candidate,
            required settings,
          }) async {
            return switch (candidate.tag) {
              'server-a' => const AutoSelectPreconnectProbeResult(
                serverTag: 'server-a',
                urlTestDelay: 35,
                domainProbeOk: true,
                ipProbeOk: true,
                throughputBytesPerSecond: 96 * 1024,
              ),
              _ => const AutoSelectPreconnectProbeResult(
                serverTag: 'server-b',
                urlTestDelay: 180,
                domainProbeOk: true,
                ipProbeOk: true,
                throughputBytesPerSecond: 48 * 1024,
              ),
            };
          },
    );

    final outcome = await service.prepare(
      profile: _buildProfile(serverTags: ['server-a', 'server-b']),
      templateConfig: _templateConfig(['server-a', 'server-b']),
    );

    expect(outcome, isNotNull);
    expect(
      outcome!.summary,
      'Auto-selector chose server-a before connect (35 ms, 96 KB/s).',
    );
    expect(
      outcome.summary,
      isNot(contains("Instance of 'AutoSelectPreconnectProbeResult'")),
    );
  });

  test(
    'times out a stuck preconnect probe instead of hanging the batch',
    () async {
      final service = AutoSelectPreconnectService(
        settingsRepository: settingsRepository,
        preconnectProbeTimeout: const Duration(milliseconds: 20),
        probeCandidate:
            ({
              required profileId,
              required templateConfig,
              required candidate,
              required settings,
            }) => Completer<AutoSelectPreconnectProbeResult>().future,
      );

      final stopwatch = Stopwatch()..start();
      final outcome = await service.prepare(
        profile: _buildProfile(serverTags: ['server-a']),
        templateConfig: _templateConfig(['server-a']),
      );
      stopwatch.stop();

      expect(outcome, isNull);
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
    },
  );

  test(
    'falls back to the saved server when no candidate passes preconnect',
    () async {
      final progressMessages = <String>[];
      final service = AutoSelectPreconnectService(
        settingsRepository: settingsRepository,
        probeCandidate:
            ({
              required profileId,
              required templateConfig,
              required candidate,
              required settings,
            }) async {
              return const AutoSelectPreconnectProbeResult(
                serverTag: 'server-a',
                urlTestDelay: null,
                domainProbeOk: false,
                ipProbeOk: false,
                throughputBytesPerSecond: 0,
              );
            },
      );

      final outcome = await service.prepare(
        profile: _buildProfile(serverTags: ['server-a']),
        templateConfig: _templateConfig(['server-a']),
        onProgress: (event) {
          progressMessages.add(event.message);
        },
      );

      expect(outcome, isNull);
      expect(
        progressMessages.last,
        contains('Continuing with the saved server and retrying after connect'),
      );
    },
  );

  test(
    'uses a best-effort candidate instead of returning null when partial signal exists',
    () async {
      final service = AutoSelectPreconnectService(
        settingsRepository: settingsRepository,
        probeCandidate:
            ({
              required profileId,
              required templateConfig,
              required candidate,
              required settings,
            }) async {
              return switch (candidate.tag) {
                'server-a' => const AutoSelectPreconnectProbeResult(
                  serverTag: 'server-a',
                  urlTestDelay: null,
                  domainProbeOk: false,
                  ipProbeOk: false,
                  throughputBytesPerSecond: 0,
                ),
                _ => const AutoSelectPreconnectProbeResult(
                  serverTag: 'server-b',
                  urlTestDelay: null,
                  domainProbeOk: true,
                  ipProbeOk: false,
                  throughputBytesPerSecond: 0,
                ),
              };
            },
      );

      final outcome = await service.prepare(
        profile: _buildProfile(serverTags: ['server-a', 'server-b']),
        templateConfig: _templateConfig(['server-a', 'server-b']),
      );

      expect(outcome, isNotNull);
      expect(outcome!.selectedServerTag, 'server-b');
      expect(outcome.requiresImmediatePostConnectCheck, isTrue);
      expect(outcome.summary, contains('best-effort candidate server-b'));
    },
  );
}

ProxyProfile _buildProfile({List<String>? serverTags}) {
  final tags = serverTags ?? ['server-a', 'server-b', 'server-c'];
  return ProxyProfile(
    id: 'profile-1',
    name: 'Example',
    subscriptionUrl: 'https://example.com/subscription',
    templateFileName: 'profile.json',
    createdAt: DateTime(2026, 4, 3),
    updatedAt: DateTime(2026, 4, 3),
    servers: [
      for (final tag in tags)
        ServerEntry(
          tag: tag,
          displayName: tag,
          type: 'vless',
          host: '$tag.example.com',
          port: 443,
        ),
    ],
    lastSelectedServerTag: autoSelectServerTag,
    lastAutoSelectedServerTag: tags.first,
  );
}

String _templateConfig(List<String> serverTags) {
  return jsonEncode({
    'outbounds': [
      for (final tag in serverTags)
        {
          'type': 'vless',
          'tag': tag,
          'server': '$tag.example.com',
          'server_port': 443,
        },
    ],
  });
}
