#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# tvOS physical-device E2E runner for the focus-driven DeviceBackend surface.
# It provisions and installs the fixture, repairs/installs the signed WDA
# runner through Appium's xcodebuild path, then verifies ui, remote, type,
# screenshot, and server-down fail-fast against observable CLI output.
#
# Required runtime configuration (no repository/account values are hardcoded).
# Read from .sim-use-e2e.local.env (gitignored), or supplied in the environment:
#   SIM_USE_TVOS_DEVICE_UDID
#   SIM_USE_TVOS_BUNDLE_ID
#   SIM_USE_TVOS_WDA_BUNDLE_ID       product id without .xctrunner
#   SIM_USE_XCODE_ORG_ID
#
# Optional:
#   SIM_USE_XCODE_SIGNING_ID         default: Apple Development
#   SIM_USE_APPIUM_URL               reuse when reachable
#   SIM_USE_APPIUM_BIN               task-owned server binary otherwise
#   SIM_USE_TUNNEL_REGISTRY_PORT      validate/use an Appium tunnel registry
#   SIM_USE_E2E_EVIDENCE_DIR
#   SIM_USE_E2E_DERIVED_DATA
#
# Usage:
#   scripts/test-runner-tvos-device.sh --require-device
#   scripts/test-runner-tvos-device.sh --require-device --no-build
#
# Without --require-device, an absent target exits 0 with SKIP for
# hardware-free CI. Required mode never reports a skipped case.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
print_info()    { echo -e "${BLUE}ℹ️  $1${NC}"; }
print_success() { echo -e "${GREEN}✅ $1${NC}"; }
print_skip()    { echo -e "${YELLOW}⏭️  SKIP: $1${NC}"; }
print_error()   { echo -e "${RED}❌ $1${NC}"; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=load-physical-device-e2e-config.sh
source "$REPO_ROOT/scripts/load-physical-device-e2e-config.sh"
sim_use_load_physical_device_e2e_config "$REPO_ROOT"

UDID="${SIM_USE_TVOS_DEVICE_UDID:-}"
APPIUM_PORT="${SIM_USE_APPIUM_PORT:-4793}"
export SIM_USE_WDA_LOCAL_PORT="${SIM_USE_WDA_LOCAL_PORT:-8111}"
export SIM_USE_WDA_REMOTE_PORT="${SIM_USE_WDA_REMOTE_PORT:-8100}"
TUNNEL_REGISTRY_PORT="${SIM_USE_TUNNEL_REGISTRY_PORT:-}"
PLAYGROUND_DIR="Playgrounds/tvOS"
PLAYGROUND_PROJECT="$PLAYGROUND_DIR/SimUsePlaygroundTV.xcodeproj"
PLAYGROUND_SCHEME="SimUsePlaygroundTV"
DERIVED_DATA="${SIM_USE_E2E_DERIVED_DATA:-.build/PlaygroundTVDevice}"
EVIDENCE_DIR="${SIM_USE_E2E_EVIDENCE_DIR:-.build/e2e-tvos-device/$(date -u +%Y%m%dT%H%M%SZ)}"
WDA_STATE_HOME="${SIM_USE_WDA_STATE_HOME:-$EVIDENCE_DIR/wda-state-home}"
if [[ "$WDA_STATE_HOME" != /* ]]; then
    WDA_STATE_HOME="$REPO_ROOT/$WDA_STATE_HOME"
fi
export SIM_USE_WDA_STATE_HOME="$WDA_STATE_HOME"
export APPIUM_HOME="${APPIUM_HOME:-$HOME/.appium}"

SKIP_BUILD=false
REQUIRE_DEVICE=false
for arg in "$@"; do
    case "$arg" in
        -h|--help)
            sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        --no-build) SKIP_BUILD=true ;;
        --require-device) REQUIRE_DEVICE=true ;;
        *) print_error "Unknown option: $arg (see --help)"; exit 1 ;;
    esac
done

PASS_COUNT=0
FAIL_COUNT=0
FAILED_CASES=()

step() { echo; echo -e "${BLUE}── $1${NC}"; }
pass() { print_success "$1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { print_error "$1"; FAIL_COUNT=$((FAIL_COUNT + 1)); FAILED_CASES+=("$1"); }

assert_contains() {
    local file="$1" needle="$2" msg="$3"
    if grep -qF -- "$needle" "$file" 2>/dev/null; then
        pass "$msg"
    else
        fail "$msg — expected '${needle}' in ${file}"
        echo "    ---- actual (head) ----"
        head -8 "$file" | sed 's/^/    /'
    fi
}

assert_file_nonempty() {
    local path="$1" msg="$2" size
    if [[ -f "$path" ]] && size=$(stat -f%z "$path" 2>/dev/null) && [[ "$size" -gt 0 ]]; then
        pass "$msg (${size} bytes)"
    else
        fail "$msg — file missing or zero bytes: $path"
    fi
}

assert_elapsed_under() {
    local max="$1" actual="$2" msg="$3"
    if [[ "${actual%.*}" -lt "$max" ]]; then
        pass "$msg (${actual}s < ${max}s)"
    else
        fail "$msg — took ${actual}s, expected < ${max}s"
    fi
}

device_present() {
    [[ "${SIM_USE_E2E_FORCE_NO_DEVICE:-0}" == "1" ]] && return 1
    local details ids
    details="$(xcrun devicectl device info details --device "$UDID" 2>/dev/null || true)"
    if grep -qiE 'tunnelState:[[:space:]]*connected' <<<"$details"; then
        CONNECTION_METHOD="CoreDevice"
        return 0
    fi
    if command -v idevice_id >/dev/null 2>&1; then
        ids="$(idevice_id -l 2>/dev/null || true)"
        if grep -qxF "$UDID" <<<"$ids"; then
            CONNECTION_METHOD="USB fallback"
            return 0
        fi
    fi
    return 1
}

if [[ -z "$UDID" ]]; then
    if [[ "$REQUIRE_DEVICE" == true ]]; then
        print_error "Required tvOS physical device is not connected: SIM_USE_TVOS_DEVICE_UDID is unset."
        exit 1
    fi
    print_skip "SIM_USE_TVOS_DEVICE_UDID is unset; optional physical-device path not exercised."
    exit 0
fi

CONNECTION_METHOD=""
if ! device_present; then
    if [[ "$REQUIRE_DEVICE" == true ]]; then
        print_error "Required tvOS physical device is not connected: $UDID."
        print_info "Connect it through CoreDevice/RemoteXPC or USB, then re-run."
        exit 1
    elif [[ "${SIM_USE_E2E_FORCE_NO_DEVICE:-0}" == "1" ]]; then
        print_skip "SIM_USE_E2E_FORCE_NO_DEVICE=1 — device path not exercised."
    else
        print_skip "Apple TV $UDID is not connected through CoreDevice or USB."
    fi
    exit 0
fi
print_success "Target device online via $CONNECTION_METHOD: $UDID"

require_environment() {
    local name="$1"
    if [[ -z "${!name:-}" ]]; then
        print_error "$name is required for physical-device E2E."
        exit 1
    fi
}

require_environment SIM_USE_TVOS_BUNDLE_ID
require_environment SIM_USE_TVOS_WDA_BUNDLE_ID
require_environment SIM_USE_XCODE_ORG_ID

BUNDLE_ID="$SIM_USE_TVOS_BUNDLE_ID"
DEV_TEAM="$SIM_USE_XCODE_ORG_ID"
SIGNING_ID="${SIM_USE_XCODE_SIGNING_ID:-Apple Development}"
export SIM_USE_TVOS_BUNDLE_ID SIM_USE_TVOS_WDA_BUNDLE_ID SIM_USE_XCODE_ORG_ID
print_info "WDA ports: Mac $SIM_USE_WDA_LOCAL_PORT → device $SIM_USE_WDA_REMOTE_PORT"

remote_xpc_tunnel_reachable() {
    curl -fsS --max-time 3 \
        "http://127.0.0.1:$TUNNEL_REGISTRY_PORT/remotexpc/tunnels/$UDID?waitMs=2000" \
        >/dev/null 2>&1
}

if [[ -n "$TUNNEL_REGISTRY_PORT" ]]; then
    if [[ ! "$TUNNEL_REGISTRY_PORT" =~ ^[0-9]+$ ]] \
        || (( TUNNEL_REGISTRY_PORT < 1 || TUNNEL_REGISTRY_PORT > 65535 )); then
        print_error "SIM_USE_TUNNEL_REGISTRY_PORT must be an integer from 1 through 65535."
        exit 1
    fi
    export SIM_USE_TUNNEL_REGISTRY_PORT="$TUNNEL_REGISTRY_PORT"
    if ! remote_xpc_tunnel_reachable; then
        print_error "RemoteXPC tunnel registry is not serving the target Apple TV on port $TUNNEL_REGISTRY_PORT."
        print_info "Start it in another terminal, then re-run:"
        print_info 'sudo appium driver run xcuitest tunnel-creation --appletv-device-id "$SIM_USE_TVOS_DEVICE_UDID"'
        exit 1
    fi
    print_success "RemoteXPC tunnel ready on :$TUNNEL_REGISTRY_PORT"
else
    unset SIM_USE_TUNNEL_REGISTRY_PORT
    print_info "No tunnel registry override; using Appium-managed WDA fallback"
fi

if [[ "$SKIP_BUILD" == false ]]; then
    print_info "Building sim-use CLI"
    swift build
fi
SIM_USE="${SIM_USE_BIN:-$(swift build --show-bin-path)/sim-use}"
if [[ ! -x "$SIM_USE" ]]; then
    print_error "sim-use binary not found at $SIM_USE — run \`swift build\` first"
    exit 1
fi
print_info "CLI: $SIM_USE"

APPIUM_PID=""
cleanup() {
    local code=$?
    if [[ -n "$APPIUM_PID" ]] && kill -0 "$APPIUM_PID" 2>/dev/null; then
        print_info "Stopping task-owned Appium (pid $APPIUM_PID)"
        kill "$APPIUM_PID" 2>/dev/null || true
        wait "$APPIUM_PID" 2>/dev/null || true
    fi
    exit "$code"
}
trap cleanup EXIT INT TERM

appium_reachable() {
    curl -sf --max-time 3 "$1/status" >/dev/null 2>&1
}

mkdir -p "$EVIDENCE_DIR"
if [[ -n "${SIM_USE_APPIUM_URL:-}" ]] && appium_reachable "$SIM_USE_APPIUM_URL"; then
    print_success "Reusing Appium at $SIM_USE_APPIUM_URL"
else
    APPIUM_BIN="${SIM_USE_APPIUM_BIN:-$(command -v appium || true)}"
    if [[ -z "$APPIUM_BIN" || ! -x "$APPIUM_BIN" ]]; then
        print_error "No Appium server binary found."
        print_info "Install Appium with the XCUITest driver or set SIM_USE_APPIUM_BIN."
        exit 1
    fi
    export SIM_USE_APPIUM_URL="http://127.0.0.1:$APPIUM_PORT"
    APPIUM_LOG="$EVIDENCE_DIR/appium-$APPIUM_PORT.log"
    print_info "Starting task-owned Appium on :$APPIUM_PORT (APPIUM_HOME=$APPIUM_HOME)"
    "$APPIUM_BIN" --port "$APPIUM_PORT" --base-path / --log-level info >"$APPIUM_LOG" 2>&1 &
    APPIUM_PID=$!
    for _ in $(seq 1 30); do
        appium_reachable "$SIM_USE_APPIUM_URL" && break
        kill -0 "$APPIUM_PID" 2>/dev/null || {
            print_error "Appium exited early; see $APPIUM_LOG"
            exit 1
        }
        sleep 1
    done
    appium_reachable "$SIM_USE_APPIUM_URL" || {
        print_error "Appium not ready; see $APPIUM_LOG"
        exit 1
    }
    print_success "Appium ready at $SIM_USE_APPIUM_URL (pid $APPIUM_PID)"
fi

if [[ "$SKIP_BUILD" == false ]]; then
    command -v xcodegen >/dev/null 2>&1 || {
        print_error "xcodegen not found (brew install xcodegen)"
        exit 1
    }
    step "Generating + building $PLAYGROUND_SCHEME for device"
    (cd "$PLAYGROUND_DIR" && xcodegen generate | tail -1)
    xcodebuild \
        -project "$PLAYGROUND_PROJECT" -scheme "$PLAYGROUND_SCHEME" -configuration Debug \
        -destination "platform=tvOS,id=$UDID" -derivedDataPath "$DERIVED_DATA" \
        CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$DEV_TEAM" \
        CODE_SIGN_IDENTITY="$SIGNING_ID" PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
        -allowProvisioningUpdates build | tail -2

    APP_PATH="$(find "$DERIVED_DATA/Build/Products" -name "$PLAYGROUND_SCHEME.app" -maxdepth 2 | head -1)"
    [[ -n "$APP_PATH" ]] || {
        print_error "Built .app not found under $DERIVED_DATA"
        exit 1
    }
    print_info "Installing $BUNDLE_ID"
    xcrun devicectl device install app --device "$UDID" "$APP_PATH" >/dev/null
    print_success "Fixture installed"
fi

tvos_ui() {
    "$SIM_USE" tvos ui --device "$UDID" --bundle-id "$BUNDLE_ID" "$@"
}
tvos_remote() {
    "$SIM_USE" tvos remote "$1" --device "$UDID" --bundle-id "$BUNDLE_ID" "${@:2}"
}
tvos_screenshot() {
    "$SIM_USE" tvos screenshot --device "$UDID" --bundle-id "$BUNDLE_ID" "$@"
}
tvos_type() {
    "$SIM_USE" tvos type "$1" --device "$UDID" --bundle-id "$BUNDLE_ID" "${@:2}"
}
launch_grid() {
    xcrun devicectl device process launch \
        --terminate-existing --device "$UDID" "$BUNDLE_ID" \
        --launch-arg screen=grid >/dev/null
    sleep 2
}
launch_text() {
    xcrun devicectl device process launch \
        --terminate-existing --device "$UDID" "$BUNDLE_ID" \
        --launch-arg screen=text >/dev/null
    sleep 2
}

launch_grid

# Prime/repair the signed runner once through the xcodebuild path. Subsequent
# cases use the retained supervisor when a registry was explicitly configured,
# or the Appium-managed signing-cache fallback otherwise.
step "WDA — repair/install the signed physical-tvOS runner"
SIM_USE_TVOS_WDA_SUPERVISOR=0 tvos_ui > "$EVIDENCE_DIR/wda-prime.txt" 2>&1 || true
assert_contains "$EVIDENCE_DIR/wda-prime.txt" "SimUsePlaygroundTV" "WDA: signed runner serves the fixture"

step "ui — reports the fixture and focused Alpha button"
tvos_ui > "$EVIDENCE_DIR/ui-grid.txt" 2>&1 || true
assert_contains "$EVIDENCE_DIR/ui-grid.txt" "SimUsePlaygroundTV" "ui: outline names the fixture"
assert_contains "$EVIDENCE_DIR/ui-grid.txt" "\"Alpha\"" "ui: outline contains Alpha"
assert_contains "$EVIDENCE_DIR/ui-grid.txt" "focused" "ui: outline identifies current focus"

step "remote — right moves focus to Bravo; select activates it"
tvos_remote right --report-focus --json > "$EVIDENCE_DIR/remote-right.json" 2>&1 || true
assert_contains "$EVIDENCE_DIR/remote-right.json" '"label":"Bravo"' "remote: right moves focus to Bravo"
tvos_remote select > "$EVIDENCE_DIR/remote-select.txt" 2>&1 || true
tvos_ui > "$EVIDENCE_DIR/ui-after-select.txt" 2>&1 || true
assert_contains "$EVIDENCE_DIR/ui-after-select.txt" "Last: Bravo" "remote: select activates Bravo"

step "type — enters text through the focused physical-tvOS field"
launch_text
tvos_ui > "$EVIDENCE_DIR/ui-before-type.txt" 2>&1 || true
assert_contains "$EVIDENCE_DIR/ui-before-type.txt" "TextField" "type: fixture exposes a focused text field"
TYPE_TOKEN="TVE2E$RANDOM"
tvos_type "$TYPE_TOKEN" > "$EVIDENCE_DIR/type.txt" 2>&1 || true
assert_contains "$EVIDENCE_DIR/type.txt" "Typed \"$TYPE_TOKEN\"" "type: device command reports the entered token"
tvos_ui > "$EVIDENCE_DIR/ui-after-type.txt" 2>&1 || true
assert_contains "$EVIDENCE_DIR/ui-after-type.txt" "$TYPE_TOKEN" "type: fresh outline contains the entered token"

step "screenshot — captures a non-empty physical-tvOS PNG"
SCREENSHOT_PATH="$EVIDENCE_DIR/screenshot.png"
rm -f -- "$SCREENSHOT_PATH"
tvos_screenshot --output "$SCREENSHOT_PATH" > "$EVIDENCE_DIR/screenshot.txt" 2>&1 || true
assert_file_nonempty "$SCREENSHOT_PATH" "screenshot: PNG has bytes"

step "fail-fast — a down Appium server returns immediately"
DEAD_URL="http://127.0.0.1:4999"
START=$(date +%s)
SIM_USE_APPIUM_URL="$DEAD_URL" tvos_ui --json > "$EVIDENCE_DIR/failfast.txt" 2>&1 || true
ELAPSED=$(( $(date +%s) - START ))
assert_contains "$EVIDENCE_DIR/failfast.txt" '"ok":false' "fail-fast: envelope reports ok:false"
assert_contains "$EVIDENCE_DIR/failfast.txt" "not reachable" "fail-fast: names the unreachable server"
assert_elapsed_under 5 "$ELAPSED" "fail-fast: returns without hanging"

echo
echo -e "${BLUE}================ tvOS device E2E results ================${NC}"
print_success "$PASS_COUNT assertion(s) passed"
if [[ "$FAIL_COUNT" -gt 0 ]]; then
    print_error "$FAIL_COUNT assertion(s) failed:"
    for case_name in "${FAILED_CASES[@]}"; do
        echo -e "   ${RED}• $case_name${NC}"
    done
    exit 1
fi
print_success "tvOS device E2E green — evidence in $EVIDENCE_DIR/"
