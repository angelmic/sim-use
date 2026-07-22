# Changelog

All notable changes to sim-use will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Experimental tvOS Simulator support through Appium/XCUITest: top-level `ui` and `screenshot`, the `sim-use tvos` namespace, and focus-aware `tvos remote <up|down|left|right|select|menu|play-pause|home>`. Each operation owns and closes a short-lived WebDriver session; `--bundle-id` (or `SIM_USE_TVOS_BUNDLE_ID` for top-level verbs) restores the target app after a cold WDA launch, and `SIM_USE_APPIUM_URL` overrides the default `http://127.0.0.1:4723` endpoint. `tvos type <text>` enters whole strings into the focused text field through the focus keyboard (WebDriver element sendKeys — the only string-entry channel tvOS exposes; the tvOS WebDriverAgent has no keyboardInput or W3C key actions).
- tvOS Playground fixture (`Playgrounds/tvOS`, `com.cameroncooke.SimUsePlaygroundTV`): a root menu with `--launch-arg screen=` deep links to four deterministic screens — a 3x2 focus grid (default focus pinned on Alpha, `Last:` status line, play-pause handler), a focus-behaviors row (a disabled control, an alert), a text-entry field, and a 25-row list. The TVOSRemoteTests E2E suite covers the interactions tvOS actually has: focus movement along the grid contract and select activation, focus stopping at edges and skipping disabled controls, alerts trapping focus, Menu popping back / dismissing the keyboard, Home leaving the app, play-pause reaching the app, the focus keyboard typing a character, `tvos type` entering whole strings (and refusing when focus is not on a text field), long lists scrolling the focused row into view, the shared `ui`/`screenshot`/`app-state` surface, and a parameterized sweep asserting every coordinate/HID verb fails with the focus-navigation hint. Gated by `SIM_USE_E2E=1` + `TVOS_SIMULATOR_UDID`; `make e2e-tvos` (or `scripts/test-runner-tvos.sh [test-name] [--no-build]`) builds/installs the fixture, preflights Appium, and runs the suite. Not part of `make e2e` while tvOS support is experimental.
- Android Playground fixture app (`Playgrounds/Android`, `com.linecorp.simuse.playground`) and Android device E2E suites (AndroidTap/SwipeScroll/Type/KeyboardState/MultiTouch/Button/DescribeUI) gated by `SIM_USE_E2E_ANDROID=1` + `ANDROID_SERIAL`. `make e2e-android` builds the APK, installs it, runs `sim-use android init`, and executes the suites one-by-one with a pass/fail summary (`scripts/build-playground-android.sh`, `scripts/test-runner-android.sh`).
- iOS Playground gains three screens with matching E2E suites: `paste-test` + PasteTests (Cmd+V and `--via-menu` paths, unicode, `--replace`, Allow-Paste alert handling), `orientation-test` + OrientationTests (AX-selector taps land correctly after programmatic rotation — exercises orientation self-calibration), and `permissions-test` + PermissionAlertTests (real location permission alert raised, classified via the `App: SpringBoard` header, dismissed through sim-use on both allow and deny paths).
- Agent-eval harness (`e2e/agent-evals/`): natural-language cases executed by a headless `claude -p` agent using the bundled skill (`skills/sim-use/`) against the Playground apps, judged by deterministic device-side post-condition checks. Catches skill-prose drift and verb-steering regressions the scripted suites cannot (e.g. `paste` vs US-ASCII `type`, Android paste-denied fallback).
- `make eval` / `pnpm eval` wrappers that check the environment, estimate the (real `claude -p`) cost, and confirm before running the agent evals.
- E2E confidence-suite design note under `docs/ai/`; the release skill's pre-flight now requires a green `make e2e` run.

### Changed

