import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gorion_clean/features/zapret/data/zapret_runtime_support.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('stages legacy bin and lists layout for zapret runtime', () async {
    final bundleDir = await Directory.systemTemp.createTemp(
      'gorion-zapret-runtime-',
    );
    addTearDown(() => bundleDir.delete(recursive: true));

    Future<void> touch(String relativePath, {String contents = ''}) async {
      final file = File(
        p.joinAll([bundleDir.path, ...relativePath.split('/')]),
      );
      await file.parent.create(recursive: true);
      await file.writeAsString(contents);
    }

    await touch('binaries/windows-x86_64/winws2.exe', contents: 'winws2');
    await touch('binaries/windows-x86_64/cygwin1.dll', contents: 'dll');
    await touch('files/fake/stun.bin', contents: 'fake');
    await touch('files/list-general.txt', contents: 'list');

    await ensureLegacyBatchCompatibilityLayout(
      bundleDir: bundleDir,
      relativeExecutablePath: 'binaries/windows-x86_64/winws2.exe',
    );

    expect(
      File(p.join(bundleDir.path, 'bin', 'winws.exe')).readAsStringSync(),
      'winws2',
    );
    expect(
      File(p.join(bundleDir.path, 'bin', 'winws2.exe')).readAsStringSync(),
      'winws2',
    );
    expect(
      File(p.join(bundleDir.path, 'bin', 'cygwin1.dll')).readAsStringSync(),
      'dll',
    );
    expect(
      File(p.join(bundleDir.path, 'bin', 'stun.bin')).readAsStringSync(),
      'fake',
    );
    expect(
      File(
        p.join(bundleDir.path, 'lists', 'list-general.txt'),
      ).readAsStringSync(),
      'list',
    );
  });

  test('copies bundled profile configs into install directory', () async {
    final installDir = await Directory.systemTemp.createTemp(
      'gorion-zapret-profiles-',
    );
    addTearDown(() => installDir.delete(recursive: true));

    await ensureBundledSupportLayout(installDir.path);

    expect(
      File(
        p.join(installDir.path, 'profiles', 'general.conf'),
      ).readAsStringSync(),
      contains('--wf-tcp=80,443,2053,2083,2087,2096,8443,%GameFilterTCP%'),
    );
    expect(
      File(
        p.join(installDir.path, 'profiles', 'general (ALT6).conf'),
      ).readAsStringSync(),
      contains('--dpi-desync-autottl=2'),
    );
    expect(
      File(
        p.join(installDir.path, 'files', 'fake', 'tls_clienthello_4pda_to.bin'),
      ).existsSync(),
      isTrue,
    );
    expect(
      File(
        p.join(
          installDir.path,
          'files',
          'fake',
          'quic_initial_www_google_com.bin',
        ),
      ).existsSync(),
      isTrue,
    );
    expect(
      File(p.join(installDir.path, 'lua', 'zapret-lib.lua')).existsSync(),
      isTrue,
    );
    expect(
      File(p.join(installDir.path, 'lua', 'zapret-antidpi.lua')).existsSync(),
      isTrue,
    );
  });
}
