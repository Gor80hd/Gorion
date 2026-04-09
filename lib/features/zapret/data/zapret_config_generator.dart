import 'dart:io';

import 'package:gorion_clean/features/zapret/model/zapret_models.dart';
import 'package:gorion_clean/features/zapret/model/zapret_settings.dart';
import 'package:path/path.dart' as p;

class ZapretConfigGenerator {
  const ZapretConfigGenerator();

  ZapretLaunchConfiguration build(ZapretSettings settings) {
    final installDirectory = settings.normalizedInstallDirectory;
    if (installDirectory.isEmpty) {
      throw const FormatException('Сначала укажите каталог установки zapret2.');
    }

    final assets = _resolveAssets(
      installDirectory: installDirectory,
      ipSetFilterMode: settings.ipSetFilterMode,
    );

    final customProfile = settings.customProfile;
    if (customProfile != null) {
      return _buildCustomConfiguration(
        settings: settings,
        installDirectory: installDirectory,
        assets: assets,
        customProfile: customProfile,
      );
    }

    final strategy = settings.effectiveStrategy;
    final luaLib = assets.luaLib;
    final luaAntiDpi = assets.luaAntiDpi;
    final youtubeHostlist = assets.youtubeHostlist;
    final googleHostlist = assets.googleHostlist;
    final generalHostlist = assets.generalHostlist;
    final excludeHostlist = assets.excludeHostlist;
    final quicBlob = assets.quicBlob;
    final discordMediaFilter = assets.discordMediaFilter;
    final stunFilter = assets.stunFilter;
    final quicFilter = assets.quicFilter;
    final ipSetPath = assets.ipSetPath;
    final ipSetExcludePath = assets.ipSetExcludePath;

    final usesYoutube = switch (settings.preset) {
      ZapretPreset.recommended ||
      ZapretPreset.youtube ||
      ZapretPreset.combined => true,
      ZapretPreset.discord => false,
    };
    final usesDiscord = switch (settings.preset) {
      ZapretPreset.recommended ||
      ZapretPreset.discord ||
      ZapretPreset.combined => true,
      ZapretPreset.youtube => false,
    };
    final tlsPattern = _resolveTlsPattern(strategy);
    final usesGenericTlsFallback = _usesGenericTlsFallback(
      preset: settings.preset,
      strategy: strategy,
    );

    final tcpOutPorts = _buildTcpOutPorts(
      gameFilterEnabled: settings.gameFilterEnabled,
    );
    final udpOutPorts = _buildUdpOutPorts(
      usesDiscord: usesDiscord,
      gameFilterEnabled: settings.gameFilterEnabled,
    );

    final arguments = <String>[
      '--debug=1',
      '--wf-tcp-out=$tcpOutPorts',
      '--wf-udp-out=$udpOutPorts',
      '--lua-init=@$luaLib',
      '--lua-init=@$luaAntiDpi',
    ];
    final requiredFiles = <String>[luaLib, luaAntiDpi];
    final summaryParts = <String>[strategy.label];

    if (usesYoutube) {
      arguments.add('--blob=quic_google:@$quicBlob');
      arguments.add('--wf-raw-part=@$quicFilter');
      requiredFiles.addAll([youtubeHostlist, quicBlob, quicFilter]);
      summaryParts.add('YouTube через TLS/QUIC');
      arguments.addAll(
        _youtubeArguments(youtubeHostlist, tlsPattern: tlsPattern),
      );
    }

    if (usesDiscord) {
      arguments.add('--wf-raw-part=@$discordMediaFilter');
      arguments.add('--wf-raw-part=@$stunFilter');
      requiredFiles.addAll([discordMediaFilter, stunFilter]);
      summaryParts.add('Голосовой Discord');
      arguments.addAll(
        _discordArguments(startNewProfile: usesYoutube, tlsPattern: tlsPattern),
      );
    }

    if (usesGenericTlsFallback) {
      summaryParts.add('резервный HTTPS-профиль');
      var fallbackProfileStarted = usesYoutube || usesDiscord;
      if (googleHostlist case final googleHostlist?) {
        requiredFiles.add(googleHostlist);
        arguments.addAll(
          _googleTlsFallbackArguments(
            startNewProfile: fallbackProfileStarted,
            googleHostlist: googleHostlist,
            tlsPattern: tlsPattern,
          ),
        );
        fallbackProfileStarted = true;
      }
      if (generalHostlist != null) {
        requiredFiles.add(generalHostlist);
      }
      if (excludeHostlist != null) {
        requiredFiles.add(excludeHostlist);
      }
      if (ipSetExcludePath != null) {
        requiredFiles.add(ipSetExcludePath);
      }
      arguments.addAll(
        _genericTlsFallbackArguments(
          startNewProfile: fallbackProfileStarted,
          tlsPattern: tlsPattern,
          hostlist: generalHostlist,
          hostlistExclude: excludeHostlist,
          ipSetExclude: ipSetExcludePath,
        ),
      );
    }

    if (settings.gameFilterEnabled) {
      summaryParts.add('Game Filter');
      arguments.addAll(
        _gameFilterArguments(startNewProfile: usesYoutube || usesDiscord),
      );
    }

    if (ipSetPath != null) {
      requiredFiles.add(ipSetPath);
      summaryParts.add('IPSet any');
      arguments.addAll(
        _ipSetFallbackArguments(
          startNewProfile: true,
          ipSetPath: ipSetPath,
          tlsPattern: tlsPattern,
          hostlistExclude: excludeHostlist,
          ipSetExclude: ipSetExcludePath,
        ),
      );
    }

    final preview = [
      'Пресет: ${settings.preset.label}',
      'Стратегия: ${strategy.label}',
      'Game Filter: ${settings.gameFilterEnabled ? 'включён' : 'выключен'}',
      'IPSet: ${_describeIpSetState(settings.ipSetFilterMode, ipSetPath)}',
      'Каталог установки: $installDirectory',
      '',
      ...arguments,
    ].join('\n');

    return ZapretLaunchConfiguration(
      workingDirectory: installDirectory,
      arguments: arguments,
      requiredFiles: _dedupe(requiredFiles),
      preview: preview,
      summary: summaryParts.isEmpty
          ? settings.preset.label
          : '${settings.preset.label}: ${summaryParts.join(', ')}',
    );
  }

