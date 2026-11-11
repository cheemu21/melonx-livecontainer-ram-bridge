#!/bin/bash
# Usage: patch_ipa.sh <input.ipa> <output.ipa> <empty work directory>
# Adds MeloNXDonorBridge.dylib to a LiveContainer IPA. The input file is never changed.
set -euo pipefail

[ $# -eq 3 ] || { echo "Usage: $0 <input.ipa> <output.ipa> <empty work directory>"; exit 1; }

INPUT="$1"
WORK="$3"
HERE="$(cd "$(dirname "$0")" && pwd)"

[ -f "$INPUT" ] || { echo "No such IPA: $INPUT"; exit 1; }
[ -d "$(dirname "$2")" ] || { echo "No such folder for the output: $(dirname "$2")"; exit 1; }

# The zip step runs from inside the work directory, so the output path must be absolute.
OUTPUT="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
[ ! -e "$OUTPUT" ] || { echo "Refusing to overwrite $OUTPUT"; exit 1; }

mkdir -p "$WORK"
[ -z "$(ls -A "$WORK")" ] || { echo "Work directory isn't empty: $WORK"; exit 1; }

unzip -q "$INPUT" -d "$WORK"
APP="$WORK/Payload/LiveContainer.app"
SHARED="$APP/Frameworks/LiveContainerShared.framework"
BRIDGE="$APP/Frameworks/MeloNXDonorBridge.dylib"

xcrun --sdk iphoneos clang -target arm64-apple-ios15.0 -fobjc-arc -O2 -fvisibility=hidden \
    -dynamiclib -framework Foundation -Wall -Wextra -Wno-unused-parameter \
    -install_name @rpath/MeloNXDonorBridge.dylib \
    "$HERE/MeloNXDonorBridge.m" -o "$BRIDGE"

# LiveContainerShared loads from the real app bundle at launch, in both the app and LiveProcess.
# TweakLoader won't do: guests load it through a symlink in Documents/Tweaks, and LiveContainer
# points @executable_path at the guest.
python3 -I "$HERE/add_weak_dylib.py" "$SHARED/LiveContainerShared" "@loader_path/../MeloNXDonorBridge.dylib"

# Sideloading replaces these signatures. These just keep the bundle valid until then.
codesign -f -s - "$BRIDGE"
codesign -f -s - --preserve-metadata=entitlements,flags "$SHARED"
codesign -f -s - --preserve-metadata=entitlements,flags "$APP"

(cd "$WORK" && zip -q -r -y -X "$OUTPUT" Payload $(ls -A | grep -v '^Payload$' || true))
echo "Wrote $OUTPUT"
