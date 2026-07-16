#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────
# Forge — Build & Package Script
# Builds Forge.app (Release) and packages it into a .dmg
#
# Usage:
#   ./scripts/build-dmg.sh              # Full build + DMG
#   ./scripts/build-dmg.sh --skip-build # DMG only (uses existing .app)
#   ./scripts/build-dmg.sh --notarize   # Full build + DMG + notarize
# ─────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${PROJECT_DIR}/build"
ARCHIVE_PATH="${BUILD_DIR}/Forge.xcarchive"
APP_PATH="${BUILD_DIR}/Forge.app"
DMG_NAME="Forge-$(date +%Y%m%d).dmg"
DMG_PATH="${BUILD_DIR}/${DMG_NAME}"
VERSION="1.0.0"

SKIP_BUILD=false
NOTARIZE=false

# Parse arguments
for arg in "$@"; do
    case $arg in
        --skip-build) SKIP_BUILD=true ;;
        --notarize) NOTARIZE=true ;;
        --help)
            echo "Usage: $0 [--skip-build] [--notarize]"
            echo ""
            echo "  --skip-build   Skip xcodebuild, use existing .app in build/"
            echo "  --notarize     Notarize the DMG with Apple (requires credentials)"
            exit 0
            ;;
    esac
done

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Forge Build Script v${VERSION}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ─── Step 0: Prerequisites ───────────────────────────────────

check_tool() {
    if ! command -v "$1" &>/dev/null; then
        echo "❌ $1 is not installed."
        echo "   Install with: $2"
        exit 1
    fi
}

check_tool "xcodebuild" "Install Xcode from the Mac App Store"
check_tool "xcodegen" "brew install xcodegen"

# create-dmg is optional if user just wants to build
if [ "$SKIP_BUILD" = false ]; then
    echo ""
fi

# ─── Step 1: Generate Xcode Project ─────────────────────────

echo ""
echo "▸ Generating Xcode project..."
cd "$PROJECT_DIR"
xcodegen generate --quiet
echo "  ✓ Forge.xcodeproj generated"

# ─── Step 2: Build Release Archive ──────────────────────────

if [ "$SKIP_BUILD" = false ]; then
    echo ""
    echo "▸ Building Forge (Release)..."
    mkdir -p "$BUILD_DIR"

    xcodebuild archive \
        -project Forge.xcodeproj \
        -scheme Forge \
        -configuration Release \
        -archivePath "$ARCHIVE_PATH" \
        -quiet \
        CODE_SIGN_IDENTITY="-" \
        ENABLE_HARDENED_RUNTIME=YES

    echo "  ✓ Archive created"

    # Extract .app from archive
    echo ""
    echo "▸ Extracting Forge.app..."
    rm -rf "$APP_PATH"
    cp -R "${ARCHIVE_PATH}/Products/Applications/Forge.app" "$APP_PATH"
    echo "  ✓ Forge.app extracted to build/"

    # Print app size
    APP_SIZE=$(du -sh "$APP_PATH" | cut -f1)
    echo "  ℹ App size: ${APP_SIZE}"
fi

# ─── Step 3: Verify .app exists ──────────────────────────────

if [ ! -d "$APP_PATH" ]; then
    echo "❌ Forge.app not found at ${APP_PATH}"
    echo "   Run without --skip-build first."
    exit 1
fi

# ─── Step 4: Create DMG ─────────────────────────────────────

echo ""
echo "▸ Creating DMG..."

# Check for create-dmg
if command -v create-dmg &>/dev/null; then
    # Styled DMG with Applications shortcut
    rm -f "$DMG_PATH"

    create-dmg \
        --volname "Forge" \
        --window-pos 200 120 \
        --window-size 660 400 \
        --icon-size 160 \
        --icon "Forge.app" 180 170 \
        --hide-extension "Forge.app" \
        --app-drop-link 480 170 \
        --no-internet-enable \
        "$DMG_PATH" \
        "$APP_PATH" \
        || true  # create-dmg returns 2 on "no icon" warning, which is fine

    echo "  ✓ DMG created: ${DMG_PATH}"
else
    # Fallback: simple DMG with hdiutil
    echo "  ℹ create-dmg not found, using hdiutil (basic DMG)"
    echo "    Install create-dmg for a styled DMG: brew install create-dmg"

    STAGING="${BUILD_DIR}/dmg-staging"
    rm -rf "$STAGING"
    mkdir -p "$STAGING"
    cp -R "$APP_PATH" "$STAGING/"
    ln -s /Applications "$STAGING/Applications"

    rm -f "$DMG_PATH"
    hdiutil create \
        -volname "Forge" \
        -srcfolder "$STAGING" \
        -ov \
        -format UDZO \
        "$DMG_PATH"

    rm -rf "$STAGING"
    echo "  ✓ DMG created: ${DMG_PATH}"
fi

DMG_SIZE=$(du -sh "$DMG_PATH" | cut -f1)
echo "  ℹ DMG size: ${DMG_SIZE}"

# ─── Step 5: Notarize (optional) ────────────────────────────

if [ "$NOTARIZE" = true ]; then
    echo ""
    echo "▸ Notarizing DMG..."
    echo "  ℹ You need to set up notarization credentials first:"
    echo "    xcrun notarytool store-credentials \"forge-notary\" \\"
    echo "      --apple-id YOUR_APPLE_ID \\"
    echo "      --team-id YOUR_TEAM_ID \\"
    echo "      --password YOUR_APP_SPECIFIC_PASSWORD"
    echo ""

    xcrun notarytool submit "$DMG_PATH" \
        --keychain-profile "forge-notary" \
        --wait

    xcrun stapler staple "$DMG_PATH"
    echo "  ✓ DMG notarized and stapled"
fi

# ─── Done ────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ Done!"
echo ""
echo "  App: ${APP_PATH}"
echo "  DMG: ${DMG_PATH}"
echo ""
echo "  To test: open ${APP_PATH}"
echo "  To install: open ${DMG_PATH}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
