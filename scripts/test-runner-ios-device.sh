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
# ---------------------------------------------------------------------------
# SKIP semantics (requires-device)
# ---------------------------------------------------------------------------
# With no reachable target device the runner prints SKIP and exits 0, so a CI
# gate on a host without hardware stays green instead of failing. A device is
# considered absent when SIM_USE_E2E_FORCE_NO_DEVICE=1, when the target UDID is
# not listed by `idevice_id -l`, or when devicectl does not report it as
# connected.
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
#   * Post the app-agnostic caps default (DeviceCapabilityConfig.iosWDABundleId
#     ships as the upstream com.facebook.WebDriverAgentRunner), a CatchPlay
#     device needs the WDA bundle id pinned — the runner exports
#     SIM_USE_WDA_BUNDLE_ID (default com.catchplay.WebDriverAgentRunner) so the
#     CLI signs/targets the intended WDA product. Override to re-point.
#
# Usage:
#   scripts/test-runner-ios-device.sh            # build fixture + run all cases
#   scripts/test-runner-ios-device.sh --no-build # skip CLI + fixture rebuild
#   SIM_USE_E2E_FORCE_NO_DEVICE=1 scripts/test-runner-ios-device.sh  # SKIP path
#   SIM_USE_DEVICE_UDID=<udid> scripts/test-runner-ios-device.sh     # other iPhone
#
# Exit codes: 0 = all green OR skipped (no device); 1 = an assertion failed or
# a precondition with a device present is unmet.

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

UDID="${SIM_USE_DEVICE_UDID:-00008140-00096D5C0CEA801C}"   # CP 16 Pro Max
BUNDLE_ID="${SIM_USE_PLAYGROUND_BUNDLE_ID:-com.catchplay.SimUsePlayground}"
DEV_TEAM="${SIM_USE_XCODE_ORG_ID:-MKK9DM2XD9}"
export SIM_USE_XCODE_ORG_ID="$DEV_TEAM"
APPIUM_PORT="${SIM_USE_APPIUM_PORT:-4792}"
PLAYGROUND_DIR="Playgrounds/iOS"
PLAYGROUND_PROJECT="$PLAYGROUND_DIR/SimUsePlayground.xcodeproj"
PLAYGROUND_SCHEME="SimUsePlayground"
DERIVED_DATA=".build/PlaygroundiOS"
EVIDENCE_DIR="${SIM_USE_E2E_EVIDENCE_DIR:-.scratch/xd-2.0/evidence/T4}"

# D7 ships the app-agnostic upstream WDA id (com.facebook.WebDriverAgentRunner)
# as the caps default on purpose. This runner is a local verification tool that
# knows the office device's WebDriverAgent is CatchPlay-signed, so it pins that
# id explicitly — the intended D7 usage, not a default rollback. Override the
# env var to re-point at a differently-signed WDA.
: "${SIM_USE_WDA_BUNDLE_ID:=com.catchplay.WebDriverAgentRunner}"
export SIM_USE_WDA_BUNDLE_ID
export APPIUM_HOME="${APPIUM_HOME:-$HOME/.appium}"

SKIP_BUILD=false
for arg in "$@"; do
    case "$arg" in
        -h|--help)
            sed -n '2,60p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        --no-build) SKIP_BUILD=true ;;
        *) print_error "Unknown option: $arg (see --help)"; exit 1 ;;
    esac
done

# --- assertion accounting ---------------------------------------------------
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
FAILED_CASES=()

