#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# iOS physical-device E2E runner for the sim-use DeviceBackend verbs.
#
# Drives the six tracer verbs (ui / tap / type / paste / swipe / screenshot)
# of the top-level cross-platform CLI against the SimUsePlayground fixture on
# a USB-connected iPhone, and asserts an *observable* effect for each (an
# outline that names a playground element, a screen that changes after a tap,
# a text field that reflects typed / pasted text, a screenshot file with
# bytes). A seventh case pins the server-down fail-fast (instant, ok:false).
#
# This is a bash verification tool, not an XCTest suite: every assertion is a
# programmatic check over the CLI's own stdout/JSON, so a broken verb turns a
# case red without a simulator in the loop (the Mac-side sim XCTest daemon is
# deliberately never touched — this path is device-only).
#
# By default, a missing device remains a clean SKIP for hardware-free CI.
# Release gates pass `--require-device`, which turns the same state into a
# non-zero failure and guarantees the run contains no skipped cases.
#
# ---------------------------------------------------------------------------
# Preconditions when a device IS present (else the runner errors with the fix)
# ---------------------------------------------------------------------------
#   * sim-use built locally (the runner runs `swift build` unless --no-build).
#   * xcodegen + an iOS-capable Xcode toolchain (fixture build + signing).
#   * An Appium 3.x server binary with the xcuitest driver installed under
#     APPIUM_HOME (default ~/.appium). Discovered via SIM_USE_APPIUM_BIN or
#     PATH; the runner starts a task-owned server on SIM_USE_APPIUM_PORT
#     (default 4792) and tears it down on exit. Set SIM_USE_APPIUM_URL to
#     reuse an already-running server instead.
#   * WDA signing inputs that match the target device. On a cache hit the CLI
#     selects Appium's test-without-building path; on a miss it performs one
#     incremental build/sign in the stable per-UDID DerivedData directory.
#     The first successful session writes wda-signing-config.json, so later
#     daily commands do not need the signing variables exported again.
#   * Explicit, repository-local signing values loaded at runtime from
#     .sim-use-e2e.local.env (gitignored), or supplied in the environment:
#       SIM_USE_DEVICE_UDID
#       SIM_USE_PLAYGROUND_BUNDLE_ID
#       SIM_USE_WDA_BUNDLE_ID
#       SIM_USE_XCODE_ORG_ID
#     The generic runner deliberately contains no developer/team/app defaults.
#
# Usage:
#   scripts/test-runner-ios-device.sh --require-device
#   scripts/test-runner-ios-device.sh --require-device --no-build
#   SIM_USE_E2E_FORCE_NO_DEVICE=1 scripts/test-runner-ios-device.sh  # SKIP path
#
# Exit codes: 0 = all green, or optional mode skipped an absent device;
# 1 = an assertion/precondition failed. Required mode never exits 0 on SKIP.

set -euo pipefail

# --- pretty output (mirrors scripts/test-runner-tvos.sh) --------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
print_info()    { echo -e "${BLUE}ℹ️  $1${NC}"; }
print_success() { echo -e "${GREEN}✅ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
print_error()   { echo -e "${RED}❌ $1${NC}"; }
print_skip()    { echo -e "${YELLOW}⏭️  SKIP: $1${NC}"; }

# --- configuration (all env-overridable) ------------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=load-physical-device-e2e-config.sh
source "$REPO_ROOT/scripts/load-physical-device-e2e-config.sh"
sim_use_load_physical_device_e2e_config "$REPO_ROOT"

UDID="${SIM_USE_DEVICE_UDID:-}"
APPIUM_PORT="${SIM_USE_APPIUM_PORT:-4792}"
export SIM_USE_WDA_LOCAL_PORT="${SIM_USE_WDA_LOCAL_PORT:-8110}"
export SIM_USE_WDA_REMOTE_PORT="${SIM_USE_WDA_REMOTE_PORT:-8100}"
PLAYGROUND_DIR="Playgrounds/iOS"
PLAYGROUND_PROJECT="$PLAYGROUND_DIR/SimUsePlayground.xcodeproj"
PLAYGROUND_SCHEME="SimUsePlayground"
DERIVED_DATA="${SIM_USE_E2E_DERIVED_DATA:-.build/PlaygroundiOS}"
EVIDENCE_DIR="${SIM_USE_E2E_EVIDENCE_DIR:-.build/e2e-ios-device/$(date -u +%Y%m%dT%H%M%SZ)}"
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
            sed -n '2,60p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        --no-build) SKIP_BUILD=true ;;
        --require-device) REQUIRE_DEVICE=true ;;
        *) print_error "Unknown option: $arg (see --help)"; exit 1 ;;
    esac