  String? resolveExecutablePath(String installDirectory) {
    const candidates = <String>[
      'winws2.exe',
      'binaries/windows-x86_64/winws2.exe',
      'binaries/windows-x86/winws2.exe',
      'nfq2\\winws2.exe',
    ];
    for (final candidate in candidates) {
      final fullPath = p.join(installDirectory, candidate);
      if (File(fullPath).existsSync()) {
        return fullPath;
      }
    }
    return null;
  }

  ZapretLaunchConfiguration _buildCustomConfiguration({
    required ZapretSettings settings,
    required String installDirectory,
    required _ZapretResolvedAssets assets,
    required ZapretCustomProfile customProfile,
  }) {
    final tcpOutPorts = _buildCustomTcpOutPorts(
      gameFilterEnabled: settings.gameFilterEnabled,
    );
    final udpOutPorts = _buildCustomUdpOutPorts(
      gameFilterEnabled: settings.gameFilterEnabled,
    );
    final arguments = <String>[
      '--debug=1',
      '--wf-tcp-out=$tcpOutPorts',
      '--wf-udp-out=$udpOutPorts',
      '--lua-init=@${assets.luaLib}',
      '--lua-init=@${assets.luaAntiDpi}',
      '--blob=tls_google:@${assets.tlsGoogleBlob}',
      '--blob=tls_iana:@${assets.tlsIanaBlob}',
      '--blob=quic_google:@${assets.quicBlob}',
      '--wf-raw-part=@${assets.quicFilter}',
      '--wf-raw-part=@${assets.discordMediaFilter}',
      '--wf-raw-part=@${assets.stunFilter}',
      ..._customYoutubeTlsArguments(
        youtubeHostlist: assets.youtubeHostlist,
        variant: customProfile.youtubeVariant,
      ),
      ..._customYoutubeQuicArguments(
        youtubeHostlist: assets.youtubeHostlist,
        variant: customProfile.youtubeVariant,
      ),
      ..._customDiscordMediaArguments(customProfile.discordVariant),
      ..._customDiscordVoiceArguments(),
      if (assets.googleHostlist case final googleHostlist?)
        ..._customGoogleTlsArguments(
          googleHostlist: googleHostlist,
          variant: customProfile.genericVariant,
        ),
      ..._customGenericTlsArguments(
        customProfile.genericVariant,
        hostlist: assets.generalHostlist,
        hostlistExclude: assets.excludeHostlist,
        ipSetExclude: assets.ipSetExcludePath,
      ),
    ];

    final summaryParts = <String>[
      'YouTube ${customProfile.youtubeVariant.label}',
      'Discord ${customProfile.discordVariant.label}',
      'HTTPS ${customProfile.genericVariant.label}',
    ];
    final requiredFiles = <String>[
      assets.luaLib,
      assets.luaAntiDpi,
      assets.youtubeHostlist,
      assets.quicBlob,
      assets.quicFilter,
      assets.discordMediaFilter,
      assets.stunFilter,
      assets.tlsGoogleBlob,
      assets.tlsIanaBlob,
      if (assets.googleHostlist != null) assets.googleHostlist!,
      if (assets.generalHostlist != null) assets.generalHostlist!,
      if (assets.excludeHostlist != null) assets.excludeHostlist!,
      if (assets.ipSetExcludePath != null) assets.ipSetExcludePath!,
    ];

    if (settings.gameFilterEnabled) {
      summaryParts.add('Game Filter');
      arguments.addAll(_gameFilterArguments(startNewProfile: true));
    }

    if (assets.ipSetPath case final ipSetPath?) {
      requiredFiles.add(ipSetPath);
      summaryParts.add('IPSet any');
      arguments.addAll(
        _customIpSetFallbackArguments(
          ipSetPath: ipSetPath,
          variant: customProfile.genericVariant,
          hostlistExclude: assets.excludeHostlist,
          ipSetExclude: assets.ipSetExcludePath,
        ),
      );
    }

    final preview = [
      'Профиль: Автоподобранный Flowseal-style',
      'Сводка: ${customProfile.summaryLabel}',
      'Game Filter: ${settings.gameFilterEnabled ? 'включён' : 'выключен'}',
      'IPSet: ${_describeIpSetState(settings.ipSetFilterMode, assets.ipSetPath)}',
      'Каталог установки: $installDirectory',
      '',
      ...arguments,
    ].join('\n');

    return ZapretLaunchConfiguration(
      workingDirectory: installDirectory,
      arguments: arguments,
      requiredFiles: _dedupe(requiredFiles),
      preview: preview,
      summary: 'Flowseal: ${summaryParts.join(', ')}',
    );
  }

