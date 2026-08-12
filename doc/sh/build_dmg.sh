#!/bin/bash
set -euo pipefail

# ================================================================================
# IntelGuardian — Build macOS .app and package it into an installable .dmg
#
# Usage:
#   ./build_dmg.sh                # Release build → IntelGuardian.dmg
#   ./build_dmg.sh --debug        # Debug build
#   ./build_dmg.sh --install      # Build + mount DMG & open Finder for install
#   ./build_dmg.sh --clean        # Delete the output dmg/app first
#
# Requires: Xcode command line tools (xcodebuild, hdiutil).
# The app is signed with your Development Team (Automatic signing) as configured
# in the Xcode project.
# ================================================================================

PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PROJECT="$PROJECT_DIR/IntelGuardian.xcodeproj"
SCHEME="IntelGuardian"
CONFIG="Release"
APP_NAME="IntelGuardian"

# Output locations
DIST_DIR="$PROJECT_DIR/dist"
APP_PATH="$DIST_DIR/$APP_NAME.app"
DMG_PATH="$DIST_DIR/$APP_NAME.dmg"
DERIVED_BASE="$PROJECT_DIR/.build/dmg"
VOL_NAME="$APP_NAME"
SRC_FOLDER="$DIST_DIR/dmg-staging"

DO_INSTALL=false
DO_CLEAN=false

red()   { echo "❌  $*"; }
green() { echo "✅  $*"; }
log()   { echo "  $*"; }

# ── Parse args ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --debug)     CONFIG="Debug" ;;
        --install)   DO_INSTALL=true ;;
        --clean)     DO_CLEAN=true ;;
        -h|--help)
            echo "Usage: $0 [--debug] [--install] [--clean]"
            echo "  --debug    Build a Debug configuration instead of Release."
            echo "  --install  After building, mount the DMG and open Finder."
            echo "  --clean    Remove existing .app/.dmg in dist/ first."
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

echo ""
echo "══════════════════════════════════════════════════════════════════"
echo "  IntelGuardian — Build .dmg installer › $CONFIG"
echo "══════════════════════════════════════════════════════════════════"

command -v xcodebuild >/dev/null || { red "xcodebuild not found — install Xcode"; exit 1; }
command -v hdiutil    >/dev/null || { red "hdiutil not found"; exit 1; }

mkdir -p "$DIST_DIR"

# ── Optional clean ─────────────────────────────────────────────────────────────
if $DO_CLEAN; then
    log "Cleaning dist/ …"
    rm -rf "$APP_PATH" "$DMG_PATH" "$SRC_FOLDER"
fi

# ── Build ───────────────────────────────────────────────────────────────────────
echo -e "\n━━━ 🔨  Building macOS $CONFIG ━━━━━━━━━━━━━━━━━━"
rm -rf "$DERIVED_BASE"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
    -derivedDataPath "$DERIVED_BASE" \
    -destination 'platform=macOS,arch=arm64' \
    build 2>&1 | sed 's/^/  [build] /' || { red "macOS build failed"; exit 1; }

BUILT_APP=$(find "$DERIVED_BASE/Build/Products/$CONFIG" -maxdepth 1 -name "*.app" -type d | head -1)
[[ -z "$BUILT_APP" ]] && { red ".app not found in build products"; exit 1; }
log "Built: $BUILT_APP"

rm -rf "$APP_PATH"
cp -R "$BUILT_APP" "$APP_PATH"
green "Copied app to $APP_PATH"

# Verify the app runs on the target macOS (LSUIElement / arch sanity check)
APP_ARCH=$(lipo -archs "$APP_PATH/Contents/MacOS/IntelGuardian" 2>/dev/null || echo "unknown")
log "App architecture: $APP_ARCH"

# ── Create DMG ─────────────────────────────────────────────────────────────────
echo -e "\n━━━ 💿  Packaging .dmg ━━━━━━━━━━━━━━━━━━"

# Stage the .app and a symlink to /Applications so dragging installs it.
rm -rf "$SRC_FOLDER"
mkdir -p "$SRC_FOLDER"
cp -R "$APP_PATH" "$SRC_FOLDER/"
ln -sf /Applications "$SRC_FOLDER/Applications"

rm -f "$DMG_PATH"
hdiutil create \
    -volname "$VOL_NAME" \
    -srcfolder "$SRC_FOLDER" \
    -ov \
    -format UDZO \
    "$DMG_PATH" 2>&1 | sed 's/^/  [dmg] /' || { red "hdiutil create failed"; exit 1; }

rm -rf "$SRC_FOLDER"
green "Created $DMG_PATH"

SIZE_MB=$(du -k "$DMG_PATH" | awk '{printf "%.1f", $1/1024}')
log "Size: ${SIZE_MB} MB"

# ── Optional install (mount + open Finder) ─────────────────────────────────────
if $DO_INSTALL; then
    echo -e "\n━━━ 📂  Opening installer ━━━━━━━━━━━━━━━━━━"
    hdiutil attach "$DMG_PATH" -nobrowse 2>&1 | sed 's/^/  [mount] /' | tail -2
    open "$DMG_PATH"
    green "DMG mounted — drag IntelGuardian.app into Applications"
fi

echo ""
echo "══════════════════════════════════════════════════════════════════"
echo "  🎉  Done — $DMG_PATH"
echo "══════════════════════════════════════════════════════════════════"
