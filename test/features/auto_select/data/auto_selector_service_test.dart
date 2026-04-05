import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gorion_clean/features/auto_select/data/auto_selector_service.dart';
import 'package:gorion_clean/features/profiles/model/profile_models.dart';
import 'package:gorion_clean/features/runtime/model/runtime_mode.dart';
import 'package:gorion_clean/features/runtime/model/runtime_models.dart';

const _domainProbeUrl = 'https://www.gstatic.com/generate_204';
const _session = RuntimeSession(
  profileId: 'profile-1',
  mode: RuntimeMode.mixed,
  binaryPath: 'sing-box.exe',
  configPath: 'config.json',
  controllerPort: 9090,
  mixedPort: 2080,
  secret: 'secret',
  manualSelectorTag: 'gorion-manual',
  autoGroupTag: 'gorion-auto',
);

const _servers = [
  ServerEntry(
    tag: 'server-a',
    displayName: 'Server A',
    type: 'vless',
    host: 'a.example.com',
    port: 443,
  ),
  ServerEntry(
    tag: 'server-b',
    displayName: 'Server B',
    type: 'vless',
    host: 'b.example.com',
    port: 443,
  ),
  ServerEntry(
    tag: 'server-c',
    displayName: 'Server C',
    type: 'vless',
    host: 'c.example.com',
    port: 443,
  ),
];

List<ServerEntry> _buildServers(List<String> tags) {
  return [
    for (final tag in tags)
      ServerEntry(
        tag: tag,
        displayName: tag,
        type: 'vless',
        host: '$tag.example.com',
        port: 443,
      ),
  ];
}