  List<String> _customYoutubeTlsArguments({
    required String youtubeHostlist,
    required ZapretFlowsealVariant variant,
  }) {
    return _flowsealTlsBlockArguments(
      profileName: null,
      filterTcp: '443',
      hostlist: youtubeHostlist,
      blobAlias: 'tls_google',
      hostValue: 'www.google.com',
      variant: variant,
    );
  }

  List<String> _customYoutubeQuicArguments({
    required String youtubeHostlist,
    required ZapretFlowsealVariant variant,
  }) {
    return [
      '--new=youtube_quic',
      '--filter-udp=443',
      '--filter-l7=quic',
      '--hostlist=$youtubeHostlist',
      '--payload=quic_initial',
      '--lua-desync=fake:blob=quic_google:repeats=${_flowsealQuicRepeats(variant)}',
    ];
  }

  List<String> _customDiscordMediaArguments(ZapretFlowsealVariant variant) {
    return _flowsealTlsBlockArguments(
      profileName: 'discord_media',
      filterTcp: '2053,2083,2087,2096,8443',
      hostlistDomains: 'discord.media',
      blobAlias: 'tls_google',
      hostValue: 'www.google.com',
      variant: variant,
    );
  }

  List<String> _customGoogleTlsArguments({
    required String googleHostlist,
    required ZapretFlowsealVariant variant,
  }) {
    return _flowsealTlsBlockArguments(
      profileName: 'google_tls',
      filterTcp: '443',
      hostlist: googleHostlist,
      blobAlias: 'tls_google',
      hostValue: 'www.google.com',
      variant: variant,
    );
  }

