#!/bin/bash
set -euo pipefail

# Build Menu du Jour as a signed .app bundle ready for notarization.
#
# Usage:
#   ./macmenu_scripts/build-release.sh                                   # unsigned (for local testing)
#   ./macmenu_scripts/build-release.sh --log                             # unsigned + stream logs after launch
#   ./macmenu_scripts/build-release.sh --install                         # unsigned + copy to /Applications and launch from there
#   ./macmenu_scripts/build-release.sh "Developer ID Application: Your Name (TEAMID)"
#   ./macmenu_scripts/build-release.sh "Developer ID Application: ..." --log

WITH_LOG=0
INSTALL=0
SIGNING_IDENTITY=""
for arg in "$@"; do
    case "$arg" in
        --log) WITH_LOG=1 ;;
        --install) INSTALL=1 ;;
        *) SIGNING_IDENTITY="$arg" ;;
    esac
done

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/.build"
APP_NAME="Menu du Jour"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
INSTALL_DIR="/Applications"
INSTALLED_BUNDLE="$INSTALL_DIR/$APP_NAME.app"

echo "==> Stopping any previous instance..."
# Quit (or kill) the old instance BEFORE rebuilding the bundle. Deleting and
# recreating the bundle while an instance is still running leaves Launch
# Services pointing at a dead process, and the later `open` fails with
# error -600 (procNotFound). The osascript quit is asynchronous and silently
# fails without Automation permission, so wait and fall back to pkill.
osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
for _ in $(seq 1 20); do
    pgrep -qx "$APP_NAME" || break
    sleep 0.1
done
if pgrep -qx "$APP_NAME"; then
    echo "==> Previous instance did not quit — force killing..."
    pkill -x "$APP_NAME" || true
    sleep 0.5
fi

if [ -z "$SIGNING_IDENTITY" ]; then
    # Ad-hoc signatures change on every build, invalidating the TCC grant —
    # reset so the permission prompt reappears cleanly. Developer ID builds
    # have a stable signature and keep their grant, so don't reset for them.
    echo "==> Resetting accessibility permission (ad-hoc build)..."
    tccutil reset Accessibility com.luca.menudujour
    # Apple Events grants are keyed to the signature too, and the browser
    # Change Case path needs them. Left stale, AppleScriptRunner.permission
    # reports the grant as undetermined and the in-page JS path silently
    # declines, which looks like a broken hotkey rather than a prompt.
    tccutil reset AppleEvents com.luca.menudujour
fi

echo "==> Building release binary..."
swift build -c release --package-path "$PROJECT_DIR"

BINARY="$BUILD_DIR/release/$APP_NAME"
if [ ! -f "$BINARY" ]; then
    echo "ERROR: Binary not found at $BINARY"
    exit 1
fi

echo "==> Creating app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$PROJECT_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# Copy app icon if it exists
if [ -f "$PROJECT_DIR/Resources/AppIcon.icns" ]; then
    cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

echo "==> App bundle created at $APP_BUNDLE"

if [ -n "$SIGNING_IDENTITY" ]; then
    echo "==> Code signing with: $SIGNING_IDENTITY"
    codesign --force --options runtime \
        --entitlements "$PROJECT_DIR/MenuDuJour.entitlements" \
        --sign "$SIGNING_IDENTITY" \
        "$APP_BUNDLE"

    echo "==> Verifying signature..."
    codesign --verify --verbose "$APP_BUNDLE"

    ZIP_PATH="$BUILD_DIR/$APP_NAME.zip"
    echo "==> Creating zip for notarization..."
    ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"

    echo ""
    echo "Done! Next steps:"
    echo ""
    echo "  1. Submit for notarization:"
    echo "     xcrun notarytool submit \"$ZIP_PATH\" --keychain-profile menudujour-notary --wait   # profile: see CLAUDE.md"
    echo ""
    echo "  2. Staple the ticket:"
    echo "     xcrun stapler staple $APP_BUNDLE"
    echo ""
    echo "  3. Re-zip for distribution:"
    echo "     ditto -c -k --keepParent $APP_BUNDLE $ZIP_PATH"
else
    echo "==> Ad-hoc signing (local testing)..."
    codesign --force --sign - "$APP_BUNDLE"

    echo ""
    echo "Done! (ad-hoc signed — pass a signing identity for distribution)"
    echo "  ./macmenu_scripts/build-release.sh \"Developer ID Application: Your Name (TEAMID)\""
fi

# Choose which bundle to launch: the freshly-built one, or a copy installed
# into /Applications (a stable location, needed for Start-at-Login to work).
LAUNCH_BUNDLE="$APP_BUNDLE"
if [[ $INSTALL -eq 1 ]]; then
    echo "==> Installing to $INSTALLED_BUNDLE..."
    # The running instance (from either location) was already stopped above.
    rm -rf "$INSTALLED_BUNDLE"
    cp -R "$APP_BUNDLE" "$INSTALLED_BUNDLE"
    LAUNCH_BUNDLE="$INSTALLED_BUNDLE"
    if [ -z "$SIGNING_IDENTITY" ]; then
        echo "==> NOTE: ad-hoc build moved to a new path — re-grant Accessibility"
        echo "    in System Settings > Privacy & Security > Accessibility"
        echo "    (remove any stale 'Menu du Jour' entry first)."
    fi
fi

echo "==> Launching $APP_NAME..."
# Previous instance was already stopped before the bundle was rebuilt.
# Retry once in case Launch Services needs a beat to re-register the bundle.
if ! open "$LAUNCH_BUNDLE"; then
    echo "==> Launch failed — retrying in 1s..."
    sleep 1
    open "$LAUNCH_BUNDLE"
fi

if [[ $WITH_LOG -eq 1 ]]; then
    echo "==> Streaming logs (Ctrl+C to stop)..."
    # Filter by the emitting PROCESS, not by eventMessage. The app logs via
    # NSLog("%@", "[Menu du Jour] …") — the "%@" indirection keeps user text out
    # of the format string — so the literal "[Menu du Jour]" text lives in the
    # log's composedMessage while its eventMessage is just "%@". An
    # `eventMessage CONTAINS "Menu du Jour"` predicate therefore matched only
    # unrelated *system* logs that mention the app and never our own
    # diagnostics. Matching on the process name captures every line we emit.
    log stream --style compact --predicate 'process == "Menu du Jour"'
fi
