import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gorion_clean/features/zapret/data/zapret_config_generator.dart';
import 'package:gorion_clean/features/zapret/model/zapret_models.dart';
import 'package:gorion_clean/features/zapret/model/zapret_settings.dart';
import 'package:path/path.dart' as p;

void main() {
  const generator = ZapretConfigGenerator();

  test('lists config files with the same names and natural order', () async {
    final packageDir = await _createZapretPackage();
    addTearDown(() => packageDir.delete(recursive: true));

    await _writeConfig(packageDir, 'general (ALT10).conf', _sampleConfigBody());
    await _writeConfig(packageDir, 'general (ALT2).conf', _sampleConfigBody());
    await _writeConfig(packageDir, 'general (ALT).conf', _sampleConfigBody());

    final profiles = generator.listAvailableProfiles(packageDir.path);

    expect(profiles.map((profile) => profile.fileName), [
      'general.conf',
      'general (ALT).conf',
      'general (ALT2).conf',
      'general (ALT10).conf',
    ]);
  });

  test(
    'builds launch args from selected general.conf with explicit disabled game filter',
    () async {
      final packageDir = await _createZapretPackage();
      addTearDown(() => packageDir.delete(recursive: true));

      final configuration = generator.build(
        ZapretSettings(
          installDirectory: packageDir.path,
          configFileName: 'general.conf',
          gameFilterMode: ZapretGameFilterMode.disabled,
        ),
      );

      expect(
        configuration.executablePath,
        p.join(packageDir.path, 'binaries', 'windows-x86_64', 'winws2.exe'),
      );
      expect(
        configuration.workingDirectory,
        p.join(packageDir.path, 'binaries', 'windows-x86_64'),
      );
      expect(configuration.summary, 'general');
      expect(configuration.arguments, contains('--wf-tcp-out=80,443'));
      expect(configuration.arguments, contains('--wf-udp-out=443'));
      expect(configuration.arguments, contains('--payload=quic_initial'));
      expect(
        configuration.arguments,
        contains(
          '--lua-init=@${p.join(packageDir.path, 'lua', 'zapret-lib.lua')}',
        ),
      );
      expect(
        configuration.arguments,
        contains(
          '--hostlist=${p.join(packageDir.path, 'files', 'list-general.txt')}',
        ),
      );
      expect(
        configuration.requiredFiles,
        contains(p.join(packageDir.path, 'files', 'list-general-user.txt')),
      );
      expect(
        configuration.requiredFiles,
        contains(p.join(packageDir.path, 'lua', 'zapret-antidpi.lua')),
      );
    },
  );

  test(
    'applies the same service.bat game filter modes to TCP and UDP placeholders',
    () async {
      final packageDir = await _createZapretPackage();
      addTearDown(() => packageDir.delete(recursive: true));

      final tcpOnly = generator.build(
        ZapretSettings(
          installDirectory: packageDir.path,
          gameFilterMode: ZapretGameFilterMode.tcp,
        ),
      );
      final udpOnly = generator.build(
        ZapretSettings(
          installDirectory: packageDir.path,
          gameFilterMode: ZapretGameFilterMode.udp,
        ),
      );
      final allTraffic = generator.build(
        ZapretSettings(
          installDirectory: packageDir.path,
          gameFilterMode: ZapretGameFilterMode.all,
        ),
      );

      expect(tcpOnly.arguments, contains('--wf-tcp-out=80,443,1024-65535'));
      expect(tcpOnly.arguments, contains('--wf-udp-out=443'));
      expect(udpOnly.arguments, contains('--wf-tcp-out=80,443'));
      expect(udpOnly.arguments, contains('--wf-udp-out=443,1024-65535'));
      expect(allTraffic.arguments, contains('--wf-tcp-out=80,443,1024-65535'));
      expect(allTraffic.arguments, contains('--wf-udp-out=443,1024-65535'));
    },
  );

  test('keeps game filter ports inert when IPSet mode is disabled', () async {
    final packageDir = await _createZapretPackage();
    addTearDown(() => packageDir.delete(recursive: true));

    final configuration = generator.build(
      ZapretSettings(
        installDirectory: packageDir.path,
        gameFilterMode: ZapretGameFilterMode.all,
        ipSetFilterMode: ZapretIpSetFilterMode.none,
      ),
    );

    expect(configuration.arguments, contains('--wf-tcp-out=80,443,1024-65535'));
    expect(configuration.arguments, contains('--wf-udp-out=443,1024-65535'));
    expect(configuration.arguments, isNot(contains(contains('ipset-all.txt'))));
    expect(configuration.arguments, contains('--ipset-ip=203.0.113.113/32'));
  });

  test('keeps ipset-all when IPSet mode is enabled', () async {
    final packageDir = await _createZapretPackage();
    addTearDown(() => packageDir.delete(recursive: true));

    final configuration = generator.build(
      ZapretSettings(
        installDirectory: packageDir.path,
        gameFilterMode: ZapretGameFilterMode.all,
        ipSetFilterMode: ZapretIpSetFilterMode.any,
      ),
    );

    expect(
      configuration.arguments,
      contains('--ipset=${p.join(packageDir.path, 'files', 'ipset-all.txt')}'),
    );
    expect(
      configuration.arguments,
      isNot(contains('--ipset-ip=203.0.113.113/32')),
    );
  });

  test(
    'translates legacy split2 badseq strategy into winws2 multisplit',
    () async {
      final packageDir = await _createZapretPackage();
      addTearDown(() => packageDir.delete(recursive: true));

      await _writeConfig(packageDir, 'general (ALT2).conf', '''
--wf-tcp=443
--filter-tcp=443 --hostlist="%LISTS%list-google.txt" --dpi-desync=split2 --dpi-desync-split-pos=1,midsld --dpi-desync-fooling=badseq
''');

      final configuration = generator.build(
        ZapretSettings(
          installDirectory: packageDir.path,
          configFileName: 'general (ALT2).conf',
        ),
      );

      expect(configuration.arguments, contains('--filter-l7=tls'));
      expect(configuration.arguments, contains('--payload=tls_client_hello'));
      expect(
        configuration.arguments,
        contains(
          '--lua-desync=multisplit:tcp_seq=-10000:tcp_ack=-66000:pos=1,midsld',
        ),
      );
    },
  );

  test(
    'creates missing companion user lists just like service.bat load_user_lists',
    () async {
      final packageDir = await _createZapretPackage(createUserLists: false);
      addTearDown(() => packageDir.delete(recursive: true));

      final filesIpSetAll = File(
        p.join(packageDir.path, 'files', 'ipset-all.txt'),
      );
      if (filesIpSetAll.existsSync()) {
        filesIpSetAll.deleteSync();
      }

      generator.build(
        ZapretSettings(
          installDirectory: packageDir.path,
          configFileName: 'general.conf',
        ),
      );

      expect(
        File(
          p.join(packageDir.path, 'lists', 'list-general-user.txt'),
        ).existsSync(),
        isTrue,
      );
      expect(
        File(
          p.join(packageDir.path, 'lists', 'list-exclude-user.txt'),
        ).existsSync(),
        isTrue,
      );
      expect(
        File(
          p.join(packageDir.path, 'lists', 'ipset-exclude-user.txt'),
        ).existsSync(),
        isTrue,
      );
      expect(
        File(p.join(packageDir.path, 'lists', 'ipset-all.txt')).existsSync(),
        isTrue,
      );
      expect(
        File(
          p.join(packageDir.path, 'files', 'ipset-exclude-user.txt'),
        ).existsSync(),
        isTrue,
      );
      expect(
        File(p.join(packageDir.path, 'files', 'ipset-all.txt')).existsSync(),
        isTrue,
      );
      expect(
        File(
          p.join(packageDir.path, 'files', 'ipset-all.txt'),
        ).readAsStringSync(),
        contains('0.0.0.0/0'),
      );
    },
  );

  test(
    'uses canonical files/fake and files directories for .conf profiles',
    () async {
      final packageDir = await Directory.systemTemp.createTemp(
        'gorion-zapret-canonical-',
      );
      addTearDown(() => packageDir.delete(recursive: true));

      Future<void> touch(String relativePath, {String contents = ''}) async {
        final file = File(
          p.joinAll([packageDir.path, ...relativePath.split('/')]),
        );
        await file.parent.create(recursive: true);
        await file.writeAsString(contents);
      }

      await touch('binaries/windows-x86_64/winws2.exe');
      await touch('files/fake/quic_initial_www_google_com.bin');
      await touch('files/list-general.txt');
      await touch('files/list-exclude.txt');
      await touch('files/ipset-all.txt');
      await touch('files/ipset-exclude.txt');
      await _writeConfig(packageDir, 'general.conf', _sampleConfigBody());

      final configuration = generator.build(
        ZapretSettings(
          installDirectory: packageDir.path,
          configFileName: 'general.conf',
        ),
      );

      expect(
        configuration.arguments,
        contains(
          '--hostlist=${p.join(packageDir.path, 'files', 'list-general.txt')}',
        ),
      );
      expect(
        configuration.arguments,
        contains(
          '--blob=quic_initial_www_google_com:@${p.join(packageDir.path, 'files', 'fake', 'quic_initial_www_google_com.bin')}',
        ),
      );
      expect(
        configuration.arguments,
        contains(
          '--lua-desync=fake:blob=quic_initial_www_google_com:repeats=6',
        ),
      );
    },
  );

  test('prefers winws2 and keeps legacy winws.exe only as fallback', () async {
    final packageDir = await Directory.systemTemp.createTemp(
      'gorion-zapret-exe-',
    );
    addTearDown(() => packageDir.delete(recursive: true));

    final fallbackWinws2 = File(
      p.join(packageDir.path, 'binaries', 'windows-x86_64', 'winws2.exe'),
    );
    await fallbackWinws2.parent.create(recursive: true);
    await fallbackWinws2.writeAsString('');

    expect(
      generator.resolveExecutablePath(packageDir.path),
      fallbackWinws2.path,
    );

    final preferredWinws = File(p.join(packageDir.path, 'bin', 'winws.exe'));
    await preferredWinws.parent.create(recursive: true);
    await preferredWinws.writeAsString('');

    expect(
      generator.resolveExecutablePath(packageDir.path),
      fallbackWinws2.path,
    );
  });

  test('legacy .bat launch always uses bundled winws executable', () async {
    final packageDir = await _createZapretPackage();
    addTearDown(() => packageDir.delete(recursive: true));

    await _writeConfig(packageDir, 'legacy.bat', '''
start "" /min "C:\\Temp\\evil.exe" --hostlist="%LISTS%list-general.txt" --comment=winws.exe
''');

    final configuration = generator.build(
      ZapretSettings(
        installDirectory: packageDir.path,
        configFileName: 'legacy.bat',
      ),
    );

    expect(
      configuration.executablePath,
      p.join(packageDir.path, 'binaries', 'windows-x86_64', 'winws2.exe'),
    );
    expect(configuration.executablePath, isNot(contains('evil.exe')));
    expect(configuration.requiredFiles, isNot(contains('C:\\Temp\\evil.exe')));
  });

  test('normalizes legacy .bat name to matching .conf profile', () async {
    final packageDir = await _createZapretPackage();
    addTearDown(() => packageDir.delete(recursive: true));

    expect(
      generator.resolveSelectedConfigFileName(packageDir.path, 'general.bat'),
      'general.conf',
    );
    expect(
      generator.resolveSelectedConfigFileName(
        packageDir.path,
        'general (ALT10).bat',
      ),
      'general.conf',
    );
  });
}