  List<String> _customDiscordVoiceArguments() {
    return const [
      '--new=discord_voice',
      '--filter-udp=19294-19344,50000-50100',
      '--filter-l7=stun,discord',
      '--lua-desync=fake:blob=0x00000000000000000000000000000000:repeats=6',
    ];
  }

  List<String> _customGenericTlsArguments(
    ZapretFlowsealVariant variant, {
    String? hostlist,
    String? hostlistExclude,
    String? ipSetExclude,
  }) {
    return _flowsealTlsBlockArguments(
      profileName: 'generic_tls',
      filterTcp: '443',
      hostlist: hostlist,
      hostlistExclude: hostlistExclude,
      ipSetExclude: ipSetExclude,
      blobAlias: 'tls_iana',
      hostValue: 'www.iana.org',
      variant: variant,
    );
  }

  List<String> _customIpSetFallbackArguments({
    required String ipSetPath,
    required ZapretFlowsealVariant variant,
    String? hostlistExclude,
    String? ipSetExclude,
  }) {
    return [
      '--new=ipset_any',
      '--filter-tcp=443',
      '--filter-l7=tls',
      '--ipset=$ipSetPath',
      if (hostlistExclude != null) '--hostlist-exclude=$hostlistExclude',
      if (ipSetExclude != null) '--ipset-exclude=$ipSetExclude',
      '--out-range=${_variantOutRange(variant)}',
      '--payload=tls_client_hello',
      '--lua-desync=${_flowsealPrimaryDesync(variant: variant, blobAlias: 'tls_iana', hostValue: 'www.iana.org')}',
      ..._flowsealFollowUpDesyncs(
        variant: variant,
        blobAlias: 'tls_iana',
        hostValue: 'www.iana.org',
      ).map((value) => '--lua-desync=$value'),
    ];
  }

  List<String> _flowsealTlsBlockArguments({
    required String? profileName,
    required String filterTcp,
    String? hostlist,
    String? hostlistDomains,
    String? hostlistExclude,
    String? ipSetExclude,
    required String blobAlias,
    required String hostValue,
    required ZapretFlowsealVariant variant,
  }) {
    return [
      if (profileName != null) '--new=$profileName',
      '--filter-tcp=$filterTcp',
      '--filter-l7=tls',
      if (hostlist != null) '--hostlist=$hostlist',
      if (hostlistDomains != null) '--hostlist-domains=$hostlistDomains',
      if (hostlistExclude != null) '--hostlist-exclude=$hostlistExclude',
      if (ipSetExclude != null) '--ipset-exclude=$ipSetExclude',
      '--out-range=${_variantOutRange(variant)}',
      '--payload=tls_client_hello',
      '--lua-desync=${_flowsealPrimaryDesync(variant: variant, blobAlias: blobAlias, hostValue: hostValue)}',
      ..._flowsealFollowUpDesyncs(
        variant: variant,
        blobAlias: blobAlias,
        hostValue: hostValue,
      ).map((value) => '--lua-desync=$value'),
    ];
  }

  String _variantOutRange(ZapretFlowsealVariant variant) {
    return switch (variant) {
      ZapretFlowsealVariant.fakedsplit ||
      ZapretFlowsealVariant.multisplit => '-d9',
      ZapretFlowsealVariant.hostfakesplit ||
      ZapretFlowsealVariant.multidisorder => '-d8',
    };
  }

  String _flowsealPrimaryDesync({
    required ZapretFlowsealVariant variant,
    required String blobAlias,
    required String hostValue,
  }) {
    return switch (variant) {
      ZapretFlowsealVariant.fakedsplit =>
        'fake:blob=$blobAlias:tcp_md5:repeats=6:tls_mod=rnd,dupsid,sni=$hostValue',
      ZapretFlowsealVariant.multisplit =>
        'multisplit:pos=1:seqovl=1:seqovl_pattern=$blobAlias',
      ZapretFlowsealVariant.hostfakesplit =>
        'fake:blob=$blobAlias:tcp_md5:repeats=6:tls_mod=rnd,dupsid,sni=$hostValue',
      ZapretFlowsealVariant.multidisorder =>
        'fake:blob=$blobAlias:tcp_md5:repeats=6:tls_mod=rnd,dupsid,sni=$hostValue',
    };
  }

