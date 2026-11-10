// Downloads the pinned sing-box binaries into assets/singbox/.
//
//   dart run tool/vendor_singbox.dart            # binaries for this host OS
//   dart run tool/vendor_singbox.dart --all      # every desktop platform
//   dart run tool/vendor_singbox.dart windows    # one named platform
//
// The binaries are not stored in git. Every extracted binary must match the
// SHA-256 pinned in tool/singbox.lock.json, otherwise it is discarded.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

Future<void> main(List<String> args) async {
  final repoRoot = File.fromUri(Platform.script).parent.parent;
  final lock =
      jsonDecode(
            await File('${repoRoot.path}/tool/singbox.lock.json').readAsString(),
          )
          as Map<String, dynamic>;
  final version = lock['version'] as String;
  final baseUrl = lock['releaseBaseUrl'] as String;
  final targets = (lock['targets'] as List).cast<Map<String, dynamic>>();

  final knownPlatforms = targets.map((t) => t['platform'] as String).toSet();
  final Set<String> wanted;
  if (args.contains('--all')) {
    wanted = knownPlatforms;
  } else if (args.isNotEmpty) {
    wanted = args.toSet();
    final unknown = wanted.difference(knownPlatforms);
    if (unknown.isNotEmpty) {
      stderr.writeln(
        'Unknown platform(s): ${unknown.join(', ')}. '
        'Known: ${knownPlatforms.join(', ')}.',
      );
      exit(64);
    }
  } else {
    wanted = {Platform.operatingSystem};
  }

  final temp = await Directory.systemTemp.createTemp('gorion-singbox-');
  try {
    for (final target in targets) {
      if (!wanted.contains(target['platform'])) continue;
      await _vendor(
        target: target,
        version: version,
        baseUrl: baseUrl,
        assetRoot: Directory('${repoRoot.path}/assets/singbox'),
        temp: temp,
      );
    }
  } finally {
    await temp.delete(recursive: true);
  }
}

Future<void> _vendor({
  required Map<String, dynamic> target,
  required String version,
  required String baseUrl,
  required Directory assetRoot,
  required Directory temp,
}) async {
  final output = target['output'] as String;
  final binaryName = target['binary'] as String;
  final expected = target['sha256'] as String;
  final destination = File('${assetRoot.path}/$output/$binaryName');

  if (await destination.exists() && await _sha256(destination) == expected) {
    stdout.writeln('ok       $output (already present)');
    return;
  }

  final archiveName = (target['archive'] as String).replaceAll(
    '{version}',
    version,
  );
  final archive = File('${temp.path}/$archiveName');
  stdout.writeln('download $archiveName');
  await _download(Uri.parse('$baseUrl/v$version/$archiveName'), archive);

  final extractDir = await Directory(
    '${temp.path}/${output.replaceAll('/', '-')}',
  ).create();
  await _extract(archive, extractDir);

  final extracted = await extractDir
      .list(recursive: true)
      .where((e) => e is File && e.uri.pathSegments.last == binaryName)
      .cast<File>()
      .first;
  final actual = await _sha256(extracted);
  if (actual != expected) {
    throw StateError(
      'SHA-256 mismatch for $output/$binaryName\n'
      '  expected $expected\n'
      '  actual   $actual\n'
      'If the pinned version changed on purpose, update tool/singbox.lock.json.',
    );
  }

  await destination.parent.create(recursive: true);
  await extracted.copy(destination.path);
  if (!Platform.isWindows) {
    await _run('chmod', ['755', destination.path]);
  }
  stdout.writeln('ok       $output');
}

Future<String> _sha256(File file) async {
  return (await sha256.bind(file.openRead()).first).toString();
}

Future<void> _download(Uri url, File destination) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(url);
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('HTTP ${response.statusCode}', uri: url);
    }
    await response.pipe(destination.openWrite());
  } finally {
    client.close();
  }
}

Future<void> _extract(File archive, Directory into) async {
  // bsdtar (macOS, Windows 10+) reads zip archives; GNU tar on Linux does not.
  if (archive.path.endsWith('.zip') && Platform.isLinux) {
    await _run('unzip', ['-q', archive.path, '-d', into.path]);
  } else {
    await _run('tar', ['-xf', archive.path, '-C', into.path]);
  }
}

Future<void> _run(String executable, List<String> arguments) async {
  final result = await Process.run(executable, arguments);
  if (result.exitCode != 0) {
    throw ProcessException(
      executable,
      arguments,
      result.stderr.toString(),
      result.exitCode,
    );
  }
}
