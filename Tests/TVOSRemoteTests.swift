// SPDX-License-Identifier: Apache-2.0
import Testing
import Foundation

/// E2E coverage for the experimental tvOS backend against the
/// SimUsePlaygroundTV fixture (`Playgrounds/tvOS`), one test per tvOS
/// interaction the platform actually has:
///
///   * focus movement + select activation (the tap/observe loop's tvOS
///     equivalent), including the grid geometry contract
///   * focus-engine behaviours agents must be able to observe: focus
///     stops at edges, skips disabled controls, and alerts trap it
///   * Menu returning to the previous screen, Home leaving the app,
///     play-pause reaching the app
///   * the focus keyboard: select opens it and types, menu dismisses it
///     (tvOS's only text-entry interaction — the tvOS WebDriverAgent has
///     no keyboardInput/W3C-key-actions support, so there is no string
///     shortcut to test)
///   * long lists scrolling the focused row into view
///   * the shared observe surface (`ui`, `screenshot`, `app-state`)
///   * every coordinate/HID verb failing fast with the remote hint
///
/// iOS-only behaviours (rotation, coordinate taps/swipes, HID keyboard,
/// pasteboard, video recording) are deliberately not mirrored here beyond
/// the rejection sweep — tvOS has no such interactions.
///
/// Requires a booted tvOS Simulator with the fixture installed and a
/// reachable Appium server; `scripts/test-runner-tvos.sh` arranges all
/// three, exports `SIM_USE_E2E=1` + `TVOS_SIMULATOR_UDID`, and runs this
/// suite. Without that environment the suite is skipped.
@Suite("tvOS Remote Command Tests", .serialized, .enabled(if: isTVOSE2EEnabled))
struct TVOSRemoteTests {
    private let bundleID = "com.cameroncooke.SimUsePlaygroundTV"

    // MARK: - Focus movement & activation (tap-family equivalent)

    @Test("Focus starts on Alpha, remote moves it, select activates it")
    func focusNavigationRoundTrip() async throws {
        // Arrange
        let udid = try #require(tvosSimulatorUDID)
        try await launchFixture(screen: "grid")

        let initial = try await runTVOSCommand("tvos ui --device \(udid) --bundle-id \(bundleID)")
        #expect(initial.output.contains("\"Alpha\"") && initial.output.contains("focused"), "default focus should be Alpha")
        #expect(initial.output.contains("Last: none"))

        // Act + Assert — each step pins the grid geometry contract.
        let right = try await remote("right")
        #expect(right.after == "Bravo", "right of Alpha is Bravo, got \(right.after ?? "nil")")

        _ = try await remote("select")
        let afterSelect = try await runTVOSCommand("tvos ui --device \(udid) --bundle-id \(bundleID)")
        #expect(afterSelect.output.contains("Last: Bravo"), "select should activate the focused button")

        let down = try await remote("down")
        #expect(down.after == "Echo", "below Bravo is Echo, got \(down.after ?? "nil")")
    }

    @Test("The default remote press takes the HID fast path and still moves focus")
    func hidFastPathPressesWithoutObserving() async throws {
        // Arrange
        let udid = try #require(tvosSimulatorUDID)
        try await launchFixture(screen: "grid")

        // Act — no --report-focus: the press goes through the HID channel
        // (~0.3 s, no Appium session) and reports nothing.
        let press = try await runTVOSCommand("tvos remote right --device \(udid)")

        // Assert — output has no transition, but the focus really moved.
        #expect(press.output.contains("Pressed right"))
        #expect(!press.output.contains("->"), "the fast path must not fabricate a focus report: \(press.output)")
        let after = try await runTVOSCommand("tvos ui --device \(udid) --bundle-id \(bundleID)")
        #expect(after.output.contains("\"Bravo\"") && after.output.contains("focused"), "right of Alpha is Bravo")
    }

    @Test("Screenshot without a bundle id captures through simctl")
    func screenshotFastPathViaSimctl() async throws {
        // Arrange
        let udid = try #require(tvosSimulatorUDID)
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("tvos-e2e-simctl-\(UUID().uuidString).png").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        // Act — no --bundle-id: the capture path is simctl io, no Appium.
        _ = try await runTVOSCommand("tvos screenshot --device \(udid) --output \(path)")

        // Assert
        let data = try #require(FileManager.default.contents(atPath: path))
        #expect(data.starts(with: [0x89, 0x50, 0x4E, 0x47]), "output should be a PNG")
    }

    @Test("Focus stops at screen edges instead of wrapping")
    func focusStopsAtEdges() async throws {
        // Arrange — Alpha sits on the grid's top-left edge.
        try await launchFixture(screen: "grid")

        // Act
        let left = try await remote("left")
        let up = try await remote("up")

        // Assert — the focus engine does not wrap; the report shows an
        // unchanged focus rather than an error, which is what an agent
        // uses to conclude "I've reached the end".
        #expect(left.before == "Alpha" && left.after == "Alpha", "left from the edge must not move focus")
        #expect(up.after == "Alpha", "up from the edge must not move focus")
    }

