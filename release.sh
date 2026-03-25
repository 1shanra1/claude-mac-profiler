#!/bin/bash
set -e

APP="ClaudeProfiler.app"
IDENTITY="Developer ID Application: Ishan Rai (X84JU33S92)"
TEAM_ID="X84JU33S92"

echo "Building $APP for release..."
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

codesign --force --sign "$IDENTITY" "$APP"

echo "Signed. Zipping and submitting for notarization..."
ditto -c -k --keepParent "$APP" "$APP.zip"
xcrun notarytool submit "$APP.zip" \
    --apple-id ishanrai2212@gmail.com \
    --password "$1" \
    --team-id "$TEAM_ID" \
    --wait

xcrun stapler staple "$APP"
rm "$APP.zip"

echo ""
echo "Done! $APP is signed, notarized, and ready for distribution."
