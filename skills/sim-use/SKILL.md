---
name: sim-use
description: Drive iOS/tvOS Simulator, Android emulator/device, and physical iPhone/iPad/Apple TV screens for AI agents. Use when asked to automate a simulator or emulator, drive a real iOS or tvOS device, tap/swipe/type on a touch device, navigate tvOS focus, describe UI, take a screenshot, or interact with a mobile app.
---

## 0. Preflight

Before first interaction with a device, run the preflight check:

```bash
python3 scripts/preflight.py --device <UDID>
```

This verifies sim-use is installed, the device is reachable, and its backend transport is healthy. If you don't have the script, do the checks manually:

1. `sim-use --version` — confirm sim-use is on PATH.
2. `sim-use devices` — confirm the target device is listed and booted/connected.
3. `sim-use ui --device <UDID>` — confirm you can read the screen.

`--device` is optional when only one simulator is booted or one daemon is running. For Android, run `sim-use android init --device <serial>` once to install the bridge APK. For tvOS, start Appium with the XCUITest driver before preflight (`appium --port 4723`; override with `SIM_USE_APPIUM_URL`) and pass the target app as `sim-use tvos ui --bundle-id <id>` so a cold WDA launch restores it before observation. A modern physical Apple TV needs `SIM_USE_TVOS_WDA_BUNDLE_ID` matching its signed runner. Supplying a live `SIM_USE_TUNNEL_REGISTRY_PORT` enables the retained installed-runner supervisor; without one sim-use uses Appium-managed WDA.

Attached physical Apple devices appear in `sim-use devices` with kind `physical` and route through the top-level verbs (`ui`, `tap`, `swipe`, `type`, `paste`, `screenshot`) over WebDriverAgent. The `sim-use ios-device` namespace additionally offers a zero-setup accessibility-audit path (`devices`, `ui`, `screenshot`, identifier-based `tap`) that needs no Appium server or WDA signing — only Developer Mode and a trusted cable.

For repository release validation on physical Apple hardware, use
`make e2e-ios-device` or `make e2e-tvos-device`. These strict targets require
the target UDID, fixture bundle id, WDA product id, and Apple Team id. Copy
`.sim-use-e2e.local.env.example` to the gitignored
`.sim-use-e2e.local.env`; the runners load it only at script runtime. Set
`SIM_USE_E2E_CONFIG_FILE` for another path, or use non-empty environment
variables to override individual values. They fail instead of SKIP when
hardware is absent.
The runners set `SIM_USE_WDA_STATE_HOME` beneath their evidence directory so
their signing cache, DerivedData, and supervisor records do not overwrite a
long-lived xd process's `~/.sim-use/<UDID>` state.
They prefer CoreDevice/RemoteXPC and use a live `idevice_id -l` attachment only
as a USB fallback. The tvOS gate defaults to Appium-managed WDA. To exercise
the retained supervisor, keep `sudo appium driver run xcuitest
tunnel-creation --appletv-device-id "$SIM_USE_TVOS_DEVICE_UDID"
--tunnel-registry-port 42314` alive and run the gate with
`SIM_USE_TUNNEL_REGISTRY_PORT=42314`; an explicit but missing registry fails
fast. The iOS/tvOS runners use isolated Mac-side WDA ports `8110` / `8111` by
default while the device side stays on `8100`. See the README's
*Physical-device E2E gates* section for the exact variables.

## 1. The observe-act loop

Every interaction follows the same cycle: **observe → act → verify**.

### Observe

```bash
sim-use ui --device <UDID>
```

Read the outline. Each element has an `@N` alias and optionally a `#<id>` identifier. List cells carry `#N` (dominant list) or `#N@M` (scoped).

Frames in the JSON output (`--json`: `entries[].frame`, `screen`) are in platform-native units — iOS **points**, tvOS WebDriver display coordinates, Android **pixels**. Key off the envelope's `platform` field before doing math on coordinates across platforms. Always pair `--json` with `--no-raw` — see *Keeping output small* below.

### Act

On iOS or Android, pick a selector in order of preference:

| Selector | When to use |
|---|---|
| `tap @N` | Right after `ui`. Fastest, cache-backed. |
| `tap #<id>` | Stable across minor layout changes. Paste from the outline. |
| `tap --label 'X'` | Scripted flows. Combine with `--wait-timeout` for transitions. |
| `tap --label-regex '...'` | Dynamic labels with counters/timestamps. Anchor with `^...$`. |
| `tap --label-contains 'X'` | Substring match when exact label is unknown. |
| `tap -x N -y N` / `tap --point x,y` | Last resort for elements with no AX data. |

