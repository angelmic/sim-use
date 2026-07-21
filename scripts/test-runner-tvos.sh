#!/bin/bash
# SPDX-License-Identifier: Apache-2.0

# tvOS Simulator E2E runner: builds the CLI and the SimUsePlaygroundTV
# fixture, installs it on a booted tvOS Simulator, checks the Appium
# endpoint, and runs the TVOSRemoteTests suite.
#
# Requirements the script checks for you:
#   * a tvOS Simulator (booted one preferred; otherwise it boots one)
#   * an Appium server with the XCUITest driver at SIM_USE_APPIUM_URL
#     (default http://127.0.0.1:4723) — start with `appium --port 4723`

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info()    { echo -e "${BLUE}ℹ️  $1${NC}"; }
print_success() { echo -e "${GREEN}✅ $1${NC}"; }
print_error()   { echo -e "${RED}❌ $1${NC}"; }

PLAYGROUND_PROJECT="Playgrounds/tvOS/SimUsePlaygroundTV.xcodeproj"
PLAYGROUND_SCHEME="SimUsePlaygroundTV"
BUNDLE_ID="com.cameroncooke.SimUsePlaygroundTV"
DERIVED_DATA=".build/PlaygroundTV"
APPIUM_URL="${SIM_USE_APPIUM_URL:-http://127.0.0.1:4723}"

# --- Arguments --------------------------------------------------------------
FILTER="TVOSRemoteTests"
SKIP_BUILD=false
for arg in "$@"; do
    case "$arg" in
        -h|--help)
            echo "Usage: $0 [test-name] [--no-build]"
            echo ""
            echo "  test-name    Run a single test, e.g. focusNavigationRoundTrip"
            echo "               (default: the whole TVOSRemoteTests suite)"
            echo "  --no-build   Skip rebuilding the CLI and the fixture app —"
            echo "               fast iteration when only the tests changed"
            exit 0
            ;;
        --no-build)
            SKIP_BUILD=true
            ;;
        *)
            FILTER="TVOSRemoteTests.$arg"
            ;;
    esac
done

# --- tvOS simulator -------------------------------------------------------
UDID="${TVOS_SIMULATOR_UDID:-}"
if [[ -z "$UDID" ]]; then
    UDID=$(xcrun simctl list devices booted -j | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
for runtime, rows in devices.items():
    if ".tvOS-" in runtime:
        for row in rows:
            print(row["udid"]); sys.exit(0)
')
fi
if [[ -z "$UDID" ]]; then
    UDID=$(xcrun simctl list devices -j | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
for runtime, rows in devices.items():
    if ".tvOS-" in runtime and rows:
        print(rows[0]["udid"]); sys.exit(0)
')
    if [[ -z "$UDID" ]]; then
        print_error "No tvOS Simulator found. Create one in Xcode (Devices & Simulators) first."
        exit 1
    fi
    print_info "Booting tvOS Simulator $UDID"
    xcrun simctl boot "$UDID"
    xcrun simctl bootstatus "$UDID"
fi
print_info "Using tvOS Simulator $UDID"

# --- Appium ---------------------------------------------------------------
if ! curl -sf --max-time 3 "$APPIUM_URL/status" > /dev/null; then
    print_error "Appium is not reachable at $APPIUM_URL."
    print_info  "Start it with: appium --port 4723   (driver: appium driver install xcuitest)"
    exit 1
fi
print_success "Appium reachable at $APPIUM_URL"

if [[ "$SKIP_BUILD" == false ]]; then
    # --- Playground project (XcodeGen; *.xcodeproj is gitignored) ----------
    if ! command -v xcodegen &> /dev/null; then
        print_error "xcodegen not found. Install with: brew install xcodegen"
        exit 1
    fi
    print_info "Generating $PLAYGROUND_SCHEME.xcodeproj"
    (cd Playgrounds/tvOS && xcodegen generate | tail -1)

    # --- Build & install ---------------------------------------------------
    print_info "Building sim-use CLI"
    swift build

    print_info "Building $PLAYGROUND_SCHEME"
    xcodebuild -project "$PLAYGROUND_PROJECT" -scheme "$PLAYGROUND_SCHEME" \
        -destination "platform=tvOS Simulator,id=$UDID" \
        -derivedDataPath "$DERIVED_DATA" build | tail -2

    APP_PATH=$(find "$DERIVED_DATA/Build/Products" -name "$PLAYGROUND_SCHEME.app" -maxdepth 2 | head -1)
    if [[ -z "$APP_PATH" ]]; then
        print_error "Built app not found under $DERIVED_DATA/Build/Products"
        exit 1
    fi
    print_info "Installing $BUNDLE_ID"
    xcrun simctl install "$UDID" "$APP_PATH"
    xcrun simctl launch "$UDID" "$BUNDLE_ID" || true
else
    print_info "Skipping CLI + fixture build (--no-build)"
fi

# --- Run the suite --------------------------------------------------------
print_info "Running $FILTER"
if SIM_USE_E2E=1 TVOS_SIMULATOR_UDID="$UDID" swift test --filter "$FILTER"; then
    print_success "tvOS E2E green"
else
    print_error "tvOS E2E failed"
    exit 1
fi