- `sim-use devices` classifies `simctl` tvOS runtimes separately and accepts `--platform tvos`; `--platform ios` no longer includes tvOS rows.
- `app-state` reports `"platform": "tvos"` for tvOS Simulators (previously `"ios"`); the underlying process probe is unchanged.
- `tvos remote` keyboard-mapped buttons (directions, select, menu) press through the simulator HID channel by default — ~0.3 s instead of ~2.5 s per Appium session — and report no focus transition; pass `--report-focus` for the observing Appium path with the before/after pair. play-pause and home have no keyboard binding and always use Appium.
- `tvos screenshot` without `--bundle-id` captures via `simctl io` (~0.7 s, no Appium); with `--bundle-id` it keeps the Appium path that restores the target app to the foreground first.
- `tvos remote` waits 0.35 s after the press before sampling the after-focus, so the reported transition reflects where focus actually landed; tune or disable with `--settle-delay`.
- The tap family (`tap`, `long-press`, `ios tap`) declares its shared flags once via `TapTargetingOptions` / `TapTimingOptions` option groups instead of three hand-kept copies (#42). Flag names, defaults, validation messages, and `--json` envelopes are unchanged; the only user-visible deltas are in `--help` output, where per-verb wording ("Tap the center…" / "Long-press the center…") unifies to verb-neutral phrasing ("Target the center…") and the timing flags render as a contiguous block after `--duration`.
- `make e2e` now runs both the iOS and Android E2E suites in sequence (continuing past a platform failure and failing if either did); the iOS-only target is `make e2e-ios`, Android-only stays `make e2e-android`.
- `scripts/test-runner.sh` keeps running after a failed suite and prints a full pass/fail map at the end (a release gate needs the whole picture, not the first crash). The hardcoded suite list gained the missing `KeyboardStateTests` and the new suites, and the misnamed `StreamVideoDebugTests` entry — which silently matched zero tests — now points at the real `StreamVideoDebugTest` suite.

### Fixed

- Apple Simulator platform routing reads CoreSimulator's per-device `device.plist` (~1 ms) instead of forking `simctl list devices -j` (hundreds of ms) in every CLI invocation — `ui`, `screenshot`, and `record-video` lose a per-call fork, and long-lived daemons now see simulators created after they spawned. The simctl catalog remains as a safety net for unreadable plists (devices in a custom `--set` are visible to neither source and keep the historical iOS routing), and a fallback failure prints a warning instead of silently routing tvOS devices to the iOS backend.
- Touch/typing/recording verbs aimed at a tvOS Simulator fail in-process with the focus-navigation hint instead of first auto-spawning a per-UDID daemon that can never serve them.
- A failed Appium session DELETE no longer fails a tvOS command whose work had already completed; teardown is best-effort with a stderr warning.
- The tvOS outline no longer drops the focused element when it is unlabeled, or when the WebDriver source emits a duplicate node (same role/label/frame) whose focused copy comes second — duplicates now merge their states.
- A malformed Appium session id surfaces as a WebDriver-protocol error instead of crashing the CLI on a force-unwrapped URL.
- Four E2E suites (KeyTests, KeyComboTests, KeySequenceTests, StreamVideoTests) still invoked the pre-0.5.x top-level verb forms and had failed ever since the five iOS-only verbs moved under the `ios` namespace; they now call `sim-use ios <verb>`.
- KeyComboTests' Cmd+A test asserted a cleared text field reads nil/empty — an empty `UITextField` exposes its placeholder as the accessibility value, so the assertion could never pass. It now accepts the placeholder form.

## [0.10.0] - 2026-07-09

### Added

- GitHub Actions CI (`.github/workflows/tests.yml`): Swift unit tests on macOS hosted runners (idb-derived FB XCFrameworks cached between runs), bridge Kotlin JVM unit tests on ubuntu, and a bridge protocol parity check — all for every push and pull request targeting `main`. (#26)
- `make build` / `make test` condense swift output via [xcsift](https://github.com/ldomaradzki/xcsift) (TOON summary; test coverage report) when it is installed — strictly optional, plain swift output otherwise; `SIM_USE_XCSIFT=0` forces plain output. (#26)
- `swipe` now accepts `--from x,y --to x,y` and positional `x,y x,y` coordinates on top-level, iOS, Android, and iOS batch surfaces while keeping the existing four coordinate flags. (#27, #30 — thanks @joonyeonglim!)
- `tap` and `long-press` now accept `--point x,y` as a coordinate-pair alternative to `-x`/`-y` on top-level, iOS, Android, and iOS batch surfaces (#25). The two forms are mutually exclusive and resolve through one shared `TapCoordinateResolver`, and `describe-ui --point` now parses through the same `CoordinatePair` grammar as `swipe --from/--to` (a malformed value fails with ArgumentParser's standard invalid-value diagnostic instead of the previous bespoke message). (#40)
- `tap`/`long-press` — and `ios batch` tap steps — now surface a structured advisory when a label/value selector resolves to a near-full-screen element (measured against the Application root frame), so daemon-routed calls show the warning in terminal output and `--json` instead of burying it in the daemon log. (#29, #36 — thanks @joonyeonglim!)

### Changed

- `describe-ui --point` coordinates are now interpreted in the same UI space as the printed outline frames. On a rotated simulator the query is transformed onto the framebuffer before the hit-test (previously the raw point was hit-tested in framebuffer space and returned the wrong element); an upright device behaves exactly as before. (#38)
- `describe-ui` surfaces the calibrated interface orientation: the `App:` header gains a suffix tag (e.g. `(landscape-right)`) when the device is not upright, `--json` `data` gains an `orientation` field, and the alias snapshot records the orientation it was captured under. (#38)
- Swipe coordinate flags now live in a shared `SwipeCoordinateOptions` group, so the top-level, iOS, and Android surfaces validate identically; the swipe success line and `--json` `data` payload derive the coordinates from the execution result (`data` now includes a `coordinates` object). (#30)
- `swipe --duration` is capped at 10 seconds on every surface (parity with `tap` / `multi-touch` / gesture presets). The error message spells out that durations are in seconds, so a millisecond value passed by habit (0.5.x `android swipe`, `adb shell input swipe`) fails loudly instead of producing a multi-minute swipe. (#30)
- JSON output no longer emits the legacy `udid` key (dual-emitted since the `deviceId` transition); `deviceId` is the canonical key in `devices --json`, `daemon stop/status --json`, and Viewer API responses. Inputs (daemon wire decode, Viewer API requests) still accept `udid` as a deprecated alias, to be removed in a future release. (#22)
- `--label`/`--value` exact matching and `--label-contains` (plus the Android-only `--value-contains`) now fall back to whitespace-collapsed comparison when the exact pass finds nothing, on both iOS and Android, so a multi-line label (which the compact `describe-ui` outline renders space-joined) matches the space-joined string an agent copies back. Existing exact matches are unaffected — the fallback only runs when the exact pass matched zero elements. The Android exact pass now end-trims both query and label, matching iOS. The round-trip covers labels the outline renders untruncated (≤ 60 graphemes) and unescaped; longer labels still need the `@N` outline alias or `describe-ui --json` (raw labels). (#28, #31 — thanks @joonyeonglim!)
- Whitespace collapsing is one canonical implementation (`SelectorTextMatcher` in SimUseCore) shared by the iOS/Android outline renderers and both selector resolvers, so the display form and the matching form can never drift apart. The outline now also folds Unicode whitespace the old collapse missed (NBSP, U+2028/U+2029 line separators), so element lines cannot wrap on exotic line breaks. (#31)
- `--wait-timeout` polling now also retries while the selector matches multiple elements (previously only not-found), so a transient ambiguity during a screen transition no longer aborts the wait on the first tick; a stable ambiguity still reports `multipleMatches` with its disambiguation hint once the window expires. (#31)
- Daemon client now retries a command once against the same daemon when the simulator reports the post-boot `transient_booting` readiness gap, matching the long-documented behaviour. (#6)
- Bridge `/swipe` now accepts durations up to 10 s (previously silently clamped to 5 s), covering the full `--duration` range the CLI validates for long-press holds. Bridge `versionCode` bumped to 16. (#8)
- `ios type` builds one HID session for the whole string instead of re-initialising FBSimulatorControl per character. (#9)
- `ios stream-video --format` help now marks `bgra` as experimental (no frame count is reported for that format). (#21)

### Fixed

- `sim-use devices` no longer hangs forever on machines with enough simulators installed to push `simctl list devices -j` past the ~64 KB kernel pipe buffer. `SimctlDeviceLister.runSimctl` now drains stdout/stderr concurrently with the child (the same `readabilityHandler` drain `Adb.run` uses on the Android path) instead of reading only after `waitUntilExit()`, which deadlocked once the child blocked on `write(2)`. (#39 — thanks @JustHm!)
- The root `sim-use --help` abstract no longer claims the tool is iOS-Simulator-only; it now mentions Android emulators/devices as well. (#35)
- iOS taps resolved through accessibility (`tap @N` / `#N` / `#<id>` / the `--label` family, batch tap steps, `paste --via-menu` targets and edit-menu items) now land correctly when the simulator or the app is rotated (#34). AX frames are reported in the app's UI space while HID events are interpreted in the device-native portrait framebuffer; sim-use now self-calibrates the orientation per command with 1–3 accessibility hit-test probes and transforms AX-derived coordinates before dispatch. Explicit `-x/-y` coordinates keep their raw framebuffer semantics. When calibration cannot be confirmed (empty or fully symmetric screens) the command falls back to portrait and surfaces an `orientation_calibration_fallback` advisory. (#38)
- `describe-ui` quadtree recovery no longer silently drops whole regions on rotated simulators — the same #34 coordinate mismatch corrupted its coverage bookkeeping (live repro: the entire Settings sidebar vanished from the outline on an upside-down iPad). (#38)
- `describe-ui --point` no longer overwrites the `@N` alias snapshot with a single-element table, so `tap @N` keeps resolving against the last full outline after a point query. (#38)
- `android swipe` invoked directly now enforces the same coordinate rules as the other surfaces: negative coordinates and identical start/end points are rejected at validate time instead of being forwarded to the bridge. (#30)
- Swipe coordinates are validated as finite and ≤ 100000 on all surfaces, so values like `inf`, `nan`, or `1e19` fail with a clean validation error instead of trapping the daemon in the Double→Int conversion. (#30)
- Tap and long-press coordinates get the same finite / ≤ 100000 validation on every surface — `tap -x inf -y 5` or `-x 1e19` targeting an Android device previously trapped the Double→Int conversion instead of failing with a clean validation error. (#40)
- The top-level `swipe` and `android swipe` no longer disagree on fractional Android coordinates (truncation vs rounding); both round half away from zero via shared accessors. (#30)
- `android swipe --pre-delay`/`--post-delay` are bounded to 0–10 seconds like every other surface; the previous sign-only check let `inf`/`nan` through into the Double→UInt64 sleep conversion, which trapped the daemon. (#30)
- Android swipe rejects coordinate pairs that round to the same integer pixel (e.g. `--from 10.4,10.4 --to 10.49,10.49`), which previously passed the Double comparison but dispatched a degenerate same-point gesture to the bridge. (#30)
- `DaemonClient.stopDaemon` no longer waits on and SIGTERMs a pidfile pid that is the caller's own process (a stale pidfile can hold a recycled pid; in-process daemons in tests always do). Signalling ourselves fanned out through every live `DaemonServer`'s SIGTERM source and tore down unrelated daemons mid-request — the main source of daemon-test flakiness under parallel load. (#26)
- Cached HID connection is now validated against the simulator's boot instance before reuse, so a simulator shut down and re-booted under the same UDID gets a fresh connection instead of hanging the daemon (or failing every command) on the dead one until restart. Additionally, any failed HID perform drops the cached connection, and failures that provably happened before delivery (dead mach port) are transparently retried once against a rebuilt session. (#23)
- `ios batch --ax-cache` was a complete no-op: the default `perBatch` never cached and every selector-based step refetched the AX tree. `perBatch` now resolves all steps against one snapshot, `perStep` refetches at each step, `none` never caches, and `--wait-timeout` poll ticks bypass the cache (updating it) so delayed elements are still found. (#20)
- Daemon client no longer tears down a healthy daemon and re-executes the command when the daemon answers with a command-level error (element not found, etc.). Failed commands now surface immediately instead of paying a full daemon respawn, and side-effecting commands are no longer executed twice. (#6)
- Daemon shutdown no longer deletes the socket/pidfile of a successor daemon that took the paths over, which previously chained invisible orphan daemons. (#7)
- Daemon base directory under `/tmp` is now validated on every run (symlinks, foreign owners rejected; loose permissions tightened to 0700) instead of trusting whatever was pre-created there. (#7)
- Bridge `/a11y_tree_full` no longer reads the active root's `windowId` after the node was recycled, which silently dropped popup/dialog secondary windows on Android 11–12. (#8)
- Bridge `/keyboard/input` no longer leaks the borrowed root `AccessibilityNodeInfo` on every call. (#8)
- `record-video` no longer hot-spins without frame pacing when screenshot frames persistently fail to decode. (#9)
- `record-video` no longer hangs forever when AVAssetWriter stops accepting frames; a stalled writer now fails the recording with an explicit error after 10 s. (#19)
- Daemon no longer shuts itself down in the middle of a request that runs longer than the idle timeout (e.g. `tap --wait-timeout` beyond the timeout, or a long `batch`). The idle timer now defers shutdown while a request is in flight. (#13)
- Daemon client no longer respawns and resends a command when the daemon drops the connection *after* receiving the request (a possible mid-execution crash). Such ambiguous outcomes now surface a dedicated error with a hint to re-observe the screen before retrying, so a side-effecting verb (tap/type/swipe) is never silently applied twice. Pre-delivery failures (connect/write) still respawn as before. (#12)
- `keyboard-state` now routes through the per-UDID daemon like every other verb (amortised init) and surfaces crash advisories and error `Hint:` lines; a vestigial `run()` override had silently opted it out. The `soft`/`hidden`/failure exit codes are unchanged. (#11)
- `ios stream-video` with the BGRA pixel format no longer exits 0 when the underlying stream fails to start or dies mid-stream; startup and mid-stream errors now terminate the streaming loop and surface as a non-zero exit instead of a stderr-only message. (#21)
- `record-video`'s stop watchdog no longer exits 0 when video finalization overruns its grace window, which could report success for a truncated/unplayable MP4. It now warns on stderr and exits 70 (`EX_SOFTWARE`), and the grace window is 3 s (was 1.5 s). (#18)
- Viewer API no longer reports success when the underlying sim-use invocation exits non-zero without a parseable JSON envelope; the subprocess's stderr is now surfaced in the error response instead of a generic JSON-parse failure. (#17)
- `sim-use android tap` no longer crashes on every invocation with ArgumentParser's "can't read a value from a parsable argument definition" fatal. `performTap`'s default `MultiTouchOptions()` was a directly-initialized `ParsableArguments` value, and the first `.fingers` read trapped before anything was dispatched; the parameter is now optional with `nil` meaning single-touch. The top-level `sim-use tap` routed to Android was unaffected (it passes its parsed options through). (#41)
- The bundled skill's `preflight.py` daemon-restart autofix no longer appends the session `--device` flag to `daemon stop --all` (the two are mutually exclusive), so the autofix actually stops the stale daemon instead of failing with exit 64 while reporting success. (#2 — thanks @viseator!)

### Removed

- Dead `.hidSwipePerformed` notification posted by `ios swipe` — nothing ever observed it since its introduction. (#14)

## [0.9.0] - 2026-06-29

Initial public release.

### Added

- Cross-platform CLI driving iOS Simulator and Android emulator/device through a single command surface.
- `ui` (alias: `describe-ui`) — compact, token-efficient screen outline with `@N` alias addressing and `#<id>` / `#N` / `#N@M` selectors.
- Full interaction surface: `tap`, `swipe`, `long-press`, `touch`, `type`, `paste`, `button`, `gesture`, `multi-touch`, `keyboard-state`, `screenshot`, `record-video`, `app-state`.
- iOS-only verbs under `sim-use ios`: `key`, `key-combo`, `key-sequence`, `stream-video`, `batch`.
- Android bridge APK (`bridge/`) with AccessibilityService + HTTP server, bootstrapped via `sim-use android init`.
- Per-UDID background daemon for iOS, amortising per-call init cost.
- Cross-command crash / termination detection with process-liveness tracking and Android crash-dialog detection.
- `sim-use viewer` — bundled local web app for visualising the accessibility tree with blind-spot overlay.
- `sim-use init` — install the bundled agent skill into Claude Code or other AI clients.
- `--json` envelope on every command for machine consumption.
- Homebrew formula via `brew tap lycorp-jp/tap && brew install sim-use`.