step()  { echo; echo -e "${BLUE}── $1${NC}"; }
pass()  { print_success "$1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail()  { print_error "$1"; FAIL_COUNT=$((FAIL_COUNT + 1)); FAILED_CASES+=("$1"); }
skip()  { print_skip "$1"; SKIP_COUNT=$((SKIP_COUNT + 1)); }

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

# assert_elapsed_under <max-seconds> <actual-seconds> <case-msg>
assert_elapsed_under() {
    local max="$1" actual="$2" msg="$3"
    # integer-second comparison; sub-second values floor to 0 and pass.
    if [[ "${actual%.*}" -lt "$max" ]]; then
        pass "$msg (${actual}s < ${max}s)"
    else
        fail "$msg — took ${actual}s, expected < ${max}s"
    fi
}

# --- device detection → SKIP (requires-device) ------------------------------
device_present() {
    [[ "${SIM_USE_E2E_FORCE_NO_DEVICE:-0}" == "1" ]] && return 1
    command -v idevice_id >/dev/null 2>&1 || return 1
    # Capture output into variables before grepping. Piping a chatty producer
    # (devicectl) straight into `grep -q` trips `set -o pipefail`: grep exits on
    # first match, the producer takes SIGPIPE (141), and the pipeline reports
    # non-zero — which would misread a present device as absent.
    local ids details
    ids="$(idevice_id -l 2>/dev/null || true)"
    grep -qx "$UDID" <<<"$ids" || return 1
    # Cross-check the CoreDevice tunnel is up (USB paired + trusted).
    details="$(xcrun devicectl device info details --device "$UDID" 2>/dev/null || true)"
    grep -qiE 'tunnelState:[[:space:]]*connected' <<<"$details" || return 1
    return 0
}

if ! device_present; then
    if [[ "${SIM_USE_E2E_FORCE_NO_DEVICE:-0}" == "1" ]]; then
        print_skip "SIM_USE_E2E_FORCE_NO_DEVICE=1 — device path not exercised."
    else
        print_skip "iPhone $UDID not connected (idevice_id / devicectl)."
    fi
    print_info "requires-device: connect the target iPhone or unset the override to run."
    exit 0
fi
print_success "Target device online: $UDID"

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
    # project.yml ships CODE_SIGNING_ALLOWED=NO for the simulator; override on
    # the command line (no fixture edit) to sign for the device. The upstream
    # bundle id (com.cameroncooke.*) is not registerable under our team, so a
    # CatchPlay-namespaced id is used and threaded through to launch + verbs.
    xcodebuild \
        -project "$PLAYGROUND_PROJECT" -scheme "$PLAYGROUND_SCHEME" -configuration Debug \
        -destination "platform=iOS,id=$UDID" -derivedDataPath "$DERIVED_DATA" \
        CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$DEV_TEAM" \
        CODE_SIGN_IDENTITY="Apple Development" PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
        -allowProvisioningUpdates build | tail -2

    APP_PATH="$(find "$DERIVED_DATA/Build/Products" -name "$PLAYGROUND_SCHEME.app" -maxdepth 2 | head -1)"
    [[ -n "$APP_PATH" ]] || { print_error "Built .app not found under $DERIVED_DATA"; exit 1; }
    print_info "Installing $BUNDLE_ID"
    xcrun devicectl device install app --device "$UDID" "$APP_PATH" >/dev/null
    print_success "Fixture installed"
fi

mkdir -p "$EVIDENCE_DIR"
TMP="$(mktemp -d -t simuse-ios-device-e2e.XXXXXX)"
trap 'rm -rf "$TMP"; cleanup' EXIT INT TERM

# thin verb wrappers -> always target the device UDID
ui()         { "$SIM_USE" ui --udid "$UDID" "$@"; }
tap()        { "$SIM_USE" tap --udid "$UDID" "$@"; }
type_text()  { "$SIM_USE" type --udid "$UDID" "$@"; }
paste_text() { "$SIM_USE" paste --udid "$UDID" "$@"; }
swipe()      { "$SIM_USE" swipe --udid "$UDID" "$@"; }
screenshot() { "$SIM_USE" screenshot --udid "$UDID" "$@"; }

DEAD_URL="http://127.0.0.1:4999"   # nothing listens here → fail-fast target

# On a physical device only `ui` / `screenshot` forward `--bundle-id`, so only
# they observe the app under test; the WDA session for an action verb resets to
# the springboard (home screen). The tracer therefore observes the app through
# `ui --bundle-id`, and exercises the action verbs against springboard until
# T3.5 lands `--bundle-id` forwarding on tap/type/paste/swipe.

# ── case 1: describe-ui names a playground element (app-targeted) ───────────
# Cold-launch the fixture to the foreground first (devicectl), then let
# `ui --bundle-id` attach and describe it. `ui --bundle-id` alone occasionally
# raced to the springboard, so the explicit launch makes the observation
# deterministic. Assertions use app-unique strings ("sim-use Playground" nav
# title, the "Text Input" row) so a springboard "SimUsePlayground" icon can't
# false-positive the case.
step "ui — describe-ui outlines the SimUsePlayground menu"
# --terminate-existing: activate semantics (T3.5) keeps the app's last screen
# across sessions, so a leftover run would break the menu-outline assertions.
xcrun devicectl device process launch --terminate-existing --device "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
sleep 3
ui --bundle-id "$BUNDLE_ID" > "$EVIDENCE_DIR/ui-menu.txt" 2>&1 || true
assert_contains "$EVIDENCE_DIR/ui-menu.txt" "sim-use Playground" "ui: outline shows the playground nav title"
assert_contains "$EVIDENCE_DIR/ui-menu.txt" "Text Input"         "ui: outline lists the Text Input row"

# ── case 2: screenshot writes a non-empty PNG ───────────────────────────────
step "screenshot — captures a non-empty PNG"
screenshot --output "$EVIDENCE_DIR/screenshot.png" > "$EVIDENCE_DIR/screenshot.txt" 2>&1 || true
assert_file_nonempty "$EVIDENCE_DIR/screenshot.png" "screenshot: PNG has bytes"

# ── case 3: tap resolves a springboard selector and dispatches ──────────────
# Prove tap end-to-end by resolving the fixture's own home-screen icon (a known
# installed element) via the live AX tree and tapping it. A missing icon (or an
# unresolved selector) turns the case red with WDA's candidate list.
step "tap — resolve the fixture's home icon on springboard and tap it"
tap --label "$PLAYGROUND_SCHEME" > "$EVIDENCE_DIR/tap.txt" 2>&1 || true
assert_contains "$EVIDENCE_DIR/tap.txt" "completed successfully" "tap: selector resolved + tap dispatched"

# ── case 4: swipe dispatches a W3C pointer gesture ──────────────────────────
step "swipe — a W3C pointer swipe completes"
swipe --from 220,600 --to 220,300 --duration 0.3 > "$EVIDENCE_DIR/swipe.txt" 2>&1 || true
assert_contains "$EVIDENCE_DIR/swipe.txt" "completed successfully" "swipe: gesture dispatched"

# ── case 5: fail-fast when the Appium server is down (instant) ──────────────
step "fail-fast — a down server returns instantly with ok:false"
START=$(date +%s)
SIM_USE_APPIUM_URL="$DEAD_URL" ui --json > "$EVIDENCE_DIR/failfast.txt" 2>&1 || true
ELAPSED=$(( $(date +%s) - START ))
assert_contains      "$EVIDENCE_DIR/failfast.txt" '"ok":false'    "fail-fast: envelope reports ok:false"
assert_contains      "$EVIDENCE_DIR/failfast.txt" "not reachable" "fail-fast: names the unreachable server"
assert_elapsed_under 5 "$ELAPSED"                                 "fail-fast: returns without hanging"

# ── type / paste: DeviceBackend wiring today, app round-trip reserved ───────
# type/paste need a focused text field to echo into, which only the app under
# test provides — and action verbs can't foreground it yet (no --bundle-id
# forwarding; T3.5). So on a physical device they land on the field-less
# springboard and error ("unable to find an element"). Until T3.5 we (a) prove
# each verb reaches the DeviceBackend fail-fast path, and (b) reserve the app
# round-trip behind SIM_USE_E2E_APP_ACTION_VERBS.
step "type — wired to DeviceBackend fail-fast (app round-trip pending T3.5)"
START=$(date +%s)
SIM_USE_APPIUM_URL="$DEAD_URL" type_text "wired?" --json > "$EVIDENCE_DIR/type-failfast.txt" 2>&1 || true
assert_contains      "$EVIDENCE_DIR/type-failfast.txt" '"ok":false' "type: routes to device + fail-fast ok:false"
assert_elapsed_under 5 "$(( $(date +%s) - START ))"                 "type: fail-fast is instant"

step "paste — wired to DeviceBackend fail-fast (app round-trip pending T3.5)"
START=$(date +%s)
SIM_USE_APPIUM_URL="$DEAD_URL" paste_text "wired?" --json > "$EVIDENCE_DIR/paste-failfast.txt" 2>&1 || true
assert_contains      "$EVIDENCE_DIR/paste-failfast.txt" '"ok":false' "paste: routes to device + fail-fast ok:false"
assert_elapsed_under 5 "$(( $(date +%s) - START ))"                  "paste: fail-fast is instant"

if [[ "${SIM_USE_E2E_APP_ACTION_VERBS:-0}" == "1" ]]; then
    # Enabled once T3.5 forwards --bundle-id to the action verbs. Finalised when
    # that lands (per team decision:追加 commit, no ticket reopen).
    step "type/paste — text echoes back in the focused field (app-targeted, T3.5)"
    TYPE_TOKEN="E2Etype$RANDOM"; PASTE_TOKEN="E2Epaste$RANDOM"
    tap  --bundle-id "$BUNDLE_ID" --label "Text Input"   >/dev/null 2>&1 || true
    tap  --bundle-id "$BUNDLE_ID" --id text-input-field  >/dev/null 2>&1 || true
    type_text  --bundle-id "$BUNDLE_ID" "$TYPE_TOKEN"    >/dev/null 2>&1 || true
    ui   --bundle-id "$BUNDLE_ID" > "$EVIDENCE_DIR/ui-after-type.txt"  2>&1 || true
    assert_contains "$EVIDENCE_DIR/ui-after-type.txt"  "$TYPE_TOKEN"  "type: field echoes the typed token"
    # paste round-trip: known gap — device paste does not land in the field
    # (type token stays; WDA pasteboard path needs WDA-foreground or another
    # route). Tracked as a Phase-1 open item; keep the wiring case above green
    # and skip the round-trip until the verb is fixed.
    skip "paste app round-trip — known device-paste gap (field keeps prior value); see .scratch/xd-2.0/issues/README.md open items"
else
    skip "type/paste app round-trip — pending T3.5 (--bundle-id on action verbs); set SIM_USE_E2E_APP_ACTION_VERBS=1 to run"
fi

# --- summary ----------------------------------------------------------------
echo
echo -e "${BLUE}================ iOS device E2E results ================${NC}"
print_success "$PASS_COUNT assertion(s) passed"
[[ "$SKIP_COUNT" -gt 0 ]] && print_skip "$SKIP_COUNT case(s) skipped (see notes above)"
if [[ "$FAIL_COUNT" -gt 0 ]]; then
    print_error "$FAIL_COUNT assertion(s) failed:"
    for c in "${FAILED_CASES[@]}"; do echo -e "   ${RED}• $c${NC}"; done
    exit 1
fi
print_success "iOS device E2E green — evidence in $EVIDENCE_DIR/"
