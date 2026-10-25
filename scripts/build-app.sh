#!/bin/bash
# Builds InkStats.app into ./build.
#
# Signing: uses SIGN_IDENTITY if set, otherwise the first "Developer ID Application"
# certificate in your keychain, otherwise an ad-hoc signature. The privileged helper only
# works with a Developer ID signature, because it checks that the app and helper share a team.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    SIGN_IDENTITY=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)
    SIGN_IDENTITY=${SIGN_IDENTITY:--}
fi

# Notarization needs a secure timestamp; RELEASE=1 asks Apple's timestamp server for one.
TIMESTAMP=--timestamp=none
[[ "${RELEASE:-}" == 1 ]] && TIMESTAMP=--timestamp

swift build -c release --product InkStats
swift build -c release --product InkStatsHelper

APP=build/InkStats.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Fonts" "$APP/Contents/Library/LaunchDaemons"
cp .build/release/InkStats "$APP/Contents/MacOS/InkStats"
cp .build/release/InkStatsHelper "$APP/Contents/MacOS/InkStatsHelper"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/Fonts/* "$APP/Contents/Resources/Fonts/"
cp Resources/LaunchDaemons/dev.inkstats.helper.plist "$APP/Contents/Library/LaunchDaemons/"

# Inner code first, then the bundle that seals it.
codesign --force --options runtime "$TIMESTAMP" --identifier dev.inkstats.helper --sign "$SIGN_IDENTITY" "$APP/Contents/MacOS/InkStatsHelper"
codesign --force --options runtime "$TIMESTAMP" --entitlements Resources/InkStats.entitlements --sign "$SIGN_IDENTITY" "$APP"
echo "Built $APP (signed with: $SIGN_IDENTITY)"