    @Test("Focus skips disabled controls and the outline tags them")
    func focusSkipsDisabledControls() async throws {
        // Arrange — behaviors row is [First] [Disabled] [Second].
        let udid = try #require(tvosSimulatorUDID)
        try await launchFixture(screen: "behaviors")

        let outline = try await runTVOSCommand("tvos ui --device \(udid) --bundle-id \(bundleID)")
        #expect(outline.output.contains("\"Disabled\"") && outline.output.contains("disabled"), "outline should tag the disabled control")

        // Act
        let right = try await remote("right")

        // Assert — the focus engine never lands on a disabled control.
        #expect(right.after == "Second", "focus must skip the disabled control, got \(right.after ?? "nil")")
    }

    @Test("An alert traps focus and select dismisses it")
    func alertTrapsFocusAndSelectDismisses() async throws {
        // Arrange — "Show Alert" sits below the behaviors row.
        let udid = try #require(tvosSimulatorUDID)
        try await launchFixture(screen: "behaviors")

        // Act — move focus down to "Show Alert" and activate it.
        let down = try await remote("down")
        #expect(down.after == "Show Alert")
        _ = try await remote("select")

        // Assert — the alert owns the screen and focus.
        let alertUI = try await runTVOSCommand("tvos ui --device \(udid) --bundle-id \(bundleID)")
        #expect(alertUI.output.contains("Fixture Alert"))
        #expect(alertUI.output.contains("\"Dismiss\"") && alertUI.output.contains("focused"), "the alert button should hold focus")

        // Act + Assert — select dismisses and the fixture records it.
        _ = try await remote("select")
        let dismissed = try await runTVOSCommand("tvos ui --device \(udid) --bundle-id \(bundleID)")
        #expect(!dismissed.output.contains("Fixture Alert"), "the alert should be gone")
        #expect(dismissed.output.contains("Last: alert-dismissed"))
    }

    // MARK: - Menu / Home / play-pause (Siri Remote buttons)

    @Test("Menu returns from a screen to the root menu")
    func menuReturnsToPreviousScreen() async throws {
        // Arrange
        let udid = try #require(tvosSimulatorUDID)
        try await launchFixture(screen: "grid")

        // Act
        _ = try await remote("menu")

        // Assert — back on the root menu, whose entries are focus targets.
        let root = try await runTVOSCommand("tvos ui --device \(udid) --bundle-id \(bundleID)")
        #expect(root.output.contains("Grid Test") && root.output.contains("Focus Behaviors"), "menu should pop back to the root menu")
    }

