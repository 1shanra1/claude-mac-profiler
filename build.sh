#!/bin/bash
set -e

APP="ClaudeProfiler.app"
IDENTITY="Developer ID Application: Ishan Rai (X84JU33S92)"
ENTITLEMENTS="ClaudeProfiler.entitlements"
TEAM_ID="X84JU33S92"
BUNDLE_ID="com.ishanrai.claudeprofiler"

echo "Building $APP..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

swiftc ClaudeProfiler.swift \
    -o "$APP/Contents/MacOS/ClaudeProfiler" \
    -target arm64-apple-macosx14.0 \
    -swift-version 5 \
    -parse-as-library

cp Info.plist "$APP/Contents/"
cp -r sprites "$APP/Contents/Resources/"

# Sign with Developer ID + hardened runtime + entitlements
if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    codesign --force --sign "$IDENTITY" "$APP"
    echo "Signed with Developer ID."
else
    codesign --force --sign - "$APP"
    echo "Signed ad-hoc (Developer ID cert not found)."
fi

echo "Built $APP successfully."
echo "Run with: open $APP"
echo ""
echo "To notarize for distribution:"
echo "  ditto -c -k --keepParent $APP $APP.zip"
echo "  xcrun notarytool submit $APP.zip --apple-id YOUR_APPLE_ID --password APP_SPECIFIC_PASSWORD --team-id $TEAM_ID --wait"
echo "  xcrun stapler staple $APP"
