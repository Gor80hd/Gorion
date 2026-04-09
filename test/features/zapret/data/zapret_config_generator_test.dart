import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gorion_clean/features/zapret/data/zapret_config_generator.dart';
import 'package:gorion_clean/features/zapret/model/zapret_models.dart';
import 'package:gorion_clean/features/zapret/model/zapret_settings.dart';
import 'package:path/path.dart' as p;

void main() {
  const generator = ZapretConfigGenerator();

  test(
    'builds a combined preset with YouTube, Discord, and generic fallback',
    () {
      final config = generator.build(
        const ZapretSettings(
          installDirectory: r'E:\Tools\zapret2',
          preset: ZapretPreset.combined,
        ),
      );

      expect(config.summary, contains('Комбинированный усиленный'));
      expect(
        config.preview,
        contains('--wf-udp-out=443,19294-19344,50000-50100'),
      );
      expect(config.preview, contains('--filter-l7=tls'));
      expect(config.preview, contains('--filter-udp=19294-19344,50000-50100'));
      expect(config.preview, contains('--filter-l7=stun,discord'));
      expect(config.preview, contains('--new=generic_tls'));
      expect(
        config.preview,
        contains(
          '--lua-desync=fake:blob=fake_default_tls:tcp_md5:tcp_seq=-10000:repeats=6:tls_mod=rnd,rndsni,dupsid',
        ),
      );
      expect(config.preview, isNot(contains('discord_ip_discovery')));
      expect(config.preview, isNot(contains('--lua-init=fake_default_tls=')));
      expect(
        config.requiredFiles,
        contains(p.join(r'E:\Tools\zapret2', 'lua', 'zapret-lib.lua')),
      );
      expect(
        config.requiredFiles,
        contains(p.join(r'E:\Tools\zapret2', 'files', 'list-youtube.txt')),
      );
    },
  );

  test('does not emit unsupported discord payload aliases', () {
    final config = generator.build(
      const ZapretSettings(
        installDirectory: r'E:\Tools\zapret2',
        preset: ZapretPreset.discord,
      ),
    );

    expect(config.arguments, contains('--filter-l7=stun,discord'));
    expect(
      config.arguments,
      isNot(contains('--payload=stun,discord_ip_discovery')),
    );
  });

  test(
    'builds a Flowseal-style custom profile without legacy preset coupling',
    () {
      final config = generator.build(
        const ZapretSettings(
          installDirectory: r'E:\Tools\zapret2',
          customProfile: ZapretCustomProfile(
            youtubeVariant: ZapretFlowsealVariant.multisplit,
            discordVariant: ZapretFlowsealVariant.hostfakesplit,
            genericVariant: ZapretFlowsealVariant.multidisorder,
          ),
        ),
      );

      expect(config.summary, contains('Flowseal:'));
      expect(config.arguments, contains('--new=discord_media'));
      expect(config.arguments, contains('--hostlist-domains=discord.media'));
      expect(
        config.arguments,
        contains('--filter-udp=19294-19344,50000-50100'),
      );
      expect(
        config.arguments,
        contains(
          '--blob=tls_google:@${p.join(r'E:\Tools\zapret2', 'files', 'fake', 'tls_clienthello_www_google_com.bin')}',
        ),
      );
      expect(
        config.arguments,
        contains('--lua-desync=hostfakesplit:host=www.google.com:altorder=1'),
      );
      expect(
        config.arguments,
        contains('--lua-desync=multidisorder:pos=1,midsld'),
      );
    },
  );

  test(
    'scopes Flowseal fallback blocks by hostlists when list files exist',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'gorion-zapret-flowseal-lists-',
      );
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      Future<void> touch(String relativePath) async {
        final file = File(
          p.joinAll([tempDir.path, ...relativePath.split('/')]),
        );
        await file.parent.create(recursive: true);
        await file.writeAsString('');
      }

      await touch('lua/zapret-lib.lua');
      await touch('lua/zapret-antidpi.lua');
      await touch('files/list-youtube.txt');
      await touch('files/list-google.txt');
      await touch('files/list-general.txt');
      await touch('files/list-exclude.txt');
      await touch('files/ipset-exclude.txt');
      await touch('files/fake/quic_initial_www_google_com.bin');
      await touch('files/fake/tls_clienthello_www_google_com.bin');
      await touch('files/fake/tls_clienthello_iana_org.bin');
      await touch(
        'init.d/windivert.filter.examples/windivert_part.discord_media.txt',
      );
      await touch('init.d/windivert.filter.examples/windivert_part.stun.txt');
      await touch(
        'init.d/windivert.filter.examples/windivert_part.quic_initial_ietf.txt',
      );

      final config = generator.build(
        ZapretSettings(
          installDirectory: tempDir.path,
          customProfile: const ZapretCustomProfile(
            youtubeVariant: ZapretFlowsealVariant.multisplit,
            discordVariant: ZapretFlowsealVariant.fakedsplit,
            genericVariant: ZapretFlowsealVariant.multidisorder,
          ),
        ),
      );

      expect(config.arguments, contains('--new=google_tls'));
      expect(
        config.arguments,
        contains(
          '--hostlist=${p.join(tempDir.path, 'files', 'list-google.txt')}',
        ),
      );
      expect(
        config.arguments,
        contains(
          '--hostlist=${p.join(tempDir.path, 'files', 'list-general.txt')}',
        ),
      );
      expect(
        config.arguments,
        contains(
          '--hostlist-exclude=${p.join(tempDir.path, 'files', 'list-exclude.txt')}',
        ),
      );
      expect(
        config.arguments,
        contains(
          '--ipset-exclude=${p.join(tempDir.path, 'files', 'ipset-exclude.txt')}',
        ),
      );
    },
  );

  test('does not rely on startup lua init to mutate fake_default_tls', () {
    final config = generator.build(
      const ZapretSettings(
        installDirectory: r'E:\Tools\zapret2',
        preset: ZapretPreset.youtube,
      ),
    );

    expect(
      config.arguments,
      isNot(
        contains(
          "--lua-init=fake_default_tls=tls_mod(fake_default_tls,'rnd,rndsni')",
        ),
      ),
    );
  });

  test('prefers upstream zapret2 companion paths when they exist', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'gorion-zapret-layout-',
    );
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    Future<void> touch(String relativePath) async {
      final file = File(p.joinAll([tempDir.path, ...relativePath.split('/')]));
      await file.parent.create(recursive: true);
      await file.writeAsString('');
    }

    await touch('lua/zapret-lib.lua');
    await touch('lua/zapret-antidpi.lua');
    await touch('files/list-youtube.txt');
    await touch('files/fake/quic_initial_www_google_com.bin');
    await touch(
      'init.d/windivert.filter.examples/windivert_part.discord_media.txt',
    );
    await touch('init.d/windivert.filter.examples/windivert_part.stun.txt');
    await touch(
      'init.d/windivert.filter.examples/windivert_part.quic_initial_ietf.txt',
    );

    final config = generator.build(
      ZapretSettings(
        installDirectory: tempDir.path,
        preset: ZapretPreset.combined,
      ),
    );

    expect(
      config.requiredFiles,
      contains(
        p.join(
          tempDir.path,
          'files',
          'fake',
          'quic_initial_www_google_com.bin',
        ),
      ),
    );
    expect(
      config.requiredFiles,
      contains(
        p.join(
          tempDir.path,
          'init.d',
          'windivert.filter.examples',
          'windivert_part.stun.txt',
        ),
      ),
    );
  });

  test('adds Game Filter and optional IPSet overlay when enabled', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'gorion-zapret-game-ipset-',
    );
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    Future<void> touch(String relativePath) async {
      final file = File(p.joinAll([tempDir.path, ...relativePath.split('/')]));
      await file.parent.create(recursive: true);
      await file.writeAsString('');
    }

    await touch('lua/zapret-lib.lua');
    await touch('lua/zapret-antidpi.lua');
    await touch('files/list-youtube.txt');
    await touch('files/list-exclude.txt');
    await touch('files/ipset-exclude.txt');
    await touch('files/fake/quic_initial_www_google_com.bin');
    await touch('files/ipset-all.txt');
    await touch(
      'init.d/windivert.filter.examples/windivert_part.discord_media.txt',
    );
    await touch('init.d/windivert.filter.examples/windivert_part.stun.txt');
    await touch(
      'init.d/windivert.filter.examples/windivert_part.quic_initial_ietf.txt',
    );

    final config = generator.build(
      ZapretSettings(
        installDirectory: tempDir.path,
        preset: ZapretPreset.combined,
        strategyProfile: ZapretStrategyProfile.combinedStrong,
        gameFilterEnabled: true,
        ipSetFilterMode: ZapretIpSetFilterMode.any,
      ),
    );

    expect(config.arguments, contains('--wf-tcp-out=80,443,1024-65535'));
    expect(
      config.arguments,
      contains('--wf-udp-out=443,19294-19344,50000-50100,1024-65535'),
    );
    expect(config.arguments, contains('--new=game_filter'));
    expect(
      config.arguments,
      contains('--ipset=${p.join(tempDir.path, 'files', 'ipset-all.txt')}'),
    );
    expect(
      config.arguments,
      contains(
        '--hostlist-exclude=${p.join(tempDir.path, 'files', 'list-exclude.txt')}',
      ),
    );
    expect(
      config.arguments,
      contains(
        '--ipset-exclude=${p.join(tempDir.path, 'files', 'ipset-exclude.txt')}',
      ),
    );
    expect(config.summary, contains('Game Filter'));
    expect(config.summary, contains('IPSet any'));
  });

  test('builds a detailed split strategy with fakedsplit fallback', () {
    final config = generator.build(
      const ZapretSettings(
        installDirectory: r'E:\Tools\zapret2',
        preset: ZapretPreset.recommended,
        strategyProfile: ZapretStrategyProfile.balancedSplit,
      ),
    );

    expect(config.summary, contains('Баланс split'));
    expect(
      config.arguments,
      contains('--wf-udp-out=443,19294-19344,50000-50100'),
    );
    expect(
      config.arguments,
      contains('--lua-desync=fakedsplit:pos=midsld+1:seqovl=1'),
    );
    expect(config.arguments, contains('--new=generic_tls'));
  });

  test('resolves winws2.exe from supported bundle layouts', () async {
    final tempDir = await Directory.systemTemp.createTemp('gorion-zapret-bin-');
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    final upstreamExe = File(
      p.join(tempDir.path, 'binaries', 'windows-x86_64', 'winws2.exe'),
    );
    await upstreamExe.parent.create(recursive: true);
    await upstreamExe.writeAsString('');

    expect(
      p.normalize(generator.resolveExecutablePath(tempDir.path)!),
      p.normalize(upstreamExe.path),
    );

    final nestedDir = Directory(p.join(tempDir.path, 'nfq2'));
    await nestedDir.create(recursive: true);
    final nestedExe = File(p.join(nestedDir.path, 'winws2.exe'));
    await nestedExe.writeAsString('');

    final rootExe = File(p.join(tempDir.path, 'winws2.exe'));
    await rootExe.writeAsString('');

    expect(generator.resolveExecutablePath(tempDir.path), rootExe.path);
  });
}