    @Test("Home leaves the app; relaunching by bundle id restores it")
    func homeThenRelaunchRestoresFixture() async throws {
        // Arrange
        let udid = try #require(tvosSimulatorUDID)
        try await launchFixture(screen: "grid")

        // Act — Home backgrounds the fixture, then the bundle-id target
        // brings it back (the cold-WDA recovery path agents rely on).
        _ = try await remote("home")
        let restored = try await runTVOSCommand("tvos ui --device \(udid) --bundle-id \(bundleID)")

        // Assert — the fixture is the foreground app again. The bundle-id
        // relaunch may cold-start it (back on the root menu) or resume it
        // (still on the grid); both prove Home left and the target
        // recovered, which is the contract agents rely on.
        #expect(restored.output.contains("App: SimUsePlaygroundTV"))
        #expect(
            restored.output.contains("Grid Test") || restored.output.contains("\"Alpha\""),
            "a known fixture screen should be back in the foreground: \(restored.output)"
        )
    }

    @Test("play-pause reaches the app's media handler")
    func playPauseReachesTheApp() async throws {
        // Arrange — the grid screen records play-pause via onPlayPauseCommand.
        let udid = try #require(tvosSimulatorUDID)
        try await launchFixture(screen: "grid")

        // Act
        _ = try await remote("play-pause")

        // Assert
        let outline = try await runTVOSCommand("tvos ui --device \(udid) --bundle-id \(bundleID)")
        #expect(outline.output.contains("Last: play-pause"))
    }

    // MARK: - Text entry (the platform's focus keyboard)

    @Test("The focus keyboard types a character and menu dismisses it")
    func textEntryThroughFocusKeyboard() async throws {
        // Arrange — the text screen's field holds default focus.
        let udid = try #require(tvosSimulatorUDID)
        try await launchFixture(screen: "text")
        let field = try await runTVOSCommand("tvos ui --device \(udid) --bundle-id \(bundleID)")
        #expect(field.output.contains("TextField") && field.output.contains("focused"))
        #expect(field.output.contains("Typed: none"))

        // Act — select opens the system linear keyboard (cursor starts on
        // "a"), a second select types that character, menu closes the
        // keyboard. This is how a real viewer types on tvOS; there is no
        // coordinate or HID string-entry shortcut on this platform.
        let open = try await remote("select")
        #expect(open.after == "Keyboard", "select on a text field should open the keyboard, got \(open.after ?? "nil")")

        let keyboard = try await runTVOSCommand("tvos ui --device \(udid) --bundle-id \(bundleID)")
        #expect(keyboard.output.contains("Key") && keyboard.output.contains("\"a\""), "the linear keyboard's character keys should be in the outline")

        _ = try await remote("select")
        let dismissed = try await remote("menu")
        #expect(dismissed.after == "text-input", "menu should close the keyboard and return focus to the field")

        // Assert — the character landed in the field and the keyboard is
        // gone.
        let after = try await runTVOSCommand("tvos ui --device \(udid) --bundle-id \(bundleID)")
        #expect(after.output.contains("Typed: a"), "the typed character should land in the field")
        #expect(!after.output.contains("\"Keyboard\""), "the keyboard should be dismissed")
    }

    @Test("tvos type enters a whole string through the keyboard's element surface")
    func typeVerbEntersWholeStrings() async throws {
        // Arrange — the text screen's field holds default focus.
        let udid = try #require(tvosSimulatorUDID)
        try await launchFixture(screen: "text")

        // Act — the Appium element sendKeys channel: select opens the
        // keyboard, the string lands in one request, menu commits.
        let result = try await runTVOSCommand(
            "tvos type \"hi there\" --device \(udid) --bundle-id \(bundleID)"
        )
        #expect(result.output.contains("Typed \"hi there\""))

        // Assert — the whole string is in the field and the keyboard is
        // dismissed.
        let after = try await runTVOSCommand("tvos ui --device \(udid) --bundle-id \(bundleID)")
        #expect(after.output.contains("Typed: hi there"), "the string should land in the field")
        #expect(!after.output.contains("\"Keyboard\""), "the keyboard should be dismissed")
    }

    @Test("tvos type without a focused text field fails with guidance")
    func typeVerbRequiresATextField() async throws {
        // Arrange — grid screen: focus sits on a Button, not a text field.
        let udid = try #require(tvosSimulatorUDID)
        try await launchFixture(screen: "grid")

        // Act
        let result = try await runTVOSCommand(
            "tvos type hello --device \(udid) --bundle-id \(bundleID)",
            allowFailure: true
        )

        // Assert
        #expect(result.exitCode != 0)
        #expect(result.output.contains("needs focus on a text field"), "got: \(result.output)")
        #expect(result.output.contains("tvos remote"), "the error should point at focus navigation")
    }

    // MARK: - Focus-driven scrolling (swipe/scroll equivalent)

    @Test("Moving focus down a long list scrolls later rows into view")
    func listScrollsFocusedItemIntoView() async throws {
        // Arrange — 25 rows, roughly 10 visible at 1080p.
        let udid = try #require(tvosSimulatorUDID)
        try await launchFixture(screen: "list")

        let initial = try await runTVOSCommand("tvos ui --device \(udid) --bundle-id \(bundleID)")
        #expect(initial.output.contains("Row 1") && initial.output.contains("focused"))
        #expect(!initial.output.contains("\"Row 20\""), "row 20 should start off-screen")

        // Act — no coordinates, no swipe: on tvOS scrolling IS focus
        // movement.
        var landed: String?
        for _ in 1...14 {
            landed = try await remote("down").after
        }

        // Assert — focus walked the list and the list scrolled with it.
        #expect(landed == "Row 15", "14 downs from Row 1 should land on Row 15, got \(landed ?? "nil")")
        let scrolled = try await runTVOSCommand("tvos ui --device \(udid) --bundle-id \(bundleID)")
        #expect(scrolled.output.contains("\"Row 15\""), "the focused row must be scrolled into view")
        #expect(!scrolled.output.contains("\"Row 1\""), "early rows should have scrolled out")
    }

    // MARK: - Shared observe surface

    @Test("Top-level ui routes a tvOS UUID to the Appium backend")
    func topLevelUIRoutesToTVOS() async throws {
        // Arrange
        let udid = try #require(tvosSimulatorUDID)
        try await launchFixture(screen: "grid")

        // Act — SIM_USE_TVOS_BUNDLE_ID is the top-level equivalent of the
        // namespaced --bundle-id target.
        let result = try await runTVOSCommand(
            "ui --device \(udid)",
            environment: ["SIM_USE_TVOS_BUNDLE_ID": bundleID]
        )

        // Assert
        #expect(result.output.contains("App: SimUsePlaygroundTV"))
        #expect(result.output.contains("focused"))
    }

    @Test("Screenshot writes a PNG")
    func screenshotWritesPNG() async throws {
        // Arrange
        let udid = try #require(tvosSimulatorUDID)
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("tvos-e2e-\(UUID().uuidString).png").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        // Act
        _ = try await runTVOSCommand("tvos screenshot --device \(udid) --bundle-id \(bundleID) --output \(path)")

        // Assert
        let data = try #require(FileManager.default.contents(atPath: path))
        #expect(data.starts(with: [0x89, 0x50, 0x4E, 0x47]), "output should be a PNG")
    }

    @Test("app-state reports platform tvos")
    func appStateReportsTVOS() async throws {
        // Arrange
        let udid = try #require(tvosSimulatorUDID)

        // Act
        let result = try await runTVOSCommand("app-state --device \(udid) --json")

        // Assert
        #expect(result.output.contains("\"platform\":\"tvos\""))
    }

    // MARK: - Coordinate/HID verbs have no tvOS interaction — reject fast

    @Test(
        "Coordinate and HID verbs are rejected with the focus-navigation hint",
        arguments: [
            "tap -x 10 -y 10",
            "long-press -x 10 -y 10",
            "touch -x 10 -y 10 --down",
            "swipe --from 10,10 --to 20,20",
            "multi-touch --x1 10 --y1 10 --x2 20 --y2 20 --x1-end 30 --y1-end 30 --x2-end 40 --y2-end 40",
            "gesture scroll-up",
            "type hello",
            "paste hello",
            "button home",
            "keyboard-state",
            "record-video --output /tmp/tvos-e2e-reject.mp4",
        ]
    )
    func coordinateVerbsRejected(verb: String) async throws {
        // Arrange
        let udid = try #require(tvosSimulatorUDID)

        // Act
        let result = try await runTVOSCommand("\(verb) --device \(udid)", allowFailure: true)

        // Assert — fail fast, name the platform, point at the remote.
        #expect(result.exitCode != 0, "\(verb) must fail on tvOS")
        #expect(result.output.contains("not supported on tvOS"), "\(verb): \(result.output)")
        #expect(result.output.contains("sim-use tvos remote"), "\(verb) should point at the remote surface")
    }

    // MARK: - Helpers

    /// Terminate + relaunch the fixture directly onto one of its screens
    /// (`--launch-arg screen=...`), so tests don't depend on each other's
    /// navigation state. Mirrors TestHelpers.launchPlaygroundApp.
    private func launchFixture(screen: String) async throws {
        let udid = try #require(tvosSimulatorUDID)
        _ = try await CommandRunner.run("xcrun simctl terminate \(udid) \(bundleID)", allowFailure: true)
        try await Task.sleep(nanoseconds: 500_000_000)
        _ = try await CommandRunner.run("xcrun simctl launch \(udid) \(bundleID) --launch-arg \"screen=\(screen)\"")
        try await Task.sleep(nanoseconds: 2_000_000_000)
    }

    /// Press one remote button and return the reported focus transition,
    /// parsed from the --json envelope. Uses --report-focus (the observing
    /// Appium path): the suite's geometry-contract assertions need the
    /// before/after pair. The default HID fast path has its own test.
    private func remote(_ button: String) async throws -> (before: String?, after: String?) {
        let udid = try #require(tvosSimulatorUDID)
        let result = try await runTVOSCommand(
            "tvos remote \(button) --report-focus --device \(udid) --bundle-id \(bundleID) --json"
        )
        let json = try #require(
            try JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any],
            "remote --json should emit an envelope: \(result.output)"
        )
        let data = json["data"] as? [String: Any]
        let label: ([String: Any]?) -> String? = { entry in entry?["label"] as? String }
        return (label(data?["before"] as? [String: Any]), label(data?["after"] as? [String: Any]))
    }

    /// A first tvOS command against a cold WebDriverAgent can take far
    /// longer than CommandRunner's 30 s default, so every call here gets
    /// the same generous ceiling.
    @discardableResult
    private func runTVOSCommand(
        _ arguments: String,
        environment: [String: String]? = nil,
        allowFailure: Bool = false
    ) async throws -> ShellOutput {
        let binary = try TestHelpers.getSimUsePath()
        let result = try await CommandRunner.run(
            "\(binary) \(arguments)",
            environment: environment,
            allowFailure: allowFailure,
            timeout: 120
        )
        return ShellOutput(output: result.output, exitCode: result.exitCode)
    }
}

let tvosSimulatorUDID = ProcessInfo.processInfo.environment["TVOS_SIMULATOR_UDID"]
let isTVOSE2EEnabled = isE2EEnabled && tvosSimulatorUDID != nil
