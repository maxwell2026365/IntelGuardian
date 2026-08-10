#!/bin/bash
set -euo pipefail

# ================================================================================
# IntelGuardian — Build & Run on macOS + iOS Simulator + iOS Device (3-way)
# ================================================================================

PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PROJECT="$PROJECT_DIR/IntelGuardian.xcodeproj"
SCHEME="IntelGuardian"
DERIVED_BASE="$PROJECT_DIR/.build"

CONFIG="Debug"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --release) CONFIG="Release" ;;
        -h|--help)
            echo "Usage: $0 [--release]"
            echo "  Builds & runs on 3 targets: macOS · iOS Simulator · iOS device"
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

echo ""
echo "══════════════════════════════════════════════════════════════════"
echo "  IntelGuardian — 3-Way Build & Run › $CONFIG"
echo "══════════════════════════════════════════════════════════════════"

# ── Clean ─────────────────────────────────────────────────────────────────────
rm -rf "$DERIVED_BASE"

# ── Shared helpers ─────────────────────────────────────────────────────────────
red()   { echo "❌  $*"; }
green() { echo "✅  $*"; }
warn()  { echo "⚠️  $*"; }
log()   { echo "  $*"; }

# ════════════════════════════════════════════════════════════════════════════════
# 1. macOS
# ════════════════════════════════════════════════════════════════════════════════
D_MAC="$DERIVED_BASE/macos"

echo -e "\n━━━ 🍏  1/3  macOS ($CONFIG) ━━━━━━━━━━━━━━━━━━━━━━"

xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
    -derivedDataPath "$D_MAC" \
    -destination 'platform=macOS,arch=arm64' \
    build 2>&1 | sed 's/^/  [macOS] /' || { red "macOS build failed"; exit 1; }

MACOS_APP=$(find "$D_MAC/Build/Products/$CONFIG" -maxdepth 1 -name "*.app" -type d | head -1)
[[ -z "$MACOS_APP" ]] && { red "macOS .app not found"; exit 1; }

open "$MACOS_APP"
green "macOS launched"

# ════════════════════════════════════════════════════════════════════════════════
# 2. iOS Simulator
# ════════════════════════════════════════════════════════════════════════════════
D_SIM="$DERIVED_BASE/ios-simulator"
build_simulator() {
    echo -e "\n━━━ 📱  2/3  iOS Simulator ($CONFIG) ━━━━━━━━━━━━"

    # Grab the UDID of the first iPhone simulator that is already booted,
    # or boot the first available one.
    local udid name
    udid=$(xcrun simctl list devices booted 2>/dev/null \
        | grep -E 'iPhone.*\([A-F0-9-]{36}\)' \
        | sed -E 's/.*\(([A-F0-9-]{36})\).*/\1/' | head -1)

    if [[ -z "$udid" ]]; then
        udid=$(xcrun simctl list devices 2>/dev/null \
            | grep -E 'iPhone.*\([A-F0-9-]{36}\)' \
            | sed -E 's/.*\(([A-F0-9-]{36})\).*/\1/' | head -1)
        [[ -z "$udid" ]] && { red "No iOS simulator found"; return 1; }
        log "Booting $udid…"
        xcrun simctl boot "$udid"
        sleep 5
    fi

    name=$(xcrun simctl list devices 2>/dev/null | grep "$udid" \
        | sed 's/^[[:space:]]*//' | sed 's/ ([^(]*)$//')
    log "Simulator: $name ($udid)"

    log "Building…"
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
        -derivedDataPath "$D_SIM" \
        -destination "platform=iOS Simulator,id=$udid" \
        build 2>&1 | sed 's/^/  [iOS Sim] /' || { red "iOS Simulator build failed"; return 1; }

    local app bid
    app=$(find "$D_SIM/Build/Products/$CONFIG-iphonesimulator" -maxdepth 1 -name "*.app" -type d | head -1)
    [[ -z "$app" ]] && { red "iOS Simulator .app not found"; return 1; }
    bid=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$app/Info.plist" 2>/dev/null || true)
    [[ -z "$bid" ]] && { red "Can't read bundle id"; return 1; }

    log "Installing…"
    xcrun simctl install booted "$app"
    log "Launching…"
    xcrun simctl launch booted "$bid"
    green "iOS Simulator launched — $name"
}

# ════════════════════════════════════════════════════════════════════════════════
# 3. iOS Device (wireless via devicectl)
# ════════════════════════════════════════════════════════════════════════════════
D_DEV="$DERIVED_BASE/ios-device"
build_device() {
    echo -e "\n━━━ 📲  3/3  iOS Device ($CONFIG) ━━━━━━━━━━━━"

    local dev_id
    # xctrace lists real devices as e.g. "iPhone (26.6) (00008110-001E21611181401E)".
    # The UDID varies in length — extract it by scanning for the "(<udid>)" pattern.
    dev_id=$(xcrun xctrace list devices 2>&1 \
        | grep -E '^iPhone \(' \
        | grep -oE '\([0-9A-F-]{25,40}\)' \
        | sed -E 's/[()]//g' | head -1)
    if [[ -z "$dev_id" ]]; then
        warn "No connected iPhone — skipping device target"
        return 0
    fi
    log "Device UDID: $dev_id"

    log "Building…"
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
        -derivedDataPath "$D_DEV" \
        -destination "platform=iOS,id=$dev_id" \
        build 2>&1 | sed 's/^/  [iOS Dev] /' || { red "iOS device build failed"; return 1; }

    local app bid
    app=$(find "$D_DEV/Build/Products/$CONFIG-iphoneos" -maxdepth 1 -name "*.app" -type d | head -1)
    [[ -z "$app" ]] && { red "iOS device .app not found"; return 1; }
    bid=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$app/Info.plist" 2>/dev/null || true)
    [[ -z "$bid" ]] && { red "Can't read bundle id"; return 1; }
    command -v devicectl &>/dev/null || { red "devicectl not found (needs Xcode 15+)"; return 1; }

    log "Installing (wireless)…"
    devicectl device install app --device "$dev_id" "$app" || { red "Install failed"; return 1; }
    log "Launching…"
    devicectl device process launch --device "$dev_id" "$bid" || { red "Launch failed"; return 1; }
    green "iOS Device launched"
}

# ════════════════════════════════════════════════════════════════════════════════

build_simulator &
PID_SIM=$!
build_device
wait $PID_SIM || true

echo ""
echo "══════════════════════════════════════════════════════════════════"
echo "  🎉  Done — macOS · iOS Simulator · iOS Device"
echo "══════════════════════════════════════════════════════════════════"
