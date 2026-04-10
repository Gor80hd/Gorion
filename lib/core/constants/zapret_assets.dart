import 'dart:ffi';

const zapretVersion = '0.9.4.7-gorion.4';

class ZapretAssetDescriptor {
  const ZapretAssetDescriptor({
    required this.assetPrefixes,
    required this.bundleKey,
    required this.relativeExecutablePath,
  });

  final List<String> assetPrefixes;
  final String bundleKey;
  final String relativeExecutablePath;
}

ZapretAssetDescriptor resolveZapretAsset() {
  final abi = Abi.current();
  return switch (abi) {
    Abi.windowsX64 => const ZapretAssetDescriptor(
      assetPrefixes: [
        'assets/zapret/common/',
        'assets/zapret/profiles/',
        'assets/zapret/windows/x64/',
      ],
      bundleKey: 'windows-x64',
      relativeExecutablePath: 'binaries/windows-x86_64/winws2.exe',
    ),
    Abi.windowsIA32 => const ZapretAssetDescriptor(
      assetPrefixes: [
        'assets/zapret/common/',
        'assets/zapret/profiles/',
        'assets/zapret/windows/x86/',
      ],
      bundleKey: 'windows-x86',
      relativeExecutablePath: 'binaries/windows-x86/winws2.exe',
    ),
    _ => throw UnsupportedError('No vendored zapret bundle for $abi'),
  };
}
