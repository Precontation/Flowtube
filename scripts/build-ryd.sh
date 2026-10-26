#!/usr/bin/env bash
# Builds Return YouTube Dislike (github.com/PoomSmart/Return-YouTube-Dislikes, GPL-3.0) as a
# sideload dylib that needs no Substrate or ElleKit: its Logos hooks are generated with Logos's
# `internal` generator (plain Objective-C runtime swaps), like FlowTube's and YTKACE's.
#
# Output: dist/YouTubeDislikesReturn.dylib and dist/RYD.bundle.
# macOS needs Xcode; Linux needs clang + lld and an iPhoneOS SDK in $SDKROOT.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$ROOT/dist/ryd-build"
OUT="$ROOT/dist"
RYD_REF="${RYD_REF:-main}"
MIN_IOS=15.0

if [[ "$(uname)" == "Darwin" ]]; then
  SDKROOT="${SDKROOT:-$(xcrun --sdk iphoneos --show-sdk-path)}"
  CC=(xcrun --sdk iphoneos clang)
  LINK_FLAGS=()
else
  : "${SDKROOT:?set SDKROOT to an iPhoneOS SDK}"
  CC=(clang)
  LINK_FLAGS=(-fuse-ld=lld)
fi

rm -rf "$WORK"
mkdir -p "$WORK/inc"
clone() { git clone -q --depth 1 ${3:+--branch "$3"} "https://github.com/$1" "$2"; }
clone PoomSmart/Return-YouTube-Dislikes "$WORK/ryd" "$RYD_REF"
clone PoomSmart/YouTubeHeader "$WORK/inc/YouTubeHeader"
clone PoomSmart/PSHeader "$WORK/inc/PSHeader"
# Theos: Logos and its vendored headers only (no toolchain).
git clone -q --depth 1 --recurse-submodules --shallow-submodules https://github.com/theos/theos "$WORK/theos"
THEOS="$WORK/theos"

cd "$WORK/ryd"
API_URL='"https://returnyoutubedislikeapi.com"'
for source in Settings TweakSettings API Vote Tweak; do
  perl "$THEOS/vendor/logos/bin/logos.pl" -c generator=internal "$source.x" > "$WORK/$source.m"
  "${CC[@]}" -target arm64-apple-ios$MIN_IOS -isysroot "$SDKROOT" -fobjc-arc -fmodules -O2 -w \
    -I . -I "$WORK/inc" -I "$THEOS/vendor/include" -F "$THEOS/vendor/lib" -include "$THEOS/Prefix.pch" \
    -DAPI_URL="$API_URL" -DTWEAK_NAME='"Return YouTube Dislike"' \
    -c "$WORK/$source.m" -o "$WORK/$source.o"
done
"${CC[@]}" -target arm64-apple-ios$MIN_IOS -isysroot "$SDKROOT" -O2 -c "$ROOT/scripts/ryd/libroot_stub.c" -o "$WORK/libroot_stub.o"
"${CC[@]}" -target arm64-apple-ios$MIN_IOS -isysroot "$SDKROOT" ${LINK_FLAGS[@]+"${LINK_FLAGS[@]}"} -dynamiclib \
  -o "$OUT/YouTubeDislikesReturn.dylib" "$WORK"/*.o \
  -framework Foundation -framework UIKit -framework CoreGraphics -framework QuartzCore \
  -Wl,-install_name,@rpath/YouTubeDislikesReturn.dylib -Wl,-dead_strip

# Substrate must not be needed: fail the build if anything still asks for it.
if command -v llvm-nm >/dev/null 2>&1; then NM=llvm-nm; else NM=nm; fi
if "$NM" -u "$OUT/YouTubeDislikesReturn.dylib" | grep -E '_MS[A-Z]|libroot|substrate'; then
  echo "Return YouTube Dislike still references Substrate/libroot" >&2
  exit 1
fi
rm -rf "$OUT/RYD.bundle"
cp -R "layout/Library/Application Support/RYD.bundle" "$OUT/RYD.bundle"
rm -rf "$WORK"
ls -la "$OUT/YouTubeDislikesReturn.dylib"