done

# --- assertion accounting ---------------------------------------------------
PASS_COUNT=0
FAIL_COUNT=0
FAILED_CASES=()

step()  { echo; echo -e "${BLUE}── $1${NC}"; }
pass()  { print_success "$1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail()  { print_error "$1"; FAIL_COUNT=$((FAIL_COUNT + 1)); FAILED_CASES+=("$1"); }

# assert_contains <file> <needle> <case-msg>
# Case red when <needle> is absent from <file>. Comparison logic lives here so
# every verb assertion funnels through one checked helper (mutation-tested).
assert_contains() {
    local file="$1" needle="$2" msg="$3"
    if grep -qF -- "$needle" "$file" 2>/dev/null; then
        pass "$msg"
    else
        fail "$msg — expected '${needle}' in ${file}"
        echo "    ---- actual (head) ----"; head -8 "$file" | sed 's/^/    /'
    fi
}

# assert_absent <file> <needle> <case-msg>
assert_absent() {
    local file="$1" needle="$2" msg="$3"
    if grep -qF -- "$needle" "$file" 2>/dev/null; then
        fail "$msg — did not expect '${needle}' in ${file}"
    else
        pass "$msg"
    fi
}

# assert_file_nonempty <path> <case-msg>
assert_file_nonempty() {
    local path="$1" msg="$2" size
    if [[ -f "$path" ]] && size=$(stat -f%z "$path" 2>/dev/null) && [[ "$size" -gt 0 ]]; then
        pass "$msg (${size} bytes)"
    else
        fail "$msg — file missing or zero bytes: $path"
    fi
}

# Millisecond-precision wall clock. `date +%s` truncates to whole seconds,
# so a 4.3s fail-fast measured across second boundaries could read as 5 and
# trip the < 5s assertion on rounding alone (cold devicectl discovery of a
# network-paired Apple TV costs ~4s on the first scan).
epoch_now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }

