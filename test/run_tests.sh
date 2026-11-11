#!/bin/bash
# Builds the bridge for macOS and runs MeloNX's real MLXRamDonor.m against it.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

APP="$BUILD/App.app"
mkdir -p "$APP/Frameworks" "$APP/PlugIns/LiveProcess.appex"

# The bridge finds LiveProcess's identifier relative to itself, as it does inside LiveContainer.
plutil -create xml1 "$APP/PlugIns/LiveProcess.appex/Info.plist"
plutil -insert CFBundleIdentifier -string com.test.livecontainer.LiveProcess "$APP/PlugIns/LiveProcess.appex/Info.plist"

SDK="$(xcrun --sdk macosx --show-sdk-path)"

xcrun clang -isysroot "$SDK" -fobjc-arc -DMLX_BRIDGE_TEST -dynamiclib -Wall -Wno-unused-parameter \
    -framework Foundation -install_name @rpath/MeloNXDonorBridge.dylib \
    "$HERE/MeloNXDonorBridge.m" -o "$APP/Frameworks/MeloNXDonorBridge.dylib"

xcrun clang -isysroot "$SDK" -fobjc-arc -fmodules -I"$HERE/upstream" -w -framework Foundation \
    "$HERE/test/harness.m" "$HERE/upstream/MLXRamDonor.m" -o "$BUILD/harness"

"$BUILD/harness" "$APP/Frameworks/MeloNXDonorBridge.dylib" 2>/dev/null