Disambiguate collisions with `--element-type` or `--frame minY=0.7r` (see `references/cheatsheet.md`).

On tvOS, do not use coordinate or selector taps. Read the entry carrying the `focused` state, then move or activate focus with the Siri Remote surface. Presses are fast (~0.3 s) and report nothing — always re-run `ui` afterwards to observe, or add `--report-focus` for the before/after focused element in one slower call:

```bash
sim-use tvos remote down --device <UDID> --bundle-id <id>
sim-use tvos remote right --device <UDID> --bundle-id <id>
sim-use tvos remote select --device <UDID> --bundle-id <id>
sim-use tvos remote menu --device <UDID> --bundle-id <id>
sim-use tvos type 'query text' --device <UDID> --bundle-id <id>   # into the focused text field
```

### Verify

Always verify after acting — commands are fire-and-forget:

```bash
sim-use ui --device <UDID>       # read the new screen state
sim-use screenshot --device <UDID> --output after.png
```

### Keeping output small

Every byte of command output you read costs context. Defaults that keep the loop cheap:

- Prefer the default text outline over `--json`. The outline carries everything a tap needs (`@N` / `#<id>` aliases, roles, frames, states); reach for `--json` when you need structured fields for coordinate math (`entries[].frame`, `screen`) or full untruncated text (the outline truncates labels at 60 graphemes, `value=` at 30).
- When you do use `--json`, add `--no-raw`. `data.raw` is the raw accessibility tree — typically the bulk of the envelope's bytes, and useful only for debugging sim-use itself.
- One `ui` per action: the Verify read of step N is the Observe read of step N+1. Don't run a second `ui` in between.
- Verify with the text outline, not a screenshot. Reading a screenshot costs several times more than a typical outline; take one only when the check is genuinely visual (colors, images, layout).
- On iOS, to wait out a transition, prefer `tap --label 'X' --wait-timeout 3` (polls for the element) over re-running `ui` in a loop. Android `tap` has no `--wait-timeout`; use `sleep` between commands instead.
- For a known multi-step sequence on iOS, use `sim-use ios batch` (see `references/batch-reference.md`) — one invocation, one output.

### Common moves

| Task | Command |
|---|---|
| Scroll down | `sim-use gesture scroll-up --device <UDID>` (scroll-up = content moves up = page down) |
| Type text | `sim-use type 'hello' --device <UDID>` |
| Paste unicode | `sim-use paste 'こんにちは 🎉' --device <UDID>` (iOS: needs hardware keyboard) |
| Hardware button | `sim-use button home --device <UDID>` |
| Android back | `sim-use button back --device <UDID>` |
| tvOS move focus | `sim-use tvos remote up\|down\|left\|right --device <UDID>` |
| tvOS activate focus | `sim-use tvos remote select --device <UDID>` |
| tvOS go back | `sim-use tvos remote menu --device <UDID>` |
| tvOS type into a field | Focus the field (`TextField` + `focused` in `ui`), then `sim-use tvos type 'text' --device <UDID>` |
| Wait for animation | `sleep 0.4` between commands, or `--pre-delay 0.5` |
| Toggle/switch | `sim-use tap @N --duration 0.05 --device <UDID>` (UISwitch needs a brief hold) |
| Swipe | `sim-use swipe --from 50,500 --to 350,500 --device <UDID>` |
| Pinch zoom in | `sim-use gesture pinch-out --device <UDID>` (two-finger spread) |
| Rotate | `sim-use gesture rotate-cw --angle 90 --device <UDID>` |
| Record evidence GIF | `sim-use record-video --output demo.gif --device <UDID>` — stop with SIGINT/SIGTERM (never SIGKILL); transcodes after stop; auto-plays inline in PRs; add `--gif-markers` for START/END loop-boundary cards |

### Physical iOS devices (experimental)

Physical iOS has two distinct channels. The top-level surface routes a physical
UDID through Appium/WDA for `ui`, `tap`, `swipe`, `type`, `paste`, and
`screenshot`; it requires a reachable Appium server and the WDA signing inputs
described in the troubleshooting table below. The `sim-use ios-device`
namespace is upstream's zero-setup accessibility-audit channel: `devices`,
`ui`, identifier/label-based `tap`, and `screenshot`, with ECID addressing and
tree-tuning flags. Do not mix their capabilities or setup requirements.

