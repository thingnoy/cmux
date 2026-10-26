#!/usr/bin/env bash
set -euo pipefail

# Ship the iOS app to Skypart's own TestFlight (com.skypart.cmux, "cmux connect").
# Reconstructed from ψ/memory/learnings/2026-08-18_cmux-ios-self-build-to-testflight.md
# + ios/scripts/upload-testflight.sh's Iroh-minOS policy. Usage:
#   ./scripts/ship-skypart-testflight.sh <build-number> ["what to test"]
#
# Toolchain is a narrow window: Xcode 26.3 only (26.0 fails strict-concurrency
# in GhosttySurfaceView; 27 beta drops SwiftUI.LazyState symbols at link).

BUILD_NUM="${1:?usage: ship-skypart-testflight.sh <build-number> [notes]}"
NOTES="${2:-}"
BUNDLE_ID="com.skypart.cmux"
TEAM_ID="W3NAH8A3G5"
SIGN_ID="Apple Distribution: Supasai haplakhon (W3NAH8A3G5)"
KEY_ID="L6J8JSWQQ3"
KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_$KEY_ID.p8"
ISSUER="$(cat "$HOME/.appstoreconnect/issuer-id")"
export DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d /tmp/cmux-ship.XXXXXX)"
ARCHIVE="$WORK/cmux-ios.xcarchive"
trap 'echo "workdir kept for inspection: $WORK"' EXIT

cd "$ROOT"
# Without --verify-only it also extracts GhosttyKit.xcframework, which the archive needs.
./scripts/download-prebuilt-ghosttykit.sh

# Extensions (NotificationService, CloudVPN) derive their ids from
# CMUX_APP_BUNDLE_IDENTIFIER; overriding PRODUCT_BUNDLE_IDENTIFIER would give
# them the app's id. group.dev.cmux.ios belongs to manaflow's team and no code
# reads it, so our NotificationService signs without it.
NSE_ENTITLEMENTS="$WORK/NotificationService.entitlements"
cp ios/Config/NotificationService.entitlements "$NSE_ENTITLEMENTS"
/usr/libexec/PlistBuddy -c 'Delete :com.apple.security.application-groups' "$NSE_ENTITLEMENTS"

echo "== archive (build $BUILD_NUM)"
xcodebuild archive -workspace ios/cmux.xcworkspace -scheme cmux-ios \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  CMUX_APP_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  CMUX_NOTIFICATION_SERVICE_BUNDLE_IDENTIFIER="$BUNDLE_ID.NotificationService" \
  CMUX_NOTIFICATION_SERVICE_CODE_SIGN_ENTITLEMENTS="$NSE_ENTITLEMENTS" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CURRENT_PROJECT_VERSION="$BUILD_NUM" \
  -allowProvisioningUpdates -authenticationKeyPath "$KEY_PATH" \
  -authenticationKeyID "$KEY_ID" -authenticationKeyIssuerID "$ISSUER" \
  | tail -3
[[ -d "$ARCHIVE" ]] || { echo "FATAL: archive failed"; exit 1; }

echo "== export (manual App Store profiles; the ASC key has no cloud-signing permission)"
python3 "$ROOT/scripts/skypart-asc-profiles.py" "$WORK/profiles.plist"
cat > "$WORK/export-options.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>export</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Apple Distribution</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>provisioningProfiles</key><dict/>
</dict></plist>
EOF
/usr/libexec/PlistBuddy -c "Merge $WORK/profiles.plist :provisioningProfiles" "$WORK/export-options.plist"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$WORK/export" \
  -exportOptionsPlist "$WORK/export-options.plist" \
  -allowProvisioningUpdates -authenticationKeyPath "$KEY_PATH" \
  -authenticationKeyID "$KEY_ID" -authenticationKeyIssuerID "$ISSUER" | tail -3
[[ -f "$WORK/export/cmux.ipa" ]] || { echo "FATAL: export produced no cmux.ipa"; exit 1; }

