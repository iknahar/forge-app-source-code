#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# make-dmg.sh — build Forge in Release configuration and wrap the .app into a
# distributable .dmg.
#
# Output: ./dist/Forge-<version>.dmg
#
# What this does, step by step:
#   1. Reads CFBundleShortVersionString out of Info.plist so the DMG filename
#      tracks the app version automatically.
#   2. Runs `xcodebuild -configuration Release` and walks the build out-of-
#      tree into ./build/ — keeps the user's normal DerivedData clean.
#   3. Copies the produced Forge.app into a staging directory, drops a
#      symlink to /Applications next to it so users get the classic
#      drag-and-drop install flow.
#   4. Uses `hdiutil create` with UDZO compression (the default for distributed
#      macOS DMGs, ~50% size reduction vs. uncompressed).
#
# Caveats:
#   • This produces an AD-HOC signed app. macOS Gatekeeper will refuse to open
#     it on first launch with a "Forge is damaged / cannot be verified"
#     message. Users have to either (a) right-click → Open the first time,
#     or (b) run `xattr -dr com.apple.quarantine /Applications/Forge.app`.
#   • For a production drop-on-the-landing-page DMG you'd want Developer ID
#     signing + Apple notarisation. That's a separate one-time setup ($99/yr
#     Apple Developer membership + certificate generation). Hook it in by
#     replacing the `codesign` + `xcrun notarytool submit` blocks below.
#
# Usage:
#   ./scripts/make-dmg.sh
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# Resolve paths relative to the repo root regardless of where the user
# invokes the script from.
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "${SCRIPT_DIR}/.." && pwd )"
cd "${REPO_ROOT}"

PROJECT="Forge.xcodeproj"
SCHEME="Forge"
CONFIG="Release"
BUILD_DIR="${REPO_ROOT}/build"
STAGE_DIR="${REPO_ROOT}/build/stage"
DIST_DIR="${REPO_ROOT}/dist"

# ── 1. Read version from Info.plist ─────────────────────────────────────────
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
    Forge/Resources/Info.plist)
echo "🔨 Building Forge ${VERSION} (${CONFIG})…"

# ── 2. Clean previous artifacts ─────────────────────────────────────────────
rm -rf "${BUILD_DIR}" "${STAGE_DIR}"
mkdir -p "${BUILD_DIR}" "${STAGE_DIR}" "${DIST_DIR}"

# ── 3. Build the Release configuration ──────────────────────────────────────
# Building out-of-tree (CONFIGURATION_BUILD_DIR / SYMROOT both inside
# ./build) so this script never touches ~/Library/Developer/Xcode/DerivedData
# — which keeps your iterative Debug builds separate from this distributable
# Release artifact.
# NB: no `clean` verb here — xcodebuild's clean step refuses to delete a
# directory the build system didn't create itself, and we've already
# `rm -rf`'d the output paths above. So we just `build` into the empty
# scratch dir.
xcodebuild \
    -project "${PROJECT}" \
    -scheme "${SCHEME}" \
    -configuration "${CONFIG}" \
    -derivedDataPath "${BUILD_DIR}/derived" \
    CONFIGURATION_BUILD_DIR="${BUILD_DIR}/${CONFIG}" \
    SYMROOT="${BUILD_DIR}" \
    build \
    2>&1 | tail -15

APP_PATH="${BUILD_DIR}/${CONFIG}/Forge.app"
if [[ ! -d "${APP_PATH}" ]]; then
    echo "❌ Build finished but Forge.app not at ${APP_PATH}"
    exit 1
fi
echo "✅ Built Forge.app at ${APP_PATH}"

# ── 4. Stage the .app + the /Applications symlink ───────────────────────────
# This is what the user actually sees inside the mounted DMG. The symlink
# right next to the app is the standard macOS install convention:
# drag Forge.app onto Applications and you're done.
cp -R "${APP_PATH}" "${STAGE_DIR}/Forge.app"
ln -s /Applications "${STAGE_DIR}/Applications"

# Friendly volume name (shown as the mounted disk's label in Finder).
VOLNAME="Forge ${VERSION}"
DMG_NAME="Forge-${VERSION}.dmg"
DMG_PATH="${DIST_DIR}/${DMG_NAME}"

# Remove any stale DMG from a previous run so hdiutil doesn't refuse to
# overwrite.
rm -f "${DMG_PATH}"

# ── 5. Build the compressed read-only DMG ───────────────────────────────────
# UDZO = zlib-compressed read-only. The standard for distribution.
# `-format UDZO` typically halves the size vs. raw, and macOS unmounts /
# remounts cleanly.
echo "📦 Wrapping into ${DMG_NAME}…"
hdiutil create \
    -volname "${VOLNAME}" \
    -srcfolder "${STAGE_DIR}" \
    -ov \
    -format UDZO \
    "${DMG_PATH}" \
    >/dev/null

# Clean up the staging folder so LaunchServices doesn't index the
# staged Forge.app as a second copy of the app — Spotlight would
# otherwise show two "Forge" results (the Debug build in
# DerivedData AND build/stage/Forge.app), and launching the wrong
# one would either no-op or fight the running instance.
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [[ -d "${STAGE_DIR}/Forge.app" ]]; then
    "${LSR}" -u "${STAGE_DIR}/Forge.app" 2>/dev/null || true
fi
rm -rf "${STAGE_DIR}"

# Final report.
SIZE_HUMAN=$(du -h "${DMG_PATH}" | cut -f1)
echo "✅ Done — ${DMG_PATH} (${SIZE_HUMAN})"
echo ""
echo "Distribution notes:"
echo "  • This DMG is ad-hoc signed. First-time users will see a Gatekeeper"
echo "    warning. They can bypass by right-clicking Forge.app → Open."
echo "  • For a no-warning install flow, add Developer ID signing +"
echo "    notarisation to this script (see header comments)."
