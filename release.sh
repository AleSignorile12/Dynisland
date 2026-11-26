#!/bin/zsh
# Builds a signed, notarised Dynisland-<version>.dmg in build/release, ready to download and open without warnings.
#   ./release.sh               build, sign with Developer ID, notarise, package
#   PUBLISH=1 ./release.sh     ...then publish it as a GitHub release (needs `gh auth login`)
#   TEST=1 ./release.sh        package only, signed with your development certificate, not notarised (to try the DMG)
# One-time setup (Developer ID certificate, notary credentials): see RELEASING.md.
set -euo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
PROFILE="${NOTARY_PROFILE:-dynisland-notary}"
OUT=build/release

step() { print -P "%F{cyan}==>%f $1"; }
fail() { print -P "%F{red}error:%f $1" >&2; exit 1; }

VERSION=$(xcodebuild -project Dynisland.xcodeproj -target Dynisland -configuration Release -showBuildSettings 2>/dev/null | awk '$1 == "MARKETING_VERSION" { print $3 }')
[[ -n $VERSION ]] || fail "couldn't read MARKETING_VERSION"

if [[ ${TEST:-0} == 1 ]]; then
  IDENTITY="Apple Development"
else
  IDENTITY=$(security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')
  [[ -n $IDENTITY ]] || fail "no \"Developer ID Application\" certificate in your keychain. See RELEASING.md, step 2. (TEST=1 ./release.sh packages without one.)"
  xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
    || fail "no notary credentials named \"$PROFILE\". See RELEASING.md, step 3."
fi
DMG="$OUT/Dynisland-$VERSION.dmg"
step "Dynisland $VERSION, signed by: $IDENTITY"

step "Building"
rm -rf "$OUT"
# --timestamp: notarisation needs a secure timestamp on every signature. No get-task-allow (debugger) entitlement in releases.
xcodebuild -project Dynisland.xcodeproj -target Dynisland -configuration Release SYMROOT="$PWD/$OUT/build" -quiet \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" OTHER_CODE_SIGN_FLAGS="--timestamp" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO
APP="$OUT/build/Release/Dynisland.app"
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

if [[ ${TEST:-0} != 1 ]]; then
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
codesign --sign "$IDENTITY" --timestamp "$DMG"

if [[ ${TEST:-0} != 1 ]]; then
  notarise "$DMG"
  xcrun stapler staple -q "$DMG"
  step "Checking it the way a downloader's Mac will"
  spctl --assess --type open --context context:primary-signature -v "$DMG"
  spctl --assess --type execute -v "$APP"
fi

if [[ ${PUBLISH:-0} == 1 ]]; then
  [[ ${TEST:-0} != 1 ]] || fail "TEST builds aren't notarised; not publishing one"
  gh auth status >/dev/null 2>&1 || fail "the GitHub CLI isn't signed in: run \`gh auth login\` once"
  step "Publishing GitHub release v$VERSION"
  gh release create "v$VERSION" "$DMG" --title "Dynisland $VERSION" --generate-notes
fi

step "Done: $DMG"