**Never assume simulator parity.** Unsupported top-level verbs such as
coordinate gestures, multi-touch, and recording reject with a physical-device
hint. The audit channel has no coordinates, aliases, swipe, typing, paste, or
recording; follow its rejection hint instead of substituting a lookalike form.

**Audit-channel requirement for `ios-device ui` / `tap`:** the device must be
paired, trusted, unlocked and in Developer Mode, and the foreground target app
must be development-signed with `get-task-allow=true`. A Release-configuration
binary installed with a Development profile is supported. Distribution/Ad Hoc,
TestFlight, App Store and system apps are unsupported; do not retry them or
claim success. `ios-device screenshot` is exempt from the signing rule and
captures any screen through CoreDevice.

```bash
# Physical-device preflight — physical rows carry kind `physical`
sim-use devices

# WDA-backed top-level observe → act → verify loop
sim-use ui --device <UDID>
sim-use tap @4 --device <UDID>
sim-use type 'hello' --device <UDID>
sim-use ui --device <UDID>

# Zero-setup accessibility-audit channel
sim-use ios-device ui --device <UDID>
sim-use ios-device tap '#BackButton' --device <UDID>

# Screenshot — any screen, not limited to development-signed apps
sim-use ios-device screenshot --output shot.png --device <UDID>
```

Rules for the zero-setup `ios-device` audit surface:

1. **Treat hierarchy errors as capability failures.** If the command says the hierarchy is unavailable, confirm the screen is unlocked and inspect the installed app's final `get-task-allow` entitlement. Do not fall back to coordinates or focus walking.
2. **Tap by `#id` or label, not `@N`.** Element handles expire with the DTX connection, so there is no `@N` alias (nor coordinates — no geometry). Use the `#id` shown in the outline (positional `#<id>` or `--id`) — it is stable and the best choice when a label is dynamic — or `--label` / `--label-contains`, with `--element-type` to disambiguate. The navigation-bar back button appears as a normal `Button "<previous screen title>" #BackButton`; go back by tapping `#BackButton` (or the shown label) like any other element — no special "back" verb.
3. **Always verify.** Activate is fire-and-forget. Re-run `sim-use ui` and confirm the expected state before continuing.
4. **Respect the capability rejections.** A `not supported by ios-device` error is a statement about this audit channel, not a transient failure — follow its hint instead of retrying or substituting a lookalike form. `--json` works on every verb with the standard `{ok, data}` envelope; physical results carry `"kind":"physical"` and omit geometry fields (`screen`, `x`/`y`).
5. **Budget seconds, not milliseconds.** A full tree takes a few seconds. `sim-use ios-device ui --fast` is quicker but omits nested elements; do not poll in a tight loop.

If `ui` succeeds with zero elements or `tap` prints success for a missing/ambiguous label, treat it as a sim-use bug; the command is expected to fail loudly instead.

## 2. Pitfalls

Quick symptom index — see `references/pitfalls.md` for detailed recipes.

