# ---------------------------------------------------------------------------
# config.sh — shared settings + notary credential handling. SOURCED, not run.
# ---------------------------------------------------------------------------
APP_NAME="Sample Sweep"
APP="build/$APP_NAME.app"
DEVID_APP_IDENTITY="Developer ID Application: Sound Decisions, LLC (W8LLAGU4XT)"
NOTARY_PROFILE="${NOTARY_PROFILE:-ComposureNotary}"
NOTARY_KEY_DIR="${NOTARY_KEY_DIR:-$HOME/.config/composure}"

die()  { printf '\n\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1m── %s ──\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }

app_version() {
    /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
        "$APP/Contents/Info.plist" 2>/dev/null
}

# Notary credentials, same contract as composure-vst/tools/_dist-lib.sh: an
# App Store Connect API key wins when present (a file you own, unaffected by
# Apple ID password rotation), else the keychain profile.
NOTARY_AUTH=()
NOTARY_AUTH_DESC=""
resolve_notary_auth() {
    local p8="$NOTARY_KEY_DIR/notary-api-key.p8"
    local envf="$NOTARY_KEY_DIR/notary-api-key.env"
    if [ -f "$p8" ] && [ -f "$envf" ]; then
        # shellcheck disable=SC1090
        source "$envf"
        if [ -n "${NOTARY_KEY_ID:-}" ] && [ -n "${NOTARY_ISSUER:-}" ]; then
            NOTARY_AUTH=(--key "$p8" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
            NOTARY_AUTH_DESC="App Store Connect API key"
            return 0
        fi
    fi
    NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
    NOTARY_AUTH_DESC="keychain profile '$NOTARY_PROFILE'"
}

# Prove credentials work before building or uploading anything (~1s).
assert_notary_credentials() {
    resolve_notary_auth
    xcrun notarytool history "${NOTARY_AUTH[@]}" >/dev/null 2>&1 || die \
"Notary credentials rejected by Apple — using $NOTARY_AUTH_DESC.

  Preferred fix (a file you own, immune to password rotation):
    developer.apple.com → Certificates, IDs & Profiles → Keys → +
    save the .p8 as  $NOTARY_KEY_DIR/notary-api-key.p8   (chmod 600)
    and its ids in   $NOTARY_KEY_DIR/notary-api-key.env
        NOTARY_KEY_ID=XXXXXXXXXX
        NOTARY_ISSUER=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx

  Or restore the keychain profile with an APP-SPECIFIC password
  (account.apple.com → Sign-In and Security → App-Specific Passwords —
   it looks like abcd-efgh-ijkl-mnop, NOT your Apple ID password):
    xcrun notarytool store-credentials \"$NOTARY_PROFILE\" \\
        --apple-id \"crew@thesounddecides.com\" --team-id W8LLAGU4XT"
}