# assert_elapsed_under <max-seconds> <actual-seconds> <case-msg>
assert_elapsed_under() {
    local max="$1" actual="$2" msg="$3"
    if [[ ! "$actual" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        fail "$msg — invalid elapsed time '${actual}'"
        return
    fi
    # integer-second comparison; sub-second values floor to 0 and pass.
    if [[ "${actual%.*}" -lt "$max" ]]; then
        pass "$msg (${actual}s < ${max}s)"
    else
        fail "$msg — took ${actual}s, expected < ${max}s"
    fi
}

# --- device detection: CoreDevice first, live USB fallback -----------------
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
        print_error "Required iOS physical device is not connected: SIM_USE_DEVICE_UDID is unset."
        exit 1
    fi
    print_skip "SIM_USE_DEVICE_UDID is unset; optional physical-device path not exercised."
    exit 0
fi

CONNECTION_METHOD=""
if ! device_present; then
    if [[ "$REQUIRE_DEVICE" == true ]]; then
        print_error "Required iOS physical device is not connected: $UDID."
        print_info "Connect it through CoreDevice/RemoteXPC or USB, then re-run."
        exit 1
    elif [[ "${SIM_USE_E2E_FORCE_NO_DEVICE:-0}" == "1" ]]; then
        print_skip "SIM_USE_E2E_FORCE_NO_DEVICE=1 — device path not exercised."
    else
        print_skip "iPhone $UDID is not connected through CoreDevice or USB."
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

require_environment SIM_USE_PLAYGROUND_BUNDLE_ID
require_environment SIM_USE_WDA_BUNDLE_ID
require_environment SIM_USE_XCODE_ORG_ID

BUNDLE_ID="$SIM_USE_PLAYGROUND_BUNDLE_ID"
DEV_TEAM="$SIM_USE_XCODE_ORG_ID"
SIGNING_ID="${SIM_USE_XCODE_SIGNING_ID:-Apple Development}"
export SIM_USE_WDA_BUNDLE_ID SIM_USE_XCODE_ORG_ID
print_info "WDA ports: Mac $SIM_USE_WDA_LOCAL_PORT → device $SIM_USE_WDA_REMOTE_PORT"

# --- resolve the sim-use binary ---------------------------------------------
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

# --- Appium: reuse a reachable server, else start a task-owned one -----------
APPIUM_PID=""
cleanup() {
    local code=$?
    if [[ -n "$APPIUM_PID" ]] && kill -0 "$APPIUM_PID" 2>/dev/null; then
        print_info "Stopping task-owned Appium (pid $APPIUM_PID)"
        kill "$APPIUM_PID" 2>/dev/null || true
        wait "$APPIUM_PID" 2>/dev/null || true
    fi
    exit $code
}
trap cleanup EXIT INT TERM

appium_reachable() {
    curl -sf --max-time 3 "$1/status" >/dev/null 2>&1
}

if [[ -n "${SIM_USE_APPIUM_URL:-}" ]] && appium_reachable "$SIM_USE_APPIUM_URL"; then
    print_success "Reusing Appium at $SIM_USE_APPIUM_URL"
else
    APPIUM_BIN="${SIM_USE_APPIUM_BIN:-$(command -v appium || true)}"
    if [[ -z "$APPIUM_BIN" || ! -x "$APPIUM_BIN" ]]; then
        print_error "No Appium server binary found."
        print_info  "Install one (npm i -g appium@3 && appium driver install xcuitest)"
        print_info  "or point SIM_USE_APPIUM_BIN at an appium executable, then re-run."
        exit 1
    fi
    export SIM_USE_APPIUM_URL="http://127.0.0.1:$APPIUM_PORT"
    APPIUM_LOG="$EVIDENCE_DIR/appium-$APPIUM_PORT.log"
    mkdir -p "$EVIDENCE_DIR"
    print_info "Starting task-owned Appium on :$APPIUM_PORT (APPIUM_HOME=$APPIUM_HOME)"
    "$APPIUM_BIN" --port "$APPIUM_PORT" --base-path / --log-level info >"$APPIUM_LOG" 2>&1 &
    APPIUM_PID=$!
    for _ in $(seq 1 30); do
        appium_reachable "$SIM_USE_APPIUM_URL" && break
        kill -0 "$APPIUM_PID" 2>/dev/null || { print_error "Appium exited early; see $APPIUM_LOG"; exit 1; }
        sleep 1
    done
    appium_reachable "$SIM_USE_APPIUM_URL" || { print_error "Appium not ready; see $APPIUM_LOG"; exit 1; }
    print_success "Appium ready at $SIM_USE_APPIUM_URL (pid $APPIUM_PID)"
fi

# --- fixture: generate → sign for device → install --------------------------
if [[ "$SKIP_BUILD" == false ]]; then
    command -v xcodegen >/dev/null 2>&1 || { print_error "xcodegen not found (brew install xcodegen)"; exit 1; }
    step "Generating + building $PLAYGROUND_SCHEME for device"
    (cd "$PLAYGROUND_DIR" && xcodegen generate | tail -1)
    # project.yml ships CODE_SIGNING_ALLOWED=NO for the simulator. Keep the
    # committed fixture generic and inject every account-specific value here.
    xcodebuild \
        -project "$PLAYGROUND_PROJECT" -scheme "$PLAYGROUND_SCHEME" -configuration Debug \
        -destination "platform=iOS,id=$UDID" -derivedDataPath "$DERIVED_DATA" \
        CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$DEV_TEAM" \
        CODE_SIGN_IDENTITY="$SIGNING_ID" PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
        -allowProvisioningUpdates build | tail -2

    APP_PATH="$(find "$DERIVED_DATA/Build/Products" -name "$PLAYGROUND_SCHEME.app" -maxdepth 2 | head -1)"
    [[ -n "$APP_PATH" ]] || { print_error "Built .app not found under $DERIVED_DATA"; exit 1; }
    print_info "Installing $BUNDLE_ID"
    xcrun devicectl device install app --device "$UDID" "$APP_PATH" >/dev/null
    print_success "Fixture installed"
fi

mkdir -p "$EVIDENCE_DIR"

# thin verb wrappers -> always target the device UDID
ui()         { "$SIM_USE" ui --udid "$UDID" "$@"; }
tap()        { "$SIM_USE" tap --udid "$UDID" "$@"; }
type_text()  { "$SIM_USE" type --udid "$UDID" "$@"; }
paste_text() { "$SIM_USE" paste --udid "$UDID" "$@"; }
swipe()      { "$SIM_USE" swipe --udid "$UDID" "$@"; }
screenshot() { "$SIM_USE" screenshot --udid "$UDID" "$@"; }

DEAD_URL="http://127.0.0.1:4999"   # nothing listens here → fail-fast target

launch_root() {
    xcrun devicectl device process launch \
        --terminate-existing --device "$UDID" "$BUNDLE_ID" >/dev/null
    sleep 2
}
launch_screen() {
    local screen="$1"
    xcrun devicectl device process launch \
        --terminate-existing --device "$UDID" "$BUNDLE_ID" \
        --launch-arg "screen=$screen" >/dev/null
    sleep 2
}

# ── case 1: describe-ui names a fixture element ─────────────────────────────
step "ui — describe-ui outlines the SimUsePlayground menu"
launch_root
ui --bundle-id "$BUNDLE_ID" > "$EVIDENCE_DIR/ui-menu.txt" 2>&1 || true
assert_contains "$EVIDENCE_DIR/ui-menu.txt" "sim-use Playground" "ui: outline shows the playground nav title"
assert_contains "$EVIDENCE_DIR/ui-menu.txt" "Text Input"         "ui: outline lists the Text Input row"

# ── case 2: screenshot writes a non-empty PNG ───────────────────────────────
step "screenshot — captures a non-empty PNG"
SCREENSHOT_PATH="$EVIDENCE_DIR/screenshot.png"
rm -f -- "$SCREENSHOT_PATH"
screenshot --bundle-id "$BUNDLE_ID" --output "$SCREENSHOT_PATH" \
    > "$EVIDENCE_DIR/screenshot.txt" 2>&1 || true
assert_file_nonempty "$SCREENSHOT_PATH" "screenshot: PNG has bytes"

# ── case 3: tap changes the fixture's visible screen ────────────────────────
step "tap — opens the Text Input screen"
tap --bundle-id "$BUNDLE_ID" --label "Text Input" \
    --wait-timeout 2 --pre-delay 0.1 --post-delay 0.1 \
    > "$EVIDENCE_DIR/tap.txt" 2>&1 || true
assert_contains "$EVIDENCE_DIR/tap.txt" "completed successfully" "tap: selector resolved + tap dispatched"
ui --bundle-id "$BUNDLE_ID" > "$EVIDENCE_DIR/ui-after-tap.txt" 2>&1 || true
assert_contains "$EVIDENCE_DIR/ui-after-tap.txt" "Text Input Playground" "tap: fixture navigated to Text Input"
assert_absent "$EVIDENCE_DIR/ui-after-tap.txt" "Gesture Presets" "tap: fixture left the main menu"

# ── case 4: type is reflected in the focused field ──────────────────────────
step "type — field echoes the typed token"
TYPE_TOKEN="E2Etype$RANDOM"
tap --bundle-id "$BUNDLE_ID" --id text-input-field > "$EVIDENCE_DIR/tap-field.txt" 2>&1 || true
type_text --bundle-id "$BUNDLE_ID" "$TYPE_TOKEN" > "$EVIDENCE_DIR/type.txt" 2>&1 || true
ui --bundle-id "$BUNDLE_ID" > "$EVIDENCE_DIR/ui-after-type.txt" 2>&1 || true
assert_contains "$EVIDENCE_DIR/ui-after-type.txt" "$TYPE_TOKEN" "type: field echoes the typed token"

# ── case 5: paste + --replace are reflected in the focused field ────────────
step "paste — field echoes text and --replace removes the prior value"
launch_screen paste-test
tap --bundle-id "$BUNDLE_ID" --id paste-input-field > "$EVIDENCE_DIR/tap-paste-field.txt" 2>&1 || true
PASTE_OLD_TOKEN="E2Eold$RANDOM"
PASTE_NEW_TOKEN="E2Enew$RANDOM"
paste_text --bundle-id "$BUNDLE_ID" "$PASTE_OLD_TOKEN" > "$EVIDENCE_DIR/paste.txt" 2>&1 || true
paste_text --bundle-id "$BUNDLE_ID" --replace "$PASTE_NEW_TOKEN" \
    > "$EVIDENCE_DIR/paste-replace.txt" 2>&1 || true
ui --bundle-id "$BUNDLE_ID" > "$EVIDENCE_DIR/ui-after-paste.txt" 2>&1 || true
assert_contains "$EVIDENCE_DIR/ui-after-paste.txt" "$PASTE_NEW_TOKEN" "paste: --replace leaves the replacement token"
assert_absent "$EVIDENCE_DIR/ui-after-paste.txt" "$PASTE_OLD_TOKEN" "paste: --replace removes the prior token"

# ── case 6: swipe moves the app's visible list window ───────────────────────
step "swipe — lower menu rows become visible"
launch_root
swipe --bundle-id "$BUNDLE_ID" --from 220,750 --to 220,250 --duration 0.3 \
    --pre-delay 0.1 --post-delay 0.1 \
    > "$EVIDENCE_DIR/swipe.txt" 2>&1 || true
assert_contains "$EVIDENCE_DIR/swipe.txt" "completed successfully" "swipe: gesture dispatched"
ui --bundle-id "$BUNDLE_ID" > "$EVIDENCE_DIR/ui-after-swipe.txt" 2>&1 || true
assert_contains "$EVIDENCE_DIR/ui-after-swipe.txt" "Batch Login Flow" "swipe: lower menu rows are visible"

# ── case 7: fail-fast when the Appium server is down (instant) ──────────────
step "fail-fast — a down server returns instantly with ok:false"
START=$(epoch_now)
SIM_USE_APPIUM_URL="$DEAD_URL" ui --bundle-id "$BUNDLE_ID" --json \
    > "$EVIDENCE_DIR/failfast.txt" 2>&1 || true
ELAPSED=$(awk "BEGIN{printf \"%.1f\", $(epoch_now) - $START}")
assert_contains      "$EVIDENCE_DIR/failfast.txt" '"ok":false'    "fail-fast: envelope reports ok:false"
assert_contains      "$EVIDENCE_DIR/failfast.txt" "not reachable" "fail-fast: names the unreachable server"
assert_elapsed_under 5 "$ELAPSED"                                 "fail-fast: returns without hanging"

# Keep keyboard verbs pinned to the same fail-fast contract independently.
step "type — a down server fails fast"
START=$(epoch_now)
SIM_USE_APPIUM_URL="$DEAD_URL" type_text --bundle-id "$BUNDLE_ID" "wired?" --json \
    > "$EVIDENCE_DIR/type-failfast.txt" 2>&1 || true
ELAPSED=$(awk "BEGIN{printf \"%.1f\", $(epoch_now) - $START}")
assert_contains      "$EVIDENCE_DIR/type-failfast.txt" '"ok":false' "type: routes to device + fail-fast ok:false"
assert_elapsed_under 5 "$ELAPSED"                                  "type: fail-fast is instant"

step "paste — a down server fails fast"
START=$(epoch_now)
SIM_USE_APPIUM_URL="$DEAD_URL" paste_text --bundle-id "$BUNDLE_ID" "wired?" --json \
    > "$EVIDENCE_DIR/paste-failfast.txt" 2>&1 || true
ELAPSED=$(awk "BEGIN{printf \"%.1f\", $(epoch_now) - $START}")
assert_contains      "$EVIDENCE_DIR/paste-failfast.txt" '"ok":false' "paste: routes to device + fail-fast ok:false"
assert_elapsed_under 5 "$ELAPSED"                                   "paste: fail-fast is instant"

# --- summary ----------------------------------------------------------------
echo
echo -e "${BLUE}================ iOS device E2E results ================${NC}"
print_success "$PASS_COUNT assertion(s) passed"
if [[ "$FAIL_COUNT" -gt 0 ]]; then
    print_error "$FAIL_COUNT assertion(s) failed:"
    for c in "${FAILED_CASES[@]}"; do echo -e "   ${RED}• $c${NC}"; done
    exit 1
fi
print_success "iOS device E2E green — evidence in $EVIDENCE_DIR/"
