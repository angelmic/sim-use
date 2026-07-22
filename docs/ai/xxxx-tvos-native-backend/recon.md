# tvOS native backend — feasibility recon (2026-07-22)

Live experiments against a tvOS 18.2 Simulator (Apple TV 4K 3rd gen),
Appium 3.5.2 / XCUITest driver 11.16.3, Xcode-current CoreSimulator.
Everything below was measured, not inferred.

## Input: HID channel — FEASIBLE, shipped

FBSimulatorControl's Indigo HID channel accepts keyboard events on tvOS
simulators unchanged, and the runtime maps them onto Siri Remote
semantics:

| HID keycode | tvOS meaning | verified |
|---|---|---|
| 79/80/81/82 | right/left/down/up (focus move) | focus moved on fixture grid |
| 40 (Return) | select | activated the focused button |
| 41 (Escape) | menu | popped back / closed keyboard |
| char keycodes | linear-keyboard typing | typed "hi" into a TextField |

* ~0.34 s per press vs ~2.5-2.7 s per Appium session (measured).
* Independent of Simulator.app: works with `ConnectHardwareKeyboard = 0`
  (both global and per-device defaults) and with the GUI closed entirely
  (headless `simctl boot`). The GUI checkbox only routes the Mac's
  physical keyboard for humans; programmatic injection bypasses it, so
  nothing needs to be "opened" for automation.
* Note: on this host, quitting/killing Simulator.app shuts down booted
  simulators — do not assume sims survive a GUI quit; headless means
  booting via `simctl boot` without the GUI, not killing the GUI later.
* play-pause and home have no keyboard usage; they stay on Appium
  (`mobile: pressButton`). A consumer-page HID injection was not probed
  (FB's key API exposes the keyboard usage page only).

Shipped as the `tvos remote` fast path + `TVOSHIDBridge` seam; see
CHANGELOG "keyboard-mapped buttons press through the simulator HID
channel".

## Screenshot — FEASIBLE, shipped

`xcrun simctl io <udid> screenshot` works on tvOS (~0.7 s, 3840x2160
PNG). Shipped as the no-`--bundle-id` path of `tvos screenshot`.

## Observation: AX tree — BLOCKED at the bridge, Appium stays

Forcing the FB accessibility path against a tvOS UUID (temporary
routing hack) connects and resolves the foreground app and screen size
(`App: SimUsePlaygroundTV 1920x1080`, exit 0) but returns ZERO
elements.

Recon so far:

* `com.apple.CoreSimulator.bridge` IS running inside the tvOS sim
  (`simctl spawn <udid> launchctl list`), so this is not a missing
  service — the bridge's accessibility enumeration itself returns empty
  for tvOS (either the tvOS AX runtime doesn't serve it, or FB's query
  carries iOS-specific parameters).
* Next digging steps (not done, ~day-scale): read
  FBSimulatorAccessibilityOperation in facebook/idb, trace the bridge
  protocol call it makes, and test variations against the tvOS bridge.

Consequence: `ui`'s element outline stays on Appium/WDA (XCTest is the
only reliable element source on tvOS today). `tvos type` also stays on
Appium — its text-field guard needs the source, so HID typing saves
nothing until a native AX channel exists (HID string typing itself was
verified working).

## String entry via Appium — the one channel that works

The tvOS WebDriverAgent has no `/wda/keys`, no `mobile: keys`
(`keyboardInput` route missing), and no W3C key actions
(`fb_performW3CActions:` unrecognized selector). Element `sendKeys`
works ONLY while the keyboard editing session is up; element `click`
works (focus+select semantics) — a future `tvos tap @N` could build on
it. Shipped as `tvos type`.
