// SPDX-License-Identifier: Apache-2.0
import Testing
import Foundation

/// E2E coverage for the experimental tvOS backend against the
/// SimUsePlaygroundTV fixture (`Playgrounds/tvOS`): a 3x2 focus grid with
/// default focus pinned on "Alpha" and a "Last: <button>" status line.
/// Grid geometry is part of the contract: right of Alpha is Bravo, below
/// Bravo is Echo.
///
/// Requires a booted tvOS Simulator with the fixture installed and a
/// reachable Appium server; `scripts/test-runner-tvos.sh` arranges all
/// three, exports `SIM_USE_E2E=1` + `TVOS_SIMULATOR_UDID`, and runs this
/// suite. Without that environment the suite is skipped.
@Suite("tvOS Remote Command Tests", .serialized, .enabled(if: isTVOSE2EEnabled))
struct TVOSRemoteTests {
    private let bundleID = "com.cameroncooke.SimUsePlaygroundTV"

    @Test("Focus starts on Alpha, remote moves it, select activates it")
    func focusNavigationRoundTrip() async throws {
        // Arrange — cold-relaunch so the fixture is in its default state
        // (focus on Alpha, "Last: none") regardless of earlier runs.
        let udid = try #require(tvosSimulatorUDID)
        _ = try await CommandRunner.run("xcrun simctl terminate \(udid) \(bundleID)", allowFailure: true)
        _ = try await CommandRunner.run("xcrun simctl launch \(udid) \(bundleID)")
        try await Task.sleep(nanoseconds: 1_500_000_000)

        let initial = try await runTVOSCommand("tvos ui --device \(udid) --bundle-id \(bundleID)")
        #expect(initial.output.contains("\"Alpha\"") && initial.output.contains("focused"), "default focus should be Alpha")
        #expect(initial.output.contains("Last: none"))

        // Act + Assert — move right, activate, move down; each step's
        // reported transition pins the grid geometry.
        let right = try await runTVOSCommand("tvos remote right --device \(udid) --bundle-id \(bundleID)")
        #expect(right.output.contains("-> @"), "remote should report a focus transition: \(right)")
        #expect(right.output.contains("\"Bravo\""), "right of Alpha is Bravo: \(right)")

        let select = try await runTVOSCommand("tvos remote select --device \(udid) --bundle-id \(bundleID)")
        #expect(select.output.contains("\"Bravo\""))

        let afterSelect = try await runTVOSCommand("tvos ui --device \(udid) --bundle-id \(bundleID)")
        #expect(afterSelect.output.contains("Last: Bravo"), "select should activate the focused button: \(afterSelect)")

        let down = try await runTVOSCommand("tvos remote down --device \(udid) --bundle-id \(bundleID)")
        #expect(down.output.contains("\"Echo\""), "below Bravo is Echo: \(down)")
    }

    @Test("Top-level ui routes a tvOS UUID to the Appium backend")
    func topLevelUIRoutesToTVOS() async throws {
        // Arrange
        let udid = try #require(tvosSimulatorUDID)

        // Act — SIM_USE_TVOS_BUNDLE_ID is the top-level equivalent of the
        // namespaced --bundle-id target.
        let output = try await runTVOSCommand(
            "ui --device \(udid)",
            environment: ["SIM_USE_TVOS_BUNDLE_ID": bundleID]
        )

        // Assert
        #expect(output.output.contains("App: SimUsePlaygroundTV"))
        #expect(output.output.contains("focused"))
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

    @Test("Coordinate verbs are rejected with the focus-navigation hint")
    func touchVerbsRejected() async throws {
        // Arrange
        let udid = try #require(tvosSimulatorUDID)

        // Act
        let result = try await runTVOSCommand("tap --label Alpha --device \(udid)", allowFailure: true)

        // Assert
        #expect(result.exitCode != 0)
        #expect(result.output.contains("not supported on tvOS"))
        #expect(result.output.contains("sim-use tvos remote"), "the rejection should point at the remote surface")
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

    // MARK: - Helpers

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