  List<String> _flowsealFollowUpDesyncs({
    required ZapretFlowsealVariant variant,
    required String blobAlias,
    required String hostValue,
  }) {
    return switch (variant) {
      ZapretFlowsealVariant.fakedsplit => [
        'fakedsplit:pos=midsld+1:seqovl=1:seqovl_pattern=$blobAlias',
      ],
      ZapretFlowsealVariant.multisplit => const [],
      ZapretFlowsealVariant.hostfakesplit => [
        'hostfakesplit:host=$hostValue:altorder=1',
      ],
      ZapretFlowsealVariant.multidisorder => const [
        'multidisorder:pos=1,midsld',
      ],
    };
  }

  int _flowsealQuicRepeats(ZapretFlowsealVariant variant) {
    return switch (variant) {
      ZapretFlowsealVariant.fakedsplit => 6,
      ZapretFlowsealVariant.multisplit => 11,
      ZapretFlowsealVariant.hostfakesplit => 10,
      ZapretFlowsealVariant.multidisorder => 11,
    };
  }

  String _buildCustomTcpOutPorts({required bool gameFilterEnabled}) {
    return gameFilterEnabled
        ? '443,2053,2083,2087,2096,8443,1024-65535'
        : '443,2053,2083,2087,2096,8443';
  }

  String _buildCustomUdpOutPorts({required bool gameFilterEnabled}) {
    return gameFilterEnabled
        ? '443,19294-19344,50000-50100,1024-65535'
        : '443,19294-19344,50000-50100';
  }

  List<String> _youtubeArguments(
    String youtubeHostlist, {
    required _ZapretTlsPattern tlsPattern,
  }) {
    return [
      '--filter-tcp=443',
      '--filter-l7=tls',
      '--hostlist=$youtubeHostlist',
      '--out-range=${_tlsOutRange(tlsPattern)}',
      '--payload=tls_client_hello',
      '--lua-desync=${_youtubeTlsFakeDesync(tlsPattern)}',
      ..._followUpTlsDesyncs(tlsPattern).map((value) => '--lua-desync=$value'),
      '--new=youtube_quic',
      '--filter-udp=443',
      '--filter-l7=quic',
      '--hostlist=$youtubeHostlist',
      '--payload=quic_initial',
      '--lua-desync=fake:blob=quic_google:repeats=${_youtubeQuicRepeats(tlsPattern)}',
    ];
  }

  List<String> _discordArguments({
    required bool startNewProfile,
    required _ZapretTlsPattern tlsPattern,
  }) {
    return [
      if (startNewProfile) '--new=discord_voice',
      '--filter-udp=19294-19344,50000-50100',
      '--filter-l7=stun,discord',
      '--lua-desync=fake:blob=0x00000000000000000000000000000000:repeats=${_discordFakeRepeats(tlsPattern)}',
    ];
  }

  List<String> _googleTlsFallbackArguments({
    required bool startNewProfile,
    required String googleHostlist,
    required _ZapretTlsPattern tlsPattern,
  }) {
    return [
      if (startNewProfile) '--new=google_tls',
      '--filter-tcp=443',
      '--filter-l7=tls',
      '--hostlist=$googleHostlist',
      '--out-range=${_tlsOutRange(tlsPattern)}',
      '--payload=tls_client_hello',
      '--lua-desync=${_youtubeTlsFakeDesync(tlsPattern)}',
      ..._followUpTlsDesyncs(tlsPattern).map((value) => '--lua-desync=$value'),
    ];
  }

