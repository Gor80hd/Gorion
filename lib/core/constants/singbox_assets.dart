import 'dart:ffi';

const singboxVersion = '1.13.5';

class SingboxAssetDescriptor {
  const SingboxAssetDescriptor({
    required this.assetPath,
    required this.fileName,
  });

  final String assetPath;
  final String fileName;
}

SingboxAssetDescriptor resolveSingboxAsset() {
  final abi = Abi.current();
  return switch (abi) {
    Abi.windowsX64 => const SingboxAssetDescriptor(
      assetPath: 'assets/singbox/windows/x64/sing-box.exe',
      fileName: 'sing-box.exe',
    ),
    Abi.windowsArm64 => const SingboxAssetDescriptor(
      assetPath: 'assets/singbox/windows/arm64/sing-box.exe',
      fileName: 'sing-box.exe',
    ),
    Abi.windowsIA32 => const SingboxAssetDescriptor(
      assetPath: 'assets/singbox/windows/x86/sing-box.exe',
      fileName: 'sing-box.exe',
    ),
    Abi.linuxX64 => const SingboxAssetDescriptor(
      assetPath: 'assets/singbox/linux/x64/sing-box',
      fileName: 'sing-box',
    ),
    Abi.linuxArm64 => const SingboxAssetDescriptor(
      assetPath: 'assets/singbox/linux/arm64/sing-box',
      fileName: 'sing-box',
    ),
    Abi.macosX64 => const SingboxAssetDescriptor(
      assetPath: 'assets/singbox/macos/x64/sing-box',
      fileName: 'sing-box',
    ),
    Abi.macosArm64 => const SingboxAssetDescriptor(
      assetPath: 'assets/singbox/macos/arm64/sing-box',
      fileName: 'sing-box',
    ),
    Abi.androidArm => const SingboxAssetDescriptor(
      assetPath: 'assets/singbox/android/armeabi-v7a/sing-box',
      fileName: 'sing-box',
    ),
    Abi.androidArm64 => const SingboxAssetDescriptor(
      assetPath: 'assets/singbox/android/arm64-v8a/sing-box',
      fileName: 'sing-box',
    ),
    Abi.androidIA32 => const SingboxAssetDescriptor(
      assetPath: 'assets/singbox/android/x86/sing-box',
      fileName: 'sing-box',
    ),
    Abi.androidX64 => const SingboxAssetDescriptor(
      assetPath: 'assets/singbox/android/x86_64/sing-box',
      fileName: 'sing-box',
    ),
    _ => throw UnsupportedError('No vendored sing-box binary for $abi'),
  };
}