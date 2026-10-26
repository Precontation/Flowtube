#!/usr/bin/env bash
# Builds dist/FlowTube.dylib: the Rust core for aarch64-apple-ios, then the Objective-C tweak,
# linked into one dylib. No Theos needed.
#
#   macOS: needs Xcode and `rustup target add aarch64-apple-ios`.
#   Linux: needs clang + lld and an iPhoneOS SDK in $SDKROOT (github.com/theos/sdks); the Rust
#          standard library is built from source (rust-src) when the target isn't installed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/dist"
OBJ="$OUT/obj"
MIN_IOS=15.0
mkdir -p "$OBJ"

if [[ "$(uname)" == "Darwin" ]]; then
  SDKROOT="${SDKROOT:-$(xcrun --sdk iphoneos --show-sdk-path)}"
  CC=(xcrun --sdk iphoneos clang)
  LINK_FLAGS=()
else
  : "${SDKROOT:?set SDKROOT to an iPhoneOS SDK}"
  CC=(clang)
  LINK_FLAGS=(-fuse-ld=lld)
fi
export SDKROOT IPHONEOS_DEPLOYMENT_TARGET=$MIN_IOS

echo "==> Rust core"
cd "$ROOT/core"
if rustup target list --installed 2>/dev/null | grep -q aarch64-apple-ios; then
  cargo build --release --target aarch64-apple-ios
else
  RUSTC_BOOTSTRAP=1 cargo build --release --target aarch64-apple-ios -Zbuild-std=std,panic_unwind
fi
CORE="$ROOT/core/target/aarch64-apple-ios/release/libflowneuro_core.a"

echo "==> Tweak"
cd "$ROOT/tweak"
for source in Sources/*.m; do
  "${CC[@]}" -target arm64-apple-ios$MIN_IOS -isysroot "$SDKROOT" -fobjc-arc -O2 \
    -Wall -Wextra -Wno-unused-parameter -Werror=return-type \
    -I "$ROOT/core/include" -c "$source" -o "$OBJ/$(basename "$source" .m).o"
done
"${CC[@]}" -target arm64-apple-ios$MIN_IOS -isysroot "$SDKROOT" ${LINK_FLAGS[@]+"${LINK_FLAGS[@]}"} -dynamiclib \
  -o "$OUT/FlowTube.dylib" "$OBJ"/*.o "$CORE" \
  -framework Foundation -framework UIKit -framework CoreFoundation -framework CoreGraphics \
  -framework QuartzCore -framework UniformTypeIdentifiers \
  -Wl,-install_name,@rpath/FlowTube.dylib -Wl,-dead_strip -Wl,-x
if command -v llvm-strip >/dev/null 2>&1; then
  llvm-strip -x "$OUT/FlowTube.dylib" || true
elif [[ "$(uname)" == "Darwin" ]]; then
  xcrun strip -x "$OUT/FlowTube.dylib" || true
fi
rm -rf "$OBJ"
ls -la "$OUT/FlowTube.dylib"
