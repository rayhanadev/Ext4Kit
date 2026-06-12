#!/bin/bash
# Builds, signs, notarizes, and packages Ext4Kit for direct distribution.
#
# One-time setup:
#   1. A "Developer ID Application" certificate in your login keychain.
#   2. A "Developer ID Application" provisioning profile for the appex
#      (com.rayhanadev.Ext4Kit.Ext4KitExtension) — the FSKit module
#      entitlement is profile-gated, so the developer-id re-sign fails
#      without one. With Xcode signed into the team, the
#      -allowProvisioningUpdates flag below fetches/creates it.
#   3. An App Store Connect API key or app-specific password stored as a
#      notarytool keychain profile:
#        xcrun notarytool store-credentials ext4kit-notary \
#          --apple-id you@example.com --team-id TEAMID --password app-specific
#
# Usage: Scripts/release.sh <version>   (e.g. Scripts/release.sh 0.1.0)
set -euo pipefail

VERSION="${1:?usage: release.sh <version>}"
NOTARY_PROFILE="${NOTARY_PROFILE:-ext4kit-notary}"
TEAM_ID="${TEAM_ID:-GXU29PTM63}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/release"
ARCHIVE="$BUILD/Ext4Kit.xcarchive"
EXPORT="$BUILD/export"
ZIP="$BUILD/Ext4Kit-$VERSION.zip"

rm -rf "$BUILD"
mkdir -p "$BUILD"

echo "==> Archiving $VERSION"
xcodebuild -project "$ROOT/Ext4Kit.xcodeproj" -scheme Ext4Kit \
    -configuration Release archive -archivePath "$ARCHIVE" \
    MARKETING_VERSION="$VERSION"

echo "==> Exporting with Developer ID signing"
cat > "$BUILD/export-options.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$BUILD/export-options.plist" -exportPath "$EXPORT" \
    -allowProvisioningUpdates

echo "==> Notarizing"
ditto -c -k --keepParent "$EXPORT/Ext4Kit.app" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling"
xcrun stapler staple "$EXPORT/Ext4Kit.app"
rm -f "$ZIP"
ditto -c -k --keepParent "$EXPORT/Ext4Kit.app" "$ZIP"

echo "==> Done: $ZIP"
echo "GPL-2 reminder: publish the exact source for this build (tag v$VERSION)"
echo "and keep THIRD_PARTY_LICENSES.md in the release notes."
