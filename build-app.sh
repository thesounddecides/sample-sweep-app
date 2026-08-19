#!/bin/bash
# Builds Sample Sweep.app. Pass --sign to codesign with your Developer ID.
set -euo pipefail
cd "$(dirname "$0")"

source ./config.sh          # APP, APP_NAME, DEVID_APP_IDENTITY, helpers
IDENTITY="$DEVID_APP_IDENTITY"

# Universal binary. SwiftPM's --arch needs full Xcode (xcbuild), which a
# Command Line Tools install does not have, so build each slice with --triple
# and lipo them together. Intel Macs are still a large share of the audience.
echo "==> Compiling (Apple silicon)"
swift build -c release --triple arm64-apple-macosx13.0 --product SampleSweepApp
echo "==> Compiling (Intel)"
swift build -c release --triple x86_64-apple-macosx13.0 --product SampleSweepApp

BIN="build/SampleSweepApp-universal"
mkdir -p build
lipo -create \
    .build/arm64-apple-macosx/release/SampleSweepApp \
    .build/x86_64-apple-macosx/release/SampleSweepApp \
    -output "$BIN"

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Sample Sweep"
cp Tools/SampleSweep.icns "$APP/Contents/Resources/SampleSweep.icns"
cp Tools/sd-logo-dark.png  "$APP/Contents/Resources/sd-logo-dark.png"
cp Tools/sd-logo-light.png "$APP/Contents/Resources/sd-logo-light.png"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Sample Sweep</string>
    <key>CFBundleDisplayName</key><string>Sample Sweep</string>
    <key>CFBundleExecutable</key><string>Sample Sweep</string>
    <key>CFBundleIdentifier</key><string>com.sounddecisions.samplesweep</string>
    <key>CFBundleIconFile</key><string>SampleSweep</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0.2</string>
    <key>CFBundleVersion</key><string>3</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Sound Decisions, LLC</string>
    <key>NSSupportsAutomaticTermination</key><false/>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

if [[ "${1:-}" == "--sign" ]]; then
    echo "==> Signing"
    cat > build/entitlements.plist <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>com.apple.security.files.user-selected.read-write</key><true/>
</dict></plist>
ENT
    codesign --force --deep --options runtime --timestamp \
             --entitlements build/entitlements.plist \
             --sign "$IDENTITY" "$APP"
    codesign --verify --strict --verbose=2 "$APP"
fi

echo "==> Architectures"
lipo -info "$APP/Contents/MacOS/Sample Sweep"

echo "==> Done: $APP"
du -sh "$APP"
