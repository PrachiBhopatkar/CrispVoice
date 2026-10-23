#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="$ROOT_DIR/vendor/BedrockSDKBridge"
OUT_DIR="$ROOT_DIR/vendor/lib"

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR/BedrockSDKBridge.swiftmodule"

for ARCH in arm64 x86_64; do
  echo "Building BedrockSDKBridge for $ARCH..."
  swift build \
    --package-path "$PACKAGE_DIR" \
    -c release \
    --arch "$ARCH"
done

lipo -create \
  -output "$OUT_DIR/libBedrockSDKBridge.a" \
  "$PACKAGE_DIR/.build/arm64-apple-macosx/release/libBedrockSDKBridge.a" \
  "$PACKAGE_DIR/.build/x86_64-apple-macosx/release/libBedrockSDKBridge.a"

cp "$PACKAGE_DIR/.build/arm64-apple-macosx/release/Modules/BedrockSDKBridge.swiftmodule" \
   "$OUT_DIR/BedrockSDKBridge.swiftmodule/arm64-apple-macos.swiftmodule"
cp "$PACKAGE_DIR/.build/x86_64-apple-macosx/release/Modules/BedrockSDKBridge.swiftmodule" \
   "$OUT_DIR/BedrockSDKBridge.swiftmodule/x86_64-apple-macos.swiftmodule"

lipo -archs "$OUT_DIR/libBedrockSDKBridge.a"
echo "vendor/lib/libBedrockSDKBridge.a and BedrockSDKBridge.swiftmodule are up to date."