void main() {
  group('AutoSelectorService', () {
    test(
      'manual selection prefers healthier candidates over faster partial ones',
      () async {
        final harness = _AutoSelectHarness(
          initialSelectedTag: 'server-c',
          delays: const {'server-a': 40, 'server-b': 70, 'server-c': 160},
          domainResults: const {
            'server-a': true,
            'server-b': true,
            'server-c': true,
          },
          ipResults: const {
            'server-a': false,
            'server-b': true,
            'server-c': true,
          },
        );
        final service = harness.build();

        final outcome = await service.selectBestServer(
          session: _session,
          servers: _servers,
          domainProbeUrl: _domainProbeUrl,
        );

        expect(outcome.selectedServerTag, 'server-b');
        expect(outcome.previousServerTag, 'server-c');
        expect(outcome.didSwitch, isTrue);
        expect(outcome.probes.first.serverTag, 'server-b');
        expect(harness.selectedCalls, ['server-b']);
        expect(harness.detachedProbeTags, ['server-a', 'server-b']);
      },
    );

    test(
      'automatic maintenance keeps the current server for marginal latency gains',
      () async {
        final harness = _AutoSelectHarness(
          initialSelectedTag: 'server-a',
          delays: const {'server-a': 140, 'server-b': 100, 'server-c': 220},
          domainResults: const {
            'server-a': true,
            'server-b': true,
            'server-c': false,
          },
          ipResults: const {
            'server-a': true,
            'server-b': true,
            'server-c': false,
          },
        );
        final service = harness.build();

        final outcome = await service.maintainBestServer(
          session: _session,
          servers: _servers,
          domainProbeUrl: _domainProbeUrl,
        );

        expect(outcome.selectedServerTag, 'server-a');
        expect(outcome.didSwitch, isFalse);
        expect(outcome.summary, contains('stayed selected'));
        expect(harness.selectedCalls, isEmpty);
        expect(harness.detachedProbeTags, ['server-b', 'server-c']);
      },
    );

    test(
      'automatic maintenance recovers from an unhealthy current server',
      () async {
        final harness = _AutoSelectHarness(
          initialSelectedTag: 'server-a',
          delays: const {'server-a': 40, 'server-b': 90, 'server-c': 120},
          domainResults: const {
            'server-a': false,
            'server-b': true,
            'server-c': true,
          },
          ipResults: const {
            'server-a': false,
            'server-b': false,
            'server-c': true,
          },
        );
        final service = harness.build();

        final outcome = await service.maintainBestServer(
          session: _session,
          servers: _servers,
          domainProbeUrl: _domainProbeUrl,
        );

        expect(outcome.selectedServerTag, 'server-b');
        expect(outcome.didSwitch, isTrue);
        expect(
          outcome.summary,
          contains('recovered from server-a to server-b'),
        );
        expect(harness.selectedCalls, ['server-b']);
        expect(harness.detachedProbeTags, ['server-b']);
      },
    );

    test(
      'automatic maintenance keeps probing replacement servers when URLTest refresh times out',
      () async {
        final harness = _AutoSelectHarness(
          initialSelectedTag: 'server-a',
          delays: const {'server-a': 40, 'server-b': 90, 'server-c': 120},
          domainResults: const {
            'server-a': false,
            'server-b': true,
            'server-c': false,
          },
          ipResults: const {
            'server-a': false,
            'server-b': true,
            'server-c': false,
          },
          measureGroupDelayError: TimeoutException('receive timeout'),
        );
        final service = harness.build();

        final outcome = await service.maintainBestServer(
          session: _session,
          servers: _servers,
          domainProbeUrl: _domainProbeUrl,
        );

        expect(outcome.selectedServerTag, 'server-b');
        expect(outcome.didSwitch, isTrue);
        expect(harness.selectedCalls, ['server-b']);
        expect(harness.detachedProbeTags, ['server-b']);
      },
    );

    test(
      'cooldown keeps the current server unless the connect pass bypasses it',
      () async {
        final harness = _AutoSelectHarness(
          initialSelectedTag: 'server-a',
          delays: const {'server-a': 180, 'server-b': 40, 'server-c': 220},
          domainResults: const {
            'server-a': true,
            'server-b': true,
            'server-c': false,
          },
          ipResults: const {
            'server-a': true,
            'server-b': true,
            'server-c': false,
          },
        );
        final service = harness.build();
        service.recordExternalSelection(profileId: _session.profileId);

        final cooled = await service.maintainBestServer(
          session: _session,
          servers: _servers,
          domainProbeUrl: _domainProbeUrl,
        );
        final forced = await service.maintainBestServer(
          session: _session,
          servers: _servers,
          domainProbeUrl: _domainProbeUrl,
          allowSwitchDuringCooldown: true,
        );

        expect(cooled.selectedServerTag, 'server-a');
        expect(cooled.didSwitch, isFalse);
        expect(forced.selectedServerTag, 'server-b');
        expect(forced.didSwitch, isTrue);
        expect(harness.selectedCalls, ['server-b']);
        expect(harness.detachedProbeTags, ['server-b', 'server-c']);
      },
    );

    test('manual selection emits progress updates', () async {
      final harness = _AutoSelectHarness(
        initialSelectedTag: 'server-c',
        delays: const {'server-a': 40, 'server-b': 70, 'server-c': 160},
        domainResults: const {
          'server-a': true,
          'server-b': true,
          'server-c': true,
        },
        ipResults: const {
          'server-a': false,
          'server-b': true,
          'server-c': true,
        },
      );
      final service = harness.build();
      final messages = <String>[];
      final progressFrames = <String>[];

      final outcome = await service.selectBestServer(
        session: _session,
        servers: _servers,
        domainProbeUrl: _domainProbeUrl,
        onProgress: (event) {
          messages.add(event.message);
          progressFrames.add('${event.completedSteps}/${event.totalSteps}');
        },
      );

      expect(outcome.selectedServerTag, 'server-b');
      expect(messages.first, contains('Refreshing URLTest delays'));
      expect(
        messages.any(
          (message) => message.contains('Probing candidate server-a'),
        ),
        isTrue,
      );
      expect(messages.last, contains('Auto-selector chose server-b'));
      expect(progressFrames.last, '5/5');
    });

    test(
      'manual selection still probes candidates when URLTest refresh times out',
      () async {
        final harness = _AutoSelectHarness(
          initialSelectedTag: 'server-c',
          delays: const {'server-a': 40, 'server-b': 70, 'server-c': 160},
          domainResults: const {
            'server-a': false,
            'server-b': true,
            'server-c': false,
          },
          ipResults: const {
            'server-a': false,
            'server-b': true,
            'server-c': false,
          },
          measureGroupDelayError: TimeoutException('receive timeout'),
        );
        final service = harness.build();

        final outcome = await service.selectBestServer(
          session: _session,
          servers: _servers,
          domainProbeUrl: _domainProbeUrl,
        );

        expect(outcome.selectedServerTag, 'server-b');
        expect(outcome.didSwitch, isTrue);
        expect(harness.selectedCalls, ['server-b']);
        expect(harness.detachedProbeTags, ['server-a', 'server-b', 'server-c']);
      },
    );

    test(
      'manual selection prefers real throughput over probe-only health during a moderate latency gap',
      () async {
        final harness = _AutoSelectHarness(
          initialSelectedTag: 'server-c',
          delays: const {'server-a': 30, 'server-b': 85, 'server-c': 160},
          domainResults: const {
            'server-a': true,
            'server-b': false,
            'server-c': false,
          },
          ipResults: const {
            'server-a': true,
            'server-b': false,
            'server-c': false,
          },
          throughputResults: const {
            'server-a': 0,
            'server-b': 96 * 1024,
            'server-c': 0,
          },
        );
        final service = harness.build();

        final outcome = await service.selectBestServer(
          session: _session,
          servers: _servers,
          domainProbeUrl: _domainProbeUrl,
        );

        expect(outcome.selectedServerTag, 'server-b');
        expect(outcome.probes.first.serverTag, 'server-b');
      },
    );

    test(
      'automatic maintenance skips live-proxy re-probe for a server that passed recently',
      () async {
        // server-a is healthy on live proxy; server-b is faster but within the
        // betterDelayThresholdMs (75 ms) window so no switch occurs.  This lets
        // the same server stay selected across two passes.
        final harness = _AutoSelectHarness(
          initialSelectedTag: 'server-a',
          delays: const {'server-a': 100, 'server-b': 70, 'server-c': 220},
          domainResults: const {
            'server-a': true,
            'server-b': true,
            'server-c': false,
          },
          ipResults: const {
            'server-a': true,
            'server-b': true,
            'server-c': false,
          },
        );
        final service = harness.build();

        // First pass — live proxy is probed and success cache is populated.
        await service.maintainBestServer(
          session: _session,
          servers: _servers,
          domainProbeUrl: _domainProbeUrl,
        );
        final liveProbeCountAfterFirst = harness.liveProbeUrls.length;
        expect(liveProbeCountAfterFirst, greaterThan(0));

        // Advance only 30 seconds — well within the shortened success cache TTL.
        harness.now = harness.now.add(const Duration(seconds: 30));

        // Second pass — current server should reuse the cached health result
        // and must NOT issue any new live proxy probes.
        await service.maintainBestServer(
          session: _session,
          servers: _servers,
          domainProbeUrl: _domainProbeUrl,
        );

        expect(
          harness.liveProbeUrls.length,
          liveProbeCountAfterFirst,
          reason: 'no additional live-proxy probes expected within cache TTL',
        );
      },
    );

    test(
      'automatic maintenance re-probes the current server after the live-pass cache expires',
      () async {
        final harness = _AutoSelectHarness(
          initialSelectedTag: 'server-a',
          delays: const {'server-a': 100, 'server-b': 70, 'server-c': 220},
          domainResults: const {
            'server-a': true,
            'server-b': true,
            'server-c': false,
          },
          ipResults: const {
            'server-a': true,
            'server-b': true,
            'server-c': false,
          },
        );
        final service = harness.build();

        await service.maintainBestServer(
          session: _session,
          servers: _servers,
          domainProbeUrl: _domainProbeUrl,
        );
        final liveProbeCountAfterFirst = harness.liveProbeUrls.length;

        harness.now = harness.now.add(const Duration(seconds: 120));

        await service.maintainBestServer(
          session: _session,
          servers: _servers,
          domainProbeUrl: _domainProbeUrl,
        );

        expect(
          harness.liveProbeUrls.length,
          greaterThan(liveProbeCountAfterFirst),
          reason: 'the current server should be probed again once the cache TTL elapses',
        );
      },
    );

    test('verify current server can skip the IP probe when checkIp is disabled', () async {
      final harness = _AutoSelectHarness(
        initialSelectedTag: 'server-a',
        delays: const {'server-a': 48},
        domainResults: const {'server-a': true},
        ipResults: const {'server-a': false},
      );
      final service = harness.build();

      final probe = await service.verifyCurrentServer(
        session: _session,
        server: _servers.first,
        domainProbeUrl: _domainProbeUrl,
        checkIp: false,
      );

      expect(probe.domainProbeOk, isTrue);
      expect(probe.ipProbeOk, isTrue);
      expect(probe.fullyHealthy, isTrue);
      expect(
        harness.liveProbeUrls.where((url) => url.contains('1.1.1.1')),
        isEmpty,
      );
    });

    test(
      'automatic maintenance probes cooling-down servers as last-resort recovery',
      () async {
        // server-a is current (dead), server-b has already failed and is on
        // cooldown from a previous pass.  server-c is also dead.
        // The fix must still try server-b as a last-resort candidate even
        // though its failure cooldown is still active.
        final harness = _AutoSelectHarness(
          initialSelectedTag: 'server-a',
          delays: const {'server-a': 0, 'server-b': 0, 'server-c': 0},
          domainResults: const {
            'server-a': false,
            'server-b': false,
            'server-c': false,
          },
          ipResults: const {
            'server-a': false,
            'server-b': false,
            'server-c': false,
          },
        );
        final service = harness.build();

        // First pass: all fail, putting server-b and server-c on cooldown.
        await service.maintainBestServer(
          session: _session,
          servers: _servers,
          domainProbeUrl: _domainProbeUrl,
        );
        harness.detachedProbeTags.clear();

        // Advance only 10 seconds — cooldown (45 s) is still active.
        harness.now = harness.now.add(const Duration(seconds: 10));

        // Second pass: server-b and server-c are cooling down but should still
        // appear as last-resort recovery candidates for the dead current server.
        await service.maintainBestServer(
          session: _session,
          servers: _servers,
          domainProbeUrl: _domainProbeUrl,
        );

        expect(
          harness.detachedProbeTags,
          containsAll(['server-b', 'server-c']),
          reason:
              'cooling-down servers must be tried as last-resort recovery when all are down',
        );
      },
    );

    test(
      'contender probing rotates through all candidate servers across cycles',
      () async {
        // 8 servers: server-a (current, healthy), server-b through server-h
        // (all reachable but not better than current so no switch occurs and
        // no cooldowns are set).  The new plan probes up to 10 contenders per
        // pass, so with only 7 candidates the first cycle covers the whole
        // pool and the second cycle restarts from a rotated index.
        const manyServers = [
          ServerEntry(
            tag: 'server-a',
            displayName: 'A',
            type: 'vless',
            host: 'a.example.com',
            port: 443,
          ),
          ServerEntry(
            tag: 'server-b',
            displayName: 'B',
            type: 'vless',
            host: 'b.example.com',
            port: 443,
          ),
          ServerEntry(
            tag: 'server-c',
            displayName: 'C',
            type: 'vless',
            host: 'c.example.com',
            port: 443,
          ),
          ServerEntry(
            tag: 'server-d',
            displayName: 'D',
            type: 'vless',
            host: 'd.example.com',
            port: 443,
          ),
          ServerEntry(
            tag: 'server-e',
            displayName: 'E',
            type: 'vless',
            host: 'e.example.com',
            port: 443,
          ),
          ServerEntry(
            tag: 'server-f',
            displayName: 'F',
            type: 'vless',
            host: 'f.example.com',
            port: 443,
          ),
          ServerEntry(
            tag: 'server-g',
            displayName: 'G',
            type: 'vless',
            host: 'g.example.com',
            port: 443,
          ),
          ServerEntry(
            tag: 'server-h',
            displayName: 'H',
            type: 'vless',
            host: 'h.example.com',
            port: 443,
          ),
        ];

        // All servers: domain OK, IP OK, throughput explicitly 0 so
        // usableThroughput = 0 and healthScore = 2 (domain+IP only).
        // The synthesised current-server probe in cycle 2 has
        // throughputBytesPerSecond = minimumUsableThroughput (healthScore 5),
        // which is higher than the contenders (healthScore 2) → no switch →
        // no cooldowns are set and the pool stays full.
        final allTags = manyServers.map((s) => s.tag).toList();
        final harness = _AutoSelectHarness(
          initialSelectedTag: 'server-a',
          delays: const {},
          domainResults: {for (final t in allTags) t: true},
          ipResults: {for (final t in allTags) t: true},
          throughputResults: {for (final t in allTags) t: 0},
          measureGroupDelayError: TimeoutException('timeout'),
        );
        final service = harness.build();

        // Cycle 1: all 7 contenders are probed in their deterministic order.
        await service.maintainBestServer(
          session: _session,
          servers: manyServers,
          domainProbeUrl: _domainProbeUrl,
        );
        final firstBatch = List<String>.from(harness.detachedProbeTags);
        harness.detachedProbeTags.clear();

        // Cycle 2: the same 7 contenders are revisited but from a rotated
        // starting point, so the first probe changes.
        await service.maintainBestServer(
          session: _session,
          servers: manyServers,
          domainProbeUrl: _domainProbeUrl,
        );
        final secondBatch = List<String>.from(harness.detachedProbeTags);

        // Rotation must start from different points.
        expect(firstBatch.first, 'server-b');
        expect(secondBatch.first, 'server-e');

        // Together, every non-current server is covered.
        expect(
          {...firstBatch, ...secondBatch},
          containsAll([
            'server-b',
            'server-c',
            'server-d',
            'server-e',
            'server-f',
            'server-g',
            'server-h',
          ]),
        );
      },
    );

    test(
      'manual selection reaches a later segmented fallback candidate when URLTest is unavailable',
      () async {
        final tags = [
          for (var index = 0; index < 20; index += 1)
            'server-${index.toString().padLeft(2, '0')}',
        ];
        final servers = _buildServers(tags);
        final harness = _AutoSelectHarness(
          initialSelectedTag: 'server-00',
          delays: const {},
          domainResults: {for (final tag in tags) tag: tag == 'server-15'},
          ipResults: {for (final tag in tags) tag: tag == 'server-15'},
          measureGroupDelayError: TimeoutException('timeout'),
          maxContenderPool: 10,
        );
        final service = harness.build();

        final outcome = await service.selectBestServer(
          session: _session,
          servers: servers,
          domainProbeUrl: _domainProbeUrl,
        );

        expect(outcome.selectedServerTag, 'server-15');
        expect(harness.detachedProbeTags.take(4).toList(growable: false), [
          'server-00',
          'server-05',
          'server-10',
          'server-15',
        ]);
      },
    );

    test(
      'maintenance probes six likely-live contenders plus four segmented fallbacks',
      () async {
        final tags = [
          for (var index = 0; index <= 20; index += 1)
            'server-${index.toString().padLeft(2, '0')}',
        ];
        final servers = _buildServers(tags);
        final delays = <String, int>{
          'server-00': 5,
          for (var index = 1; index <= 20; index += 1)
            'server-${index.toString().padLeft(2, '0')}': index * 10,
        };
        final harness = _AutoSelectHarness(
          initialSelectedTag: 'server-00',
          delays: delays,
          domainResults: {for (final tag in tags) tag: true},
          ipResults: {for (final tag in tags) tag: true},
          throughputResults: {for (final tag in tags) tag: 0},
          maxContenderPool: 10,
        );
        final service = harness.build();

        await service.maintainBestServer(
          session: _session,
          servers: servers,
          domainProbeUrl: _domainProbeUrl,
        );

        expect(harness.detachedProbeTags, [
          'server-01',
          'server-02',
          'server-03',
          'server-04',
          'server-05',
          'server-06',
          'server-11',
          'server-16',
          'server-07',
          'server-12',
        ]);
      },
    );

    test(
      'contender pool is capped at maxContenderPool even with many servers',
      () async {
        // 10 servers, server-a is current.  Set maxContenderPool=3 so only
        // three contenders enter the diversified fallback pool.  The sampled
        // pool must remain capped, and all later servers outside that sampled
        // pool must never appear in any probe batch.
        const bigList = [
          ServerEntry(
            tag: 'server-a',
            displayName: 'A',
            type: 'vless',
            host: 'a.example.com',
            port: 443,
          ),
          ServerEntry(
            tag: 'server-b',
            displayName: 'B',
            type: 'vless',
            host: 'b.example.com',
            port: 443,
          ),
          ServerEntry(
            tag: 'server-c',
            displayName: 'C',
            type: 'vless',
            host: 'c.example.com',
            port: 443,
          ),
          ServerEntry(
            tag: 'server-d',
            displayName: 'D',
            type: 'vless',
            host: 'd.example.com',
            port: 443,
          ),
          ServerEntry(
            tag: 'server-e',
            displayName: 'E',
            type: 'vless',
            host: 'e.example.com',
            port: 443,
          ),
          ServerEntry(
            tag: 'server-f',
            displayName: 'F',
            type: 'vless',
            host: 'f.example.com',
            port: 443,
          ),
          ServerEntry(
            tag: 'server-g',
            displayName: 'G',
            type: 'vless',
            host: 'g.example.com',
            port: 443,
          ),
          ServerEntry(
            tag: 'server-h',
            displayName: 'H',
            type: 'vless',
            host: 'h.example.com',
            port: 443,
          ),
          ServerEntry(
            tag: 'server-i',
            displayName: 'I',
            type: 'vless',
            host: 'i.example.com',
            port: 443,
          ),
          ServerEntry(
            tag: 'server-j',
            displayName: 'J',
            type: 'vless',
            host: 'j.example.com',
            port: 443,
          ),
        ];
        final allTags = bigList.map((s) => s.tag).toList();
        final harness = _AutoSelectHarness(
          initialSelectedTag: 'server-a',
          delays: const {},
          domainResults: {for (final t in allTags) t: true},
          ipResults: {for (final t in allTags) t: true},
          throughputResults: {for (final t in allTags) t: 0},
          measureGroupDelayError: TimeoutException('timeout'),
          maxContenderPool: 3,
        );
        final service = harness.build();

        // Run enough cycles to exercise the rotation.
        for (var i = 0; i < 4; i += 1) {
          await service.maintainBestServer(
            session: _session,
            servers: bigList,
            domainProbeUrl: _domainProbeUrl,
          );
        }

        final probed = harness.detachedProbeTags.toSet();
        expect(
          probed,
          containsAll(['server-b', 'server-e', 'server-g']),
          reason: 'servers inside the pool cap must be probed',
        );
        expect(
          probed.intersection({
            'server-c',
            'server-d',
            'server-f',
            'server-h',
            'server-i',
            'server-j',
          }),
          isEmpty,
          reason: 'servers outside the pool cap must never be probed',
        );
      },
    );

    test(
      'deep refresh resets failed-probe cooldowns and rotation index after the interval',
      () async {
        // server-a is current and healthy.  server-b and server-c are dead
        // and on cooldown after the first maintenance pass.
        // We use a short deepRefreshInterval (1 minute) so we can advance
        // the clock past it within the test.
        final harness = _AutoSelectHarness(
          initialSelectedTag: 'server-a',
          delays: const {},
          domainResults: const {
            'server-a': true,
            'server-b': false,
            'server-c': false,
          },
          ipResults: const {
            'server-a': true,
            'server-b': false,
            'server-c': false,
          },
          measureGroupDelayError: TimeoutException('timeout'),
          deepRefreshInterval: const Duration(minutes: 1),
        );
        final service = harness.build();

        // Cycle 1 — server-b and server-c fail, entering 45s cooldown.
        await service.maintainBestServer(
          session: _session,
          servers: _servers,
          domainProbeUrl: _domainProbeUrl,
        );
        harness.detachedProbeTags.clear();

        // Advance 20 seconds — still within both 45s cooldown and 1min
        // deep-refresh interval.  Cooldowns are active → no probes expected.
        harness.now = harness.now.add(const Duration(seconds: 20));
        await service.maintainBestServer(
          session: _session,
          servers: _servers,
          domainProbeUrl: _domainProbeUrl,
        );
        expect(
          harness.detachedProbeTags,
          isEmpty,
          reason:
              'servers on cooldown should be skipped when interval has not elapsed',
        );
        harness.detachedProbeTags.clear();

        // Advance past the 1-minute deep-refresh interval.
        harness.now = harness.now.add(const Duration(minutes: 1));
        await service.maintainBestServer(
          session: _session,
          servers: _servers,
          domainProbeUrl: _domainProbeUrl,
        );

        // After the deep refresh the cooldowns are gone → server-b & server-c
        // must be probed again even though they just failed 80 seconds ago.
        expect(
          harness.detachedProbeTags,
          containsAll(['server-b', 'server-c']),
          reason:
              'deep refresh must clear cooldowns so previously-failed servers are retried',
        );
      },
    );
  });
}

