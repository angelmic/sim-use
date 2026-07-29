---
name: sim-use
description: Drive iOS/tvOS Simulator and Android emulator/device screens for AI agents. Use when asked to automate a simulator or emulator, tap/swipe/type on a touch device, navigate tvOS focus, describe UI, take a screenshot, or interact with a mobile app.
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

`--device` is optional when only one simulator is booted or one daemon is running. For Android, run `sim-use android init --device <serial>` once to install the bridge APK. For tvOS, start Appium with the XCUITest driver before preflight (`appium --port 4723`; override with `SIM_USE_APPIUM_URL`) and pass the target app as `sim-use tvos ui --bundle-id <id>` so a cold WDA launch restores it before observation. A modern physical Apple TV also needs a live RemoteXPC tunnel and `SIM_USE_TVOS_WDA_BUNDLE_ID` matching its installed signed runner.

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
| tvOS device: repeated first WDA launch is slow or asks for signing approval | Appium fell through to xcodebuild instead of reusing the installed runner through XCTest/testmanagerd | Supply `--bundle-id` (or `SIM_USE_TVOS_BUNDLE_ID`) and the installed product id in `SIM_USE_TVOS_WDA_BUNDLE_ID`. sim-use health-checks and retains a per-UDID supervisor; inspect `~/.sim-use/<UDID>/tvos-wda-supervisor.json`. A live RemoteXPC tunnel is still required. `wda-signing-cache.json` remains the build/sign repair cache when the supervisor is disabled or unavailable |
| tvOS: `ui` unexpectedly shows Home after Appium starts | A cold WDA launch changed the foreground app and no target was supplied | Re-run the namespaced command with `--bundle-id <id>`, or set `SIM_USE_TVOS_BUNDLE_ID` for top-level `ui` / `screenshot` |
| tvOS: `type` says it needs focus on a text field | Focus sits on a button/cell, not a text field | Run `ui`, move focus onto the `TextField` with `tvos remote`, retry |
| tvOS: focus does not move | Direction is unavailable from the current focus graph (`remote` already waits 0.35 s for the focus animation) | Re-run `ui` and choose another direction; for slow transitions raise `--settle-delay` |
| Outline shows `U+FFFC` in label | iOS icon placeholder character | Match with `--label-regex` excluding the prefix |
| `[i] … covers ~N% of the screen` warning (text output, or `--json` top-level `advisory` key) | The selector resolved to a near-full-screen wrapper (common on Flutter/canvas UIs) and the tap hit its center, likely missing the intended control | Re-run `ui` and target the control via `@N`/`#<id>`, or pass explicit `-x/-y`/`--point` |
| `[i] Screen orientation could not be confirmed…` / `…coordinates may be stale…` advisory | Device/app is rotated (the `App:` header shows a tag like `(landscape-right)`) and orientation self-calibration couldn't verify the mapping, or the `@N` snapshot predates a rotation | Re-run `ui` and tap again; selectors handle rotation automatically once calibration succeeds. Explicit `-x/-y`/`--point` is device-native portrait space by default — on `swipe`/`touch`, pass `--coordinate-space ui` to use outline (visual-space) coordinates on a rotated device |

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
