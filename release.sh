#!/bin/zsh
# Builds build/release/Dynisland-<version>.dmg and, with PUBLISH=1, publishes it as a GitHub release. See RELEASING.md.
#
# It signs with the best identity in your keychain:
#   "Developer ID Application: …"  signed and notarised by Apple: opens with no warning (needs a paid developer account)
#   "Dynisland Self-Signed"        free; not notarised, so the first launch needs System Settings → Open Anyway.
#                                  Same certificate every release, so permissions survive updates.
#   TEST=1                          your development certificate, to try the packaging only (can't be published)
#
#   ./release.sh            build and package
#   PUBLISH=1 ./release.sh  ...and create the GitHub release (needs `gh auth login` once)
#   DRAFT=1 PUBLISH=1 ...   as a draft: only you see it until you press Publish on GitHub
set -euo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
PROFILE="${NOTARY_PROFILE:-dynisland-notary}"
SELF_SIGNED="${SELF_SIGNED_IDENTITY:-Dynisland Self-Signed}"
KEYCHAIN_ARGS=(); [[ -n ${SIGNING_KEYCHAIN:-} ]] && KEYCHAIN_ARGS=(--keychain "$SIGNING_KEYCHAIN") # only for testing with a throwaway keychain
OUT=build/release

step() { print -P "%F{cyan}==>%f $1"; }
fail() { print -P "%F{red}error:%f $1" >&2; exit 1; }

VERSION=$(xcodebuild -project Dynisland.xcodeproj -target Dynisland -configuration Release -showBuildSettings 2>/dev/null | awk '$1 == "MARKETING_VERSION" { print $3 }')
[[ -n $VERSION ]] || fail "couldn't read MARKETING_VERSION"

identities=$(security find-identity -p codesigning ${SIGNING_KEYCHAIN:-} 2>/dev/null)
if [[ ${TEST:-0} == 1 ]]; then
  MODE=test; IDENTITY="Apple Development"
elif IDENTITY=$(print -r -- "$identities" | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"') && [[ -n $IDENTITY ]]; then
  MODE=notarised
  xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
    || fail "no notary credentials named \"$PROFILE\". See RELEASING.md, \"Later: notarised releases\"."
elif print -r -- "$identities" | grep -q "\"$SELF_SIGNED\""; then
  MODE=self; IDENTITY="$SELF_SIGNED"
else
  fail "no signing certificate. Create \"$SELF_SIGNED\" in Keychain Access (RELEASING.md, step 1), or use TEST=1 to try the packaging."
fi
DMG="$OUT/Dynisland-$VERSION.dmg"
step "Dynisland $VERSION · $MODE · $IDENTITY"

step "Building"
rm -rf "$OUT"
APP="$OUT/build/Release/Dynisland.app"
if [[ $MODE == self ]]; then
  # Xcode won't sign with a self-signed certificate, so build unsigned and sign here: the helper first, then the app around it.
  xcodebuild -project Dynisland.xcodeproj -target Dynisland -configuration Release SYMROOT="$PWD/$OUT/build" -quiet \
    CODE_SIGNING_ALLOWED=NO # (ad hoc signing makes xcodebuild report a bogus failure)
  codesign --force --sign "$IDENTITY" "${KEYCHAIN_ARGS[@]}" --options runtime --timestamp=none "$APP/Contents/Resources/libNowPlaying.dylib"
  codesign --force --sign "$IDENTITY" "${KEYCHAIN_ARGS[@]}" --options runtime --timestamp=none --entitlements Dynisland.entitlements "$APP"
else
  # --timestamp: notarisation needs a secure timestamp on every signature. No get-task-allow (debugger) entitlement in releases.
  xcodebuild -project Dynisland.xcodeproj -target Dynisland -configuration Release SYMROOT="$PWD/$OUT/build" -quiet \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" OTHER_CODE_SIGN_FLAGS="--timestamp" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO
fi
codesign --verify --deep --strict "$APP" || fail "the app's signature doesn't verify"

notarise() { # $1: file to submit (zip or dmg)
  step "Notarising $(basename "$1") (usually 2-10 minutes)"
  local log="$OUT/notary-$(basename "$1").json"
  xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait --output-format json > "$log" || true
  if ! grep -q '"status" *: *"Accepted"' "$log"; then
    local id=$(sed -n 's/.*"id" *: *"\([^"]*\)".*/\1/p' "$log" | head -1)
    [[ -n $id ]] && xcrun notarytool log "$id" --keychain-profile "$PROFILE" "$OUT/notary-issues.json" >/dev/null 2>&1
    fail "Apple didn't accept it. Details: $log${id:+ and $OUT/notary-issues.json}"
  fi
}

if [[ $MODE == notarised ]]; then
  # Notarise the app itself and staple the ticket to it, so it opens offline once copied to Applications.
  ditto -c -k --keepParent "$APP" "$OUT/Dynisland.zip"
  notarise "$OUT/Dynisland.zip"
  xcrun stapler staple -q "$APP"
fi

step "Packaging $DMG"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Dynisland.app"
ln -s /Applications "$STAGE/Applications" # drag-to-install
hdiutil create -quiet -volname "Dynisland $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
if [[ $MODE == self ]]; then
  codesign --sign "$IDENTITY" "${KEYCHAIN_ARGS[@]}" --timestamp=none "$DMG"
else
  codesign --sign "$IDENTITY" --timestamp "$DMG"
fi

if [[ $MODE == notarised ]]; then
  notarise "$DMG"
  xcrun stapler staple -q "$DMG"
  step "Checking it the way a downloader's Mac will"
  spctl --assess --type open --context context:primary-signature -v "$DMG"
  spctl --assess --type execute -v "$APP"
fi

if [[ ${PUBLISH:-0} == 1 ]]; then
  [[ $MODE != test ]] || fail "TEST builds can't be published"
  gh auth status >/dev/null 2>&1 || fail "the GitHub CLI isn't signed in: run \`gh auth login\` once"
  step "Publishing GitHub release v$VERSION"
  notes=""
  if [[ $MODE == self ]]; then
    notes=$(cat <<'NOTES'
### Install
1. Download **Dynisland-VERSION.dmg** below, open it and drag **Dynisland** onto **Applications**.
2. Open Dynisland. macOS says it can't verify the developer (this build isn't notarised by Apple): click **Done**.
3. Open **System Settings → Privacy & Security**, scroll down and click **Open Anyway** next to Dynisland, then confirm.

Only needed once per version. Or, in Terminal: `xattr -dr com.apple.quarantine /Applications/Dynisland.app`

NOTES
)
    notes=${notes//VERSION/$VERSION}
  fi
  gh release create "v$VERSION" "$DMG" --title "Dynisland $VERSION" --notes "$notes" --generate-notes ${DRAFT:+--draft}
fi

step "Done: $DMG"