class _AutoSelectHarness {
  _AutoSelectHarness({
    required this.initialSelectedTag,
    required this.delays,
    required this.domainResults,
    required this.ipResults,
    this.throughputResults = const {},
    this.measureGroupDelayError,
    this.maxContenderPool = 32,
    this.deepRefreshInterval = const Duration(hours: 3),
  }) : _currentTag = initialSelectedTag;

  final String initialSelectedTag;
  final Map<String, int> delays;
  final Map<String, bool> domainResults;
  final Map<String, bool> ipResults;
  final Map<String, int> throughputResults;
  final Object? measureGroupDelayError;
  final int maxContenderPool;
  final Duration deepRefreshInterval;
  final List<String> selectedCalls = <String>[];
  final List<String> detachedProbeTags = <String>[];
  final List<String> liveProbeUrls = <String>[];
  DateTime now = DateTime(2026, 4, 3, 12);
  String? _currentTag;

  AutoSelectorService build() {
    return AutoSelectorService(
      measureGroupDelay:
          ({
            required RuntimeSession session,
            required String groupTag,
            required String testUrl,
          }) async {
            final error = measureGroupDelayError;
            if (error != null) {
              throw error;
            }
            return delays;
          },
      loadSelectedTag:
          ({
            required RuntimeSession session,
            required String selectorTag,
          }) async => _currentTag,
      selectProxy:
          ({
            required RuntimeSession session,
            required String selectorTag,
            required String serverTag,
          }) async {
            selectedCalls.add(serverTag);
            _currentTag = serverTag;
          },
      probeViaLocalProxy: ({required int mixedPort, required Uri url}) async {
        liveProbeUrls.add(url.toString());
        final activeTag = _currentTag;
        if (activeTag == null) {
          return false;
        }

        if (url.host == '1.1.1.1') {
          return ipResults[activeTag] ?? false;
        }
        return domainResults[activeTag] ?? false;
      },
      measureThroughputViaLocalProxy:
          ({required int mixedPort, required Uri url}) async {
            final activeTag = _currentTag;
            if (activeTag == null) {
              return 0;
            }
            return throughputResults[activeTag] ??
                ((domainResults[activeTag] ?? false) ||
                        (ipResults[activeTag] ?? false)
                    ? 64 * 1024
                    : 0);
          },
      probeDetachedServer:
          ({
            required RuntimeSession session,
            required ServerEntry server,
            required bool checkIp,
            required String domainProbeUrl,
            required String ipProbeUrl,
            required String throughputProbeUrl,
          }) async {
            detachedProbeTags.add(server.tag);
            return AutoSelectDetachedProbeResult(
              domainProbeOk: domainResults[server.tag] ?? false,
              ipProbeOk: ipResults[server.tag] ?? false,
              throughputBytesPerSecond:
                  throughputResults[server.tag] ??
                  ((domainResults[server.tag] ?? false) ||
                          (ipResults[server.tag] ?? false)
                      ? 64 * 1024
                      : 0),
            );
          },
      pause: (_) async {},
      clock: () => now,
      maxContenderPool: maxContenderPool,
      deepRefreshInterval: deepRefreshInterval,
    );
  }
}