| Symptom | Cause | Fix |
|---|---|---|
| `tap --label` hits wrong element | Label collision (e.g. header and tab bar share text) | Add `--frame minY=0.7r` or `--element-type` to narrow |
| `tap @N` fails after navigation | Alias cache is stale | Re-run `ui` before tapping |
| `App:` line shows wrong app | System layer (alert, share sheet) is on top | Dismiss it first, then re-run `ui` |
| `multipleMatches` error | Several elements share the selector | Use `--frame`, `--element-type`, or a more specific selector |
| Tap lands but nothing happens | Animation in progress, or element not yet interactive | Add `--pre-delay 0.3` or `--wait-timeout 3` |
| iOS: `paste` drops text | Soft keyboard only; HID Cmd+V is ignored | Use `paste --via-menu --target-id <id>` |
| Android: `paste` denied | Background clipboard access blocked | Use `type` instead |
| iOS device: installed WDA signature expired or runner is missing | The signed XCTest runner is no longer launchable | On the first successful setup, set `SIM_USE_WDA_BUNDLE_ID` to the product id and `SIM_USE_XCODE_ORG_ID` to its Apple Developer Team. sim-use persists those repair inputs in `~/.sim-use/<UDID>/wda-signing-config.json`; later runs restore them automatically (non-empty env still wins). It checks `wda-signing-cache.json` before session creation: a valid artifact uses `test-without-building`, while a missing/stale/invalid one sets `useNewWDA=true` and performs one incremental sign/build repair, preventing Appium from attaching to a still-running WDA and falsely leaving the broken local artifact unchanged. |
| iOS device: tap returns HTTP 200 but the UI does not change | Appium's legacy `mobile: tap` reached WDA `/wda/tap`, which may acknowledge without injecting input | Do not retry that route. sim-use physical-device taps use W3C `POST /actions` (`pointerMove` → `pointerDown` → optional `pause` → `pointerUp`) and reject legacy mobile-tap scripts before transport. Always verify with a fresh `ui` or screenshot; HTTP 200 alone is not interaction success. |
| tvOS: `Cannot reach Appium` | Appium is not running at `SIM_USE_APPIUM_URL` | Run `appium --port 4723`; ensure `appium driver list --installed` includes XCUITest |
| tvOS device: repeated first WDA launch is slow or asks for signing approval | The command is using Appium-managed WDA instead of the retained installed-runner supervisor | Supply `--bundle-id` (or `SIM_USE_TVOS_BUNDLE_ID`) and the installed product id in `SIM_USE_TVOS_WDA_BUNDLE_ID`. For the retained supervisor, also supply a live `SIM_USE_TUNNEL_REGISTRY_PORT`; inspect `~/.sim-use/<UDID>/tvos-wda-supervisor.json`. Without a registry, Appium-managed WDA and `wda-signing-cache.json` are the expected fallback. |
| tvOS: `ui` unexpectedly shows Home after Appium starts | A cold WDA launch changed the foreground app and no target was supplied | Re-run the namespaced command with `--bundle-id <id>`, or set `SIM_USE_TVOS_BUNDLE_ID` for top-level `ui` / `screenshot` |
| tvOS: `type` says it needs focus on a text field | Focus sits on a button/cell, not a text field | Run `ui`, move focus onto the `TextField` with `tvos remote`, retry |
| tvOS: focus does not move | Direction is unavailable from the current focus graph (`remote` already waits 0.35 s for the focus animation) | Re-run `ui` and choose another direction; for slow transitions raise `--settle-delay` |
| Outline shows `U+FFFC` in label | iOS icon placeholder character | Match with `--label-regex` excluding the prefix |
| `[i] … covers ~N% of the screen` warning (text output, or `--json` top-level `advisory` key) | The selector resolved to a near-full-screen wrapper (common on Flutter/canvas UIs) and the tap hit its center, likely missing the intended control | Re-run `ui` and target the control via `@N`/`#<id>`, or pass explicit `-x/-y`/`--point` |
| `[i] Screen orientation could not be confirmed…` / `…coordinates may be stale…` advisory | Simulator/app is rotated (the `App:` header shows a tag like `(landscape-right)`) and orientation self-calibration couldn't verify the mapping, or the `@N` snapshot predates a rotation | Re-run `ui` and tap again; selectors handle rotation automatically once calibration succeeds. On iOS Simulator, explicit `-x/-y`/`--point` is device-native portrait space by default — on `swipe`/`touch`, pass `--coordinate-space ui` to use outline (visual-space) coordinates. Physical iOS WDA already uses display-space coordinates and rejects that Simulator-only override. |

## 3. Crash awareness

See `references/crash-awareness.md` for the full protocol. Summary:

On iOS and Android, sim-use watches for the target process disappearing between commands. When it detects a crash:

```
================ PROCESS DISAPPEARED ================
com.example.app (pid 12345) was alive at the previous command and is GONE now.
```

On Android, `ui` also detects the AOSP system crash dialog directly from the accessibility tree.

The experimental tvOS backend does not yet provide cross-command process-liveness tracking; a WebDriver failure is transport evidence, not by itself proof that the app crashed.

**Mandatory response:**
1. **STOP.** Do not silently relaunch or continue.
2. Report the crash to the user with the banner text.
3. Wait for instructions before proceeding.

After an intentional relaunch, call `sim-use app-state --reset` to clear the signal.

## 4. Escalation

Stop and ask the user when:
- A selector collision cannot be resolved with available disambiguators.
- Preflight fails and autofix does not recover.
- The task requires a destructive action (deleting data, uninstalling an app).
- You've retried the same action 3 times without progress.

## 5. Exit checklist

Before reporting a task as complete:
1. Run `sim-use ui` (or `screenshot`) to capture the final state.
2. Confirm the screen matches the intended outcome.
3. If the outcome is ambiguous, show the final `ui` output or screenshot to the user.