  List<String> _genericTlsFallbackArguments({
    required bool startNewProfile,
    required _ZapretTlsPattern tlsPattern,
    String? hostlist,
    String? hostlistExclude,
    String? ipSetExclude,
  }) {
    return [
      if (startNewProfile) '--new=generic_tls',
      '--filter-tcp=443',
      '--filter-l7=tls',
      if (hostlist != null) '--hostlist=$hostlist',
      if (hostlistExclude != null) '--hostlist-exclude=$hostlistExclude',
      if (ipSetExclude != null) '--ipset-exclude=$ipSetExclude',
      '--out-range=${_tlsOutRange(tlsPattern)}',
      '--payload=tls_client_hello',
      '--lua-desync=${_genericTlsFakeDesync(tlsPattern)}',
      ..._followUpTlsDesyncs(tlsPattern).map((value) => '--lua-desync=$value'),
    ];
  }

  List<String> _gameFilterArguments({required bool startNewProfile}) {
    return [
      if (startNewProfile) '--new=game_filter',
      '--filter-tcp=1024-65535',
      '--filter-udp=1024-65535',
      '--lua-desync=fake:blob=0x00000000000000000000000000000000:repeats=2',
    ];
  }

  List<String> _ipSetFallbackArguments({
    required bool startNewProfile,
    required String ipSetPath,
    required _ZapretTlsPattern tlsPattern,
    String? hostlistExclude,
    String? ipSetExclude,
  }) {
    return [
      if (startNewProfile) '--new=ipset_any',
      '--filter-tcp=80,443',
      '--filter-l7=tls',
      '--ipset=$ipSetPath',
      if (hostlistExclude != null) '--hostlist-exclude=$hostlistExclude',
      if (ipSetExclude != null) '--ipset-exclude=$ipSetExclude',
      '--out-range=${_tlsOutRange(tlsPattern)}',
      '--payload=tls_client_hello',
      '--lua-desync=${_genericTlsFakeDesync(tlsPattern)}',
      ..._followUpTlsDesyncs(tlsPattern).map((value) => '--lua-desync=$value'),
    ];
  }

  _ZapretTlsPattern _resolveTlsPattern(ZapretStrategyProfile strategy) {
    return switch (strategy) {
      ZapretStrategyProfile.balancedDefault ||
      ZapretStrategyProfile.combinedDefault => _ZapretTlsPattern.classic,
      ZapretStrategyProfile.balancedStrong ||
      ZapretStrategyProfile.combinedStrong => _ZapretTlsPattern.strong,
      ZapretStrategyProfile.balancedSplit ||
      ZapretStrategyProfile.combinedSplit => _ZapretTlsPattern.fakeSplit,
      ZapretStrategyProfile.balancedDisorder ||
      ZapretStrategyProfile.combinedDisorder => _ZapretTlsPattern.fakeDisorder,
    };
  }

  bool _usesGenericTlsFallback({
    required ZapretPreset preset,
    required ZapretStrategyProfile strategy,
  }) {
    if (preset == ZapretPreset.combined) {
      return true;
    }
    if (preset != ZapretPreset.recommended) {
      return false;
    }

    return strategy != ZapretStrategyProfile.balancedDefault;
  }

  String _buildTcpOutPorts({required bool gameFilterEnabled}) {
    return gameFilterEnabled ? '80,443,1024-65535' : '80,443';
  }

  String _buildUdpOutPorts({
    required bool usesDiscord,
    required bool gameFilterEnabled,
  }) {
    final ports = <String>['443'];
    if (usesDiscord) {
      ports.add('19294-19344');
      ports.add('50000-50100');
    }
    if (gameFilterEnabled) {
      ports.add('1024-65535');
    }
    return ports.join(',');
  }

  String _tlsOutRange(_ZapretTlsPattern pattern) {
    return switch (pattern) {
      _ZapretTlsPattern.classic => '-d10',
      _ZapretTlsPattern.strong => '-d8',
      _ZapretTlsPattern.fakeSplit => '-d9',
      _ZapretTlsPattern.fakeDisorder => '-d8',
    };
  }

