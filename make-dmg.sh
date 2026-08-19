#!/bin/bash
# ---------------------------------------------------------------------------
# make-dmg.sh — wrap the notarized app in a drag-to-Applications .dmg.
# ---------------------------------------------------------------------------
# Pass nothing; it uses build/Sample Sweep.app. Notarize + staple the APP
# first, so the dmg carries an already-good app, then notarize the dmg too
# (it needs its own ticket to pass on download). release.sh does both in order.
#
# Branding is asset-driven and optional:
#   Tools/dmg-assets/background.png   → window background + icon layout
#   Tools/dmg-assets/VolumeIcon.icns  → custom volume icon
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")"
source ./config.sh

[[ -d "$APP" ]] || die "No app at $APP — run ./build-app.sh --sign first."
VERSION="$(app_version)"
[[ -n "$VERSION" ]] || die "Could not read CFBundleShortVersionString from $APP"

VOLNAME="$APP_NAME $VERSION"
DMG_OUT="build/SampleSweep-$VERSION.dmg"
ASSETS="Tools/dmg-assets"

# A previous failed run can leave the volume mounted, which makes hdiutil fail
# with "Resource busy". Clear it before starting.
if [ -d "/Volumes/$VOLNAME" ]; then
    step "Detaching a stale mount from an earlier run"
    hdiutil detach "/Volumes/$VOLNAME" -force >/dev/null 2>&1 || true
fi

step "Staging dmg contents"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
ditto "$APP" "$stage/$APP_NAME.app"
ln -s /Applications "$stage/Applications"
ok "$APP_NAME.app + Applications alias"

step "Creating read/write image"
rw="$(mktemp -u).dmg"
hdiutil create -srcfolder "$stage" -volname "$VOLNAME" -fs HFS+ \
    -format UDRW -ov "$rw" >/dev/null
mnt="/Volumes/$VOLNAME"
hdiutil attach "$rw" -mountpoint "$mnt" -nobrowse >/dev/null
ok "mounted at $mnt"

if [ -f "$ASSETS/background.png" ]; then
    step "Applying branded layout"
    mkdir -p "$mnt/.background"
    cp "$ASSETS/background.png" "$mnt/.background/background.png"
    # Icon slots match the arrow drawn into the background (600x400 window).
    layout_ok=1
    osascript <<OSA >/dev/null 2>&1 || layout_ok=0
tell application "Finder"
  -- Wait for Finder to register the freshly mounted volume. Addressing it
  -- immediately after hdiutil attach races and fails with -1728 ("Can't get
  -- disk"), which is what silently cost every dmg its branded layout.
  set tries to 0
  repeat until (exists disk "$VOLNAME") or tries > 20
    delay 0.5
    set tries to tries + 1
  end repeat
  tell disk "$VOLNAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 800, 520}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 96
    set background picture of opts to file ".background:background.png"
    set position of item "$APP_NAME.app" of container window to {150, 185}
    set position of item "Applications" of container window to {450, 185}
    delay 1
    close
  end tell
end tell
OSA
    # Finder writes the window layout into .DS_Store when it closes the window.
    # No .DS_Store means the background and icon positions did NOT take, however
    # cheerfully the AppleScript exited — verify rather than assume.
    sync
    if [ "$layout_ok" = "1" ] && [ -f "$mnt/.DS_Store" ]; then
        ok "background + icon layout applied"
    else
        printf '  \033[33m!\033[0m %s\n' "layout NOT applied — the dmg will open as a plain window."
        printf '    %s\n' "Finder automation was unavailable (this needs a normal desktop session;"
        printf '    %s\n' "it also fails over ssh or with Automation permission denied)."
        printf '    %s\n' "The dmg is still functional. Re-run ./make-dmg.sh from Terminal.app to fix."
        DMG_LAYOUT_MISSING=1
    fi
else
    ok "no $ASSETS/background.png — plain functional dmg"
fi

if [ -f "$ASSETS/VolumeIcon.icns" ]; then
    cp "$ASSETS/VolumeIcon.icns" "$mnt/.VolumeIcon.icns"
    command -v SetFile >/dev/null 2>&1 && SetFile -a C "$mnt" 2>/dev/null || true
    ok "custom volume icon set"
fi

step "Finalizing (compress)"
sync
hdiutil detach "$mnt" >/dev/null
rm -f "$DMG_OUT"
hdiutil convert "$rw" -format UDZO -imagekey zlib-level=9 -o "$DMG_OUT" >/dev/null
rm -f "$rw"
ok "built $DMG_OUT"

step "Signing the dmg"
# A dmg must be signed BEFORE notarizing. An unsigned dmg still notarizes, but
# spctl then reports "no usable signature".
codesign --force --timestamp --sign "$DEVID_APP_IDENTITY" "$DMG_OUT"
ok "signed with $DEVID_APP_IDENTITY"

if [ "${DMG_LAYOUT_MISSING:-0}" = "1" ]; then
    printf '\n\033[33mNote:\033[0m built without the branded layout — see above.\n'
fi
printf '\nNext (the dmg needs its own ticket): ./notarize.sh "%s"\n' "$DMG_OUT"
