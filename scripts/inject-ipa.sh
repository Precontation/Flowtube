#!/usr/bin/env bash
# Adds FlowTube (and optionally Return YouTube Dislike) to a YouTube IPA: YTKACE, YTPlusM,
# YTLitePlus or plain decrypted YouTube. Each dylib is copied into the app's Frameworks and gets a
# load command in the main binary; resource bundles go into the app. Everything is re-signed ad
# hoc and re-zipped; sideloaders (AltStore, SideStore, Feather, TrollStore) sign it again.
#
#   scripts/inject-ipa.sh input.ipa output.ipa Some.dylib [Other.dylib ...] [--resource RYD.bundle ...]
#
# A dylib the IPA already loads (by name, or Return YouTube Dislike under any name) is skipped,
# so nothing is ever loaded twice.
set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "usage: inject-ipa.sh input.ipa output.ipa Some.dylib [Other.dylib ...] [--resource Bundle ...]" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
absolute() { python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$1"; }
INPUT="$(absolute "$1")"
OUTPUT="$(absolute "$2")"
shift 2
DYLIBS=()
RESOURCES=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --resource) RESOURCES+=("$(absolute "$2")"); shift 2 ;;
    *) DYLIBS+=("$(absolute "$1")"); shift ;;
  esac
done
LDID="${LDID:-ldid}"
INJECT="$ROOT/tools/macho_inject.py"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

unzip -q "$INPUT" -d "$WORK"
APP="$(find "$WORK/Payload" -mindepth 1 -maxdepth 1 -type d -name '*.app' -print -quit)"
[[ -n "$APP" ]] || { echo "no .app in $INPUT" >&2; exit 1; }
EXECUTABLE="$(python3 -c 'import plistlib,sys; print(plistlib.load(open(sys.argv[1],"rb"))["CFBundleExecutable"])' "$APP/Info.plist")"
MAIN="$APP/$EXECUTABLE"
mkdir -p "$APP/Frameworks"

loaded() { python3 "$INJECT" "$MAIN" --list 2>/dev/null || true; }

for dylib in ${DYLIBS[@]+"${DYLIBS[@]}"}; do
  name="$(basename "$dylib")"
  if [[ "$name" == *Dislike* ]] && { loaded | grep -qi 'dislike' || ls "$APP/Frameworks" 2>/dev/null | grep -qi 'dislike'; }; then
    echo "skipping $name: this IPA already has Return YouTube Dislike"
    continue
  fi
  # Re-injecting replaces an older copy rather than loading two.
  python3 "$INJECT" "$MAIN" --remove-load "@rpath/$name" >/dev/null 2>&1 || true
  python3 "$INJECT" "$MAIN" --add-load "@rpath/$name"
  cp "$dylib" "$APP/Frameworks/$name"
  if command -v "$LDID" >/dev/null 2>&1; then "$LDID" -S "$APP/Frameworks/$name"; fi
  echo "added $name"
done

for resource in ${RESOURCES[@]+"${RESOURCES[@]}"}; do
  rm -rf "$APP/$(basename "$resource")"
  cp -R "$resource" "$APP/"
  echo "added $(basename "$resource")"
done

echo "Load commands now:"
loaded | grep -iE 'flowtube|dislike|ytkace|ytlite|ytplus' || true

if command -v "$LDID" >/dev/null 2>&1; then
  ENTITLEMENTS="$WORK/entitlements.plist"
  "$LDID" -e "$MAIN" >"$ENTITLEMENTS" 2>/dev/null || true
  if [[ -s "$ENTITLEMENTS" ]]; then "$LDID" "-S$ENTITLEMENTS" "$MAIN"; else "$LDID" -S "$MAIN"; fi
else
  echo "ldid not found: leaving signatures to the sideloader" >&2
fi
rm -rf "$APP/_CodeSignature"

rm -f "$OUTPUT"
(cd "$WORK" && zip -qry "$OUTPUT" Payload)
echo "$OUTPUT"