  String _youtubeTlsFakeDesync(_ZapretTlsPattern pattern) {
    return switch (pattern) {
      _ZapretTlsPattern.classic =>
        'fake:blob=fake_default_tls:tcp_md5:repeats=11:tls_mod=rnd,dupsid,sni=www.google.com',
      _ZapretTlsPattern.strong =>
        'fake:blob=fake_default_tls:tcp_md5:tcp_seq=-10000:repeats=13:tls_mod=rnd,rndsni,dupsid,sni=www.google.com',
      _ZapretTlsPattern.fakeSplit =>
        'fake:blob=fake_default_tls:tcp_md5:tcp_seq=-10000:repeats=9:tls_mod=rnd,rndsni,dupsid,sni=www.google.com',
      _ZapretTlsPattern.fakeDisorder =>
        'fake:blob=fake_default_tls:tcp_md5:tcp_seq=-10000:repeats=10:tls_mod=rnd,rndsni,dupsid,sni=www.google.com',
    };
  }

  String _genericTlsFakeDesync(_ZapretTlsPattern pattern) {
    return switch (pattern) {
      _ZapretTlsPattern.classic =>
        'fake:blob=fake_default_tls:tcp_md5:tcp_seq=-10000:repeats=6:tls_mod=rnd,rndsni,dupsid',
      _ZapretTlsPattern.strong =>
        'fake:blob=fake_default_tls:tcp_md5:tcp_seq=-10000:repeats=10:tls_mod=rnd,rndsni,dupsid,sni=www.google.com',
      _ZapretTlsPattern.fakeSplit =>
        'fake:blob=fake_default_tls:tcp_md5:tcp_seq=-10000:repeats=8:tls_mod=rnd,rndsni,dupsid,sni=www.google.com',
      _ZapretTlsPattern.fakeDisorder =>
        'fake:blob=fake_default_tls:tcp_md5:tcp_seq=-10000:repeats=9:tls_mod=rnd,rndsni,dupsid,sni=www.google.com',
    };
  }

  List<String> _followUpTlsDesyncs(_ZapretTlsPattern pattern) {
    return switch (pattern) {
      _ZapretTlsPattern.classic => const ['multidisorder:pos=1,midsld'],
      _ZapretTlsPattern.strong => const ['multidisorder:pos=1,sld,midsld+1'],
      _ZapretTlsPattern.fakeSplit => const ['fakedsplit:pos=midsld+1:seqovl=1'],
      _ZapretTlsPattern.fakeDisorder => const ['fakeddisorder:pos=midsld+1'],
    };
  }

  int _youtubeQuicRepeats(_ZapretTlsPattern pattern) {
    return switch (pattern) {
      _ZapretTlsPattern.classic => 11,
      _ZapretTlsPattern.strong => 13,
      _ZapretTlsPattern.fakeSplit => 9,
      _ZapretTlsPattern.fakeDisorder => 10,
    };
  }

  int _discordFakeRepeats(_ZapretTlsPattern pattern) {
    return switch (pattern) {
      _ZapretTlsPattern.classic => 2,
      _ZapretTlsPattern.strong => 4,
      _ZapretTlsPattern.fakeSplit => 4,
      _ZapretTlsPattern.fakeDisorder => 6,
    };
  }

  List<String> _dedupe(List<String> values) {
    final seen = <String>{};
    final result = <String>[];
    for (final value in values) {
      if (seen.add(value)) {
        result.add(value);
      }
    }
    return result;
  }

  String _resolvePath(String installDirectory, List<String> candidates) {
    final fullPaths = [
      for (final candidate in candidates)
        p.joinAll([installDirectory, ...candidate.split('/')]),
    ];
    for (final fullPath in fullPaths) {
      if (File(fullPath).existsSync()) {
        return fullPath;
      }
    }
    return fullPaths.first;
  }

  String? _resolveOptionalPath(
    String installDirectory,
    List<String> candidates,
  ) {
    for (final candidate in candidates) {
      final fullPath = p.joinAll([installDirectory, ...candidate.split('/')]);
      if (File(fullPath).existsSync()) {
        return fullPath;
      }
    }
    return null;
  }

  String _describeIpSetState(ZapretIpSetFilterMode mode, String? ipSetPath) {
    return switch (mode) {
      ZapretIpSetFilterMode.none => 'выключен',
      ZapretIpSetFilterMode.any when ipSetPath != null => 'any ($ipSetPath)',
      ZapretIpSetFilterMode.any => 'any, файл ipset-all.txt не найден',
    };
  }

