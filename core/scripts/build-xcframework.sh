#!/usr/bin/env bash
# Собирает ядро для macOS (arm64 + x86_64) в XCFramework и генерирует
# Swift-привязки UniFFI для пакета GorionKit.
#
#   core/scripts/build-xcframework.sh [debug|release]
#
# Результат (в git не попадает):
#   apps/macos/Packages/GorionKit/Frameworks/GorionCoreFFI.xcframework
#   apps/macos/Packages/GorionKit/Sources/GorionCoreFFI/gorion_ffi.swift
#   apps/macos/build/helper/gorion-helper — помощник для режима TUN (ADR-0005)
set -euo pipefail

PROFILE="${1:-release}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CORE="$ROOT/core"
KIT="$ROOT/apps/macos/Packages/GorionKit"
OUT_FRAMEWORK="$KIT/Frameworks/GorionCoreFFI.xcframework"
OUT_SWIFT="$KIT/Sources/GorionCoreFFI"
WORK="$CORE/target/xcframework"

# rustup из Homebrew не кладёт cargo в PATH.
if ! command -v cargo >/dev/null 2>&1 && [ -x /opt/homebrew/opt/rustup/bin/cargo ]; then
  export PATH="/opt/homebrew/opt/rustup/bin:$PATH"
fi

# Минимальная версия совпадает с приложением (ADR-0002).
export MACOSX_DEPLOYMENT_TARGET=26.0

CARGO_FLAGS=(--manifest-path "$CORE/Cargo.toml" -p gorion-ffi --lib)
if [ "$PROFILE" = "release" ]; then
  CARGO_FLAGS+=(--release)
fi

TARGETS=(aarch64-apple-darwin x86_64-apple-darwin)
HELPER_FLAGS=(--manifest-path "$CORE/Cargo.toml" -p gorion-helper --bin gorion-helper)
if [ "$PROFILE" = "release" ]; then
  HELPER_FLAGS+=(--release)
fi
for target in "${TARGETS[@]}"; do
  cargo build "${CARGO_FLAGS[@]}" --target "$target"
  cargo build "${HELPER_FLAGS[@]}" --target "$target"
done

# Помощник — универсальный бинарник, его кладёт в приложение сборка Xcode.
OUT_HELPER="$ROOT/apps/macos/build/helper"
mkdir -p "$OUT_HELPER"
HELPERS=()
for target in "${TARGETS[@]}"; do
  HELPERS+=("$CORE/target/$target/$PROFILE/gorion-helper")
done
lipo -create "${HELPERS[@]}" -output "$OUT_HELPER/gorion-helper"

rm -rf "$WORK"
mkdir -p "$WORK/headers" "$WORK/swift"

LIBS=()
for target in "${TARGETS[@]}"; do
  LIBS+=("$CORE/target/$target/$PROFILE/libgorion_ffi.a")
done
lipo -create "${LIBS[@]}" -output "$WORK/libgorion_ffi.a"

# Привязки по метаданным из собранной библиотеки.
(cd "$CORE" && cargo run -p gorion-ffi --features bindgen --bin uniffi-bindgen -- \
  generate --library "${LIBS[0]}" --language swift --out-dir "$WORK/swift")

cp "$WORK/swift/gorion_ffiFFI.h" "$WORK/headers/"
cp "$WORK/swift/gorion_ffiFFI.modulemap" "$WORK/headers/module.modulemap"

rm -rf "$OUT_FRAMEWORK"
mkdir -p "$(dirname "$OUT_FRAMEWORK")" "$OUT_SWIFT"
xcodebuild -create-xcframework \
  -library "$WORK/libgorion_ffi.a" -headers "$WORK/headers" \
  -output "$OUT_FRAMEWORK" >/dev/null

cp "$WORK/swift/gorion_ffi.swift" "$OUT_SWIFT/gorion_ffi.swift"
echo "XCFramework: $OUT_FRAMEWORK"
echo "Swift:       $OUT_SWIFT/gorion_ffi.swift"
echo "Помощник:    $OUT_HELPER/gorion-helper"
