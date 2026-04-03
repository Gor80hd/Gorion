import 'dart:async';
import 'dart:io';

import 'package:gorion_clean/features/profiles/model/profile_models.dart';
import 'package:gorion_clean/features/runtime/data/clash_api_client.dart';
import 'package:gorion_clean/features/runtime/model/runtime_models.dart';

class AutoSelectProbeResult {
  const AutoSelectProbeResult({
    required this.serverTag,
    required this.urlTestDelay,
    required this.domainProbeOk,
    required this.ipProbeOk,
  });

  final String serverTag;
  final int? urlTestDelay;
  final bool domainProbeOk;
  final bool ipProbeOk;

  int get healthScore {
    if (domainProbeOk && ipProbeOk) {
      return 3;
    }
    if (domainProbeOk) {
      return 2;
    }
    if (ipProbeOk) {
      return 1;
    }
    return 0;
  }
}

class AutoSelectOutcome {
  const AutoSelectOutcome({
    required this.selectedServerTag,
    required this.delayByTag,
    required this.probes,
    required this.summary,
  });

  final String selectedServerTag;
  final Map<String, int> delayByTag;
  final List<AutoSelectProbeResult> probes;
  final String summary;
}

class AutoSelectorService {
  Future<AutoSelectOutcome> selectBestServer({
    required RuntimeSession session,
    required List<ServerEntry> servers,
    required String domainProbeUrl,
    String ipProbeUrl = 'http://1.1.1.1',
  }) async {
    if (servers.isEmpty) {
      throw const FormatException('There are no servers to auto-select from.');
    }

    final clashClient = ClashApiClient.fromSession(session);
    final delayByTag = await clashClient.measureGroupDelay(
      groupTag: session.autoGroupTag,
      testUrl: domainProbeUrl,
    );

    final candidates = [...servers]
      ..sort((left, right) {
        final leftDelay = delayByTag[left.tag] ?? 1 << 30;
        final rightDelay = delayByTag[right.tag] ?? 1 << 30;
        return leftDelay.compareTo(rightDelay);
      });

    final probes = <AutoSelectProbeResult>[];
    final inspected = candidates.take(6);
    for (final server in inspected) {
      await clashClient.selectProxy(selectorTag: session.manualSelectorTag, serverTag: server.tag);
      await Future<void>.delayed(const Duration(milliseconds: 700));

      final domainProbeOk = await _probeViaLocalProxy(
        mixedPort: session.mixedPort,
        url: Uri.parse(domainProbeUrl),
      );
      final ipProbeOk = await _probeViaLocalProxy(
        mixedPort: session.mixedPort,
        url: Uri.parse(ipProbeUrl),
      );

      probes.add(
        AutoSelectProbeResult(
          serverTag: server.tag,
          urlTestDelay: delayByTag[server.tag],
          domainProbeOk: domainProbeOk,
          ipProbeOk: ipProbeOk,
        ),
      );

      if (domainProbeOk && ipProbeOk && (delayByTag[server.tag] ?? 999999) <= 250) {
        break;
      }
    }

    if (probes.isEmpty) {
      throw const FormatException('The auto-selector could not probe any server candidates.');
    }

    final ranked = [...probes]
      ..sort((left, right) {
        final scoreCompare = right.healthScore.compareTo(left.healthScore);
        if (scoreCompare != 0) {
          return scoreCompare;
        }
        final leftDelay = left.urlTestDelay ?? 1 << 30;
        final rightDelay = right.urlTestDelay ?? 1 << 30;
        return leftDelay.compareTo(rightDelay);
      });

    final winner = ranked.first;
    if (winner.healthScore == 0) {
      throw const FormatException(
        'No candidate passed an end-to-end proxy probe. TCP-only success is ignored by design.',
      );
    }

    await clashClient.selectProxy(selectorTag: session.manualSelectorTag, serverTag: winner.serverTag);

    final summary = winner.domainProbeOk && winner.ipProbeOk
        ? 'Auto-selector chose ${winner.serverTag} using URLTest plus IP and domain probes through the local proxy.'
        : winner.domainProbeOk
            ? 'Auto-selector chose ${winner.serverTag}. Domain traffic worked, but the IP-only probe stayed partial.'
            : 'Auto-selector chose ${winner.serverTag} with partial confidence. IP-only probe worked, domain probe did not.';

    return AutoSelectOutcome(
      selectedServerTag: winner.serverTag,
      delayByTag: delayByTag,
      probes: ranked,
      summary: summary,
    );
  }

  Future<bool> _probeViaLocalProxy({
    required int mixedPort,
    required Uri url,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 6)
      ..findProxy = (_) => 'PROXY 127.0.0.1:$mixedPort';

    try {
      final request = await client.getUrl(url);
      request.headers.set(HttpHeaders.userAgentHeader, 'GorionClean/1.0');
      final response = await request.close().timeout(const Duration(seconds: 6));
      final bytes = await response.fold<int>(0, (sum, chunk) => sum + chunk.length);
      final acceptedStatus = response.statusCode == HttpStatus.noContent ||
          (response.statusCode >= HttpStatus.ok && response.statusCode < HttpStatus.multipleChoices);
      return acceptedStatus || bytes > 0;
    } on Object {
      return false;
    } finally {
      client.close(force: true);
    }
  }
}