echo "== reconcile embedded-framework minOS (ITMS-90208: Xcode stamps synthesized"
echo "   dylibs for static SPM binaryTargets with the APP's target, plist stays put)"
cd "$WORK" && mkdir ipa-work && cd ipa-work
unzip -q ../export/cmux.ipa
APP=Payload/cmux.app
while IFS= read -r -d '' fw; do
  bin="$fw/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$fw/Info.plist" 2>/dev/null || basename "$fw" .framework)"
  file -b "$bin" | grep -q 'dynamically linked shared library' || continue
  minos="$(xcrun vtool -show-build "$bin" | awk '/^ *minos /{print $2; exit}')"
  plist_min="$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$fw/Info.plist" 2>/dev/null || true)"
  low="$(printf '%s\n%s\n' "${plist_min:-0}" "$minos" | sort -V | head -1)"
  if [[ -z "$plist_min" || ( "$plist_min" != "$minos" && "$low" == "$plist_min" ) ]]; then
    echo "   $(basename "$fw"): $plist_min -> $minos"
    /usr/libexec/PlistBuddy -c "Set :MinimumOSVersion $minos" "$fw/Info.plist" 2>/dev/null \
      || /usr/libexec/PlistBuddy -c "Add :MinimumOSVersion string $minos" "$fw/Info.plist"
    codesign --force --sign "$SIGN_ID" --timestamp "$fw"
    TOUCHED=1
  fi
done < <(find "$APP/Frameworks" -maxdepth 1 -type d -name '*.framework' -print0 2>/dev/null)
if [[ "${TOUCHED:-}" == 1 ]]; then
  codesign -d --entitlements :- --xml "$APP" > ent.plist
  codesign --force --sign "$SIGN_ID" --entitlements ent.plist --timestamp "$APP"
fi
codesign --verify --strict --verbose=2 "$APP"
codesign -d --entitlements :- "$APP" 2>/dev/null | grep -q 'aps-environment</key><string>production' \
  || { echo "FATAL: aps-environment is not production"; exit 1; }

# Untouched: ship Xcode's IPA as-is. Repacked: keep Symbols/ (crash symbolication)
# and SwiftSupport/ (ITMS-90426 rejects the build without it); Signatures/ no
# longer matches after re-signing, so it goes.
if [[ "${TOUCHED:-}" == 1 ]]; then
  rm -rf Signatures
  zip -qrX ../cmux-fixed.ipa Payload Symbols $([[ -d SwiftSupport ]] && echo SwiftSupport)
else
  cp ../export/cmux.ipa ../cmux-fixed.ipa
fi
# List once: piping zipinfo into grep -q trips pipefail via SIGPIPE (false FATAL).
IPA_FILES="$(zipinfo -1 ../cmux-fixed.ipa)"
grep -q '^Symbols/.*\.symbols$' <<<"$IPA_FILES" || { echo "FATAL: no Symbols/ in IPA"; exit 1; }
if [[ -d SwiftSupport ]]; then
  grep -q '^SwiftSupport/' <<<"$IPA_FILES" || { echo "FATAL: no SwiftSupport/ in IPA (ITMS-90426)"; exit 1; }
fi
cd "$WORK"

echo "== validate (30 s here beats 55 min of processing-then-reject)"
xcrun altool --validate-app -f cmux-fixed.ipa -t ios --apiKey "$KEY_ID" --apiIssuer "$ISSUER" | tail -2
echo "== upload"
xcrun altool --upload-app -f cmux-fixed.ipa -t ios --apiKey "$KEY_ID" --apiIssuer "$ISSUER" | tail -2

if [[ -n "$NOTES" ]]; then
  echo "== TestFlight notes: poll processing, then set What to Test"
  python3 "$ROOT/scripts/skypart-asc-notes.py" "$BUILD_NUM" "$NOTES"
fi
echo "DONE: build $BUILD_NUM uploaded — check processing with scripts/skypart-asc-notes.py --list"
