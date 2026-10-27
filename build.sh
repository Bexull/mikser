#!/bin/bash
# Builds Микшер.app into build/.
#   ./build.sh            build only
#   ./build.sh --install  also put it into /Applications (quits the running copy)
#   ./build.sh --release  also pack build/Mikser-<version>.zip for a GitHub release
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Микшер"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"

# Signing. A stable certificate keeps the "system audio recording" and Accessibility permissions
# across rebuilds, so it comes from MIXER_SIGN_IDENTITY or a local, untracked .sign-identity file
# (a certificate hash from `security find-identity -v -p codesigning`). Without one, and always
# for --release, the app is signed ad hoc: the download carries no personal certificate.
IDENTITY="${MIXER_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ] && [ "${1:-}" != "--release" ] && [ -f .sign-identity ]; then
    IDENTITY="$(tr -d '[:space:]' < .sign-identity)"
fi
IDENTITY="${IDENTITY:--}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

xcrun swiftc \
    -O \
    -swift-version 5 \
    -target arm64-apple-macos26.0 \
    -module-name Mixer \
    -parse-as-library \
    Sources/*.swift \
    -o "$APP/Contents/MacOS/Mixer"

cp Resources/Info.plist "$APP/Contents/Info.plist"
# "Русская + Қазақша" keyboard layout (regenerate with Tools/make-keyboard-layout.swift)
ditto Resources/RussianKazakh.bundle "$APP/Contents/Resources/RussianKazakh.bundle"
# Kazakh autocorrect data (regenerate with Tools/make-kazakh-dictionary.py, see README)
ditto Resources/kazakh "$APP/Contents/Resources/kazakh"

# Liquid Glass icon (Icon Composer document) -> Assets.car + AppIcon.icns
xcrun actool Resources/AppIcon.icon \
    --compile "$APP/Contents/Resources" \
    --platform macosx \
    --minimum-deployment-target 26.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "$BUILD_DIR/icon-partial.plist" \
    > /dev/null

codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
echo "Built $APP (signed: $([ "$IDENTITY" = "-" ] && echo "ad hoc" || echo "$IDENTITY"))"

if [ "${1:-}" = "--install" ]; then
    pkill -f "/Applications/$APP_NAME.app/Contents/MacOS/Mixer" 2>/dev/null || true
    sleep 0.5
    rm -rf "/Applications/$APP_NAME.app"
    ditto "$APP" "/Applications/$APP_NAME.app"
    echo "Installed /Applications/$APP_NAME.app"
fi

if [ "${1:-}" = "--release" ]; then
    VERSION="$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)"
    ZIP="$BUILD_DIR/Mikser-$VERSION.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "Packed $ZIP"
fi