  _ZapretResolvedAssets _resolveAssets({
    required String installDirectory,
    required ZapretIpSetFilterMode ipSetFilterMode,
  }) {
    return _ZapretResolvedAssets(
      luaLib: _resolvePath(installDirectory, const ['lua/zapret-lib.lua']),
      luaAntiDpi: _resolvePath(installDirectory, const [
        'lua/zapret-antidpi.lua',
      ]),
      youtubeHostlist: _resolvePath(installDirectory, const [
        'files/list-youtube.txt',
      ]),
      googleHostlist: _resolveOptionalPath(installDirectory, const [
        'files/list-google.txt',
        'lists/list-google.txt',
        'list-google.txt',
      ]),
      generalHostlist: _resolveOptionalPath(installDirectory, const [
        'files/list-general.txt',
        'lists/list-general.txt',
        'list-general.txt',
      ]),
      excludeHostlist: _resolveOptionalPath(installDirectory, const [
        'files/list-exclude.txt',
        'lists/list-exclude.txt',
        'list-exclude.txt',
      ]),
      quicBlob: _resolvePath(installDirectory, const [
        'files/fake/quic_initial_www_google_com.bin',
        'files/quic_initial_www_google_com.bin',
      ]),
      tlsGoogleBlob: _resolvePath(installDirectory, const [
        'files/fake/tls_clienthello_www_google_com.bin',
        'files/tls_clienthello_www_google_com.bin',
      ]),
      tlsIanaBlob: _resolvePath(installDirectory, const [
        'files/fake/tls_clienthello_iana_org.bin',
        'files/tls_clienthello_iana_org.bin',
      ]),
      discordMediaFilter: _resolvePath(installDirectory, const [
        'init.d/windivert.filter.examples/windivert_part.discord_media.txt',
        'windivert.filter/windivert_part.discord_media.txt',
      ]),
      stunFilter: _resolvePath(installDirectory, const [
        'init.d/windivert.filter.examples/windivert_part.stun.txt',
        'windivert.filter/windivert_part.stun.txt',
      ]),
      quicFilter: _resolvePath(installDirectory, const [
        'init.d/windivert.filter.examples/windivert_part.quic_initial_ietf.txt',
        'windivert.filter/windivert_part.quic_initial_ietf.txt',
      ]),
      ipSetPath: ipSetFilterMode == ZapretIpSetFilterMode.any
          ? _resolveOptionalPath(installDirectory, const [
              'files/ipset-all.txt',
              'lists/ipset-all.txt',
              'ipset-all.txt',
              'ipset/ipset-all.txt',
            ])
          : null,
      ipSetExcludePath: _resolveOptionalPath(installDirectory, const [
        'files/ipset-exclude.txt',
        'lists/ipset-exclude.txt',
        'ipset-exclude.txt',
        'ipset/ipset-exclude.txt',
      ]),
    );
  }
}

enum _ZapretTlsPattern { classic, strong, fakeSplit, fakeDisorder }

class _ZapretResolvedAssets {
  const _ZapretResolvedAssets({
    required this.luaLib,
    required this.luaAntiDpi,
    required this.youtubeHostlist,
    required this.googleHostlist,
    required this.generalHostlist,
    required this.excludeHostlist,
    required this.quicBlob,
    required this.tlsGoogleBlob,
    required this.tlsIanaBlob,
    required this.discordMediaFilter,
    required this.stunFilter,
    required this.quicFilter,
    required this.ipSetPath,
    required this.ipSetExcludePath,
  });

  final String luaLib;
  final String luaAntiDpi;
  final String youtubeHostlist;
  final String? googleHostlist;
  final String? generalHostlist;
  final String? excludeHostlist;
  final String quicBlob;
  final String tlsGoogleBlob;
  final String tlsIanaBlob;
  final String discordMediaFilter;
  final String stunFilter;
  final String quicFilter;
  final String? ipSetPath;
  final String? ipSetExcludePath;
}