Future<Directory> _createZapretPackage({bool createUserLists = true}) async {
  final root = await Directory.systemTemp.createTemp('gorion-zapret-package-');

  Future<void> touch(String relativePath, {String contents = ''}) async {
    final file = File(p.joinAll([root.path, ...relativePath.split('/')]));
    await file.parent.create(recursive: true);
    await file.writeAsString(contents);
  }

  await touch('binaries/windows-x86_64/winws2.exe');
  await touch('lua/zapret-lib.lua');
  await touch('lua/zapret-antidpi.lua');
  await touch('files/fake/quic_initial_www_google_com.bin');
  await touch('files/fake/tls_clienthello_4pda_to.bin');
  await touch('files/fake/tls_clienthello_max_ru.bin');
  await touch('files/fake/tls_clienthello_www_google_com.bin');
  await touch('files/fake/stun.bin');
  await touch('files/list-general.txt');
  await touch('files/list-exclude.txt');
  await touch('files/ipset-all.txt');
  await touch('files/ipset-exclude.txt');
  if (createUserLists) {
    await touch('files/list-general-user.txt');
    await touch('files/list-exclude-user.txt');
    await touch('files/ipset-exclude-user.txt');
  }
  await _writeConfig(root, 'general.conf', _sampleConfigBody());

  return root;
}

Future<void> _writeConfig(Directory root, String fileName, String body) async {
  final file = File(p.join(root.path, 'profiles', fileName));
  await file.parent.create(recursive: true);
  await file.writeAsString(body);
}

String _sampleConfigBody() {
  return '''
--wf-tcp=80,443,%GameFilterTCP% --wf-udp=443,%GameFilterUDP%
--filter-udp=443 --hostlist="%LISTS%list-general.txt" --hostlist="%LISTS%list-general-user.txt" --hostlist-exclude="%LISTS%list-exclude.txt" --hostlist-exclude="%LISTS%list-exclude-user.txt" --ipset="%LISTS%ipset-all.txt" --ipset-exclude="%LISTS%ipset-exclude.txt" --ipset-exclude="%LISTS%ipset-exclude-user.txt" --dpi-desync=fake --dpi-desync-repeats=6 --dpi-desync-fake-quic="%BIN%quic_initial_www_google_com.bin"
''';
}
