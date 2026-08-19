#!/bin/bash
# ---------------------------------------------------------------------------
# release.sh — one command from source to a shippable, notarized .dmg.
# ---------------------------------------------------------------------------
# Order matters and is the whole point:
#   build + sign the app
#   → notarize + STAPLE THE APP      (so the app is good inside the dmg)
#   → wrap it in a drag-to-Applications dmg, signed
#   → notarize + staple the DMG      (it needs its own ticket to pass on download)
#
# Credentials are checked once, up front, before any of it runs.
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")"
source ./config.sh

step "Preflight"
assert_notary_credentials; ok "notary credentials OK — $NOTARY_AUTH_DESC"
security find-identity -v -p codesigning 2>/dev/null | grep -qF "$DEVID_APP_IDENTITY" \
    || die "Developer ID Application identity not in keychain:
  '$DEVID_APP_IDENTITY'
  → check with: security find-identity -v -p codesigning"
ok "signing identity present"

./build-app.sh --sign
VERSION="$(app_version)"
[[ -n "$VERSION" ]] || die "Could not read the app version after building."

./notarize.sh                       # the app
./make-dmg.sh                       # wrap the stapled app
./notarize.sh "build/SampleSweep-$VERSION.dmg"

step "Done"
ok "build/SampleSweep-$VERSION.dmg"
printf '\nUpload it:\n  npx wrangler r2 object put composure-dl/SampleSweep-%s.dmg \\\n    --file "%s/build/SampleSweep-%s.dmg" --remote\n' \
    "$VERSION" "$PWD" "$VERSION"
printf '\nThen add the entry at the TOP of\n  sounddecides-web/src/data/sample-sweep-releases.json\nand deploy the site.\n'
