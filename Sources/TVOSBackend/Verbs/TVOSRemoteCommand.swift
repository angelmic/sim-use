// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import SimUseCore

/// Sends one Siri Remote button through Appium's XCUITest driver. Capturing
/// source before and after the action makes focus movement observable to an
/// agent without requiring a separate `ui` round trip.
public struct TVOSRemoteCommand: SimUseExecutableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "remote",
        abstract: "Press a tvOS remote button and report the focus transition."
    )

    @Argument(help: "Remote button: up, down, left, right, select, menu, play-pause, or home.")
    public var button: TVOSRemoteButton

    @OptionGroup public var device: DeviceOptions
    @OptionGroup public var target: TVOSTargetOptions
    @OptionGroup public var json: JSONOutputOptions

    @Option(
        name: .customLong("settle-delay"),
        help: "Seconds to wait after the press before sampling the focus state for the after-report. Focus animations need a beat to settle; 0 disables the wait."
    )
    public var settleDelay: Double = 0.35

    @Flag(
        name: .customLong("report-focus"),
        help: "Observe and report the before/after focused element (one Appium session). Without it, keyboard-mapped buttons press through the ~0.3 s HID fast path and report nothing — re-run `ui` to observe."
    )
    public var reportFocus: Bool = false

    public var jsonOutput: Bool { json.enabled }
    public var daemonBypass: Bool { true }
    public var simulatorUDIDForDaemon: String? { device.resolved }

    public init() {}

    public func validate() throws {
        guard settleDelay >= 0 else {
            throw ValidationError("--settle-delay must be >= 0.")
        }
    }

    public mutating func resolveDeferredArguments() throws {
        try device.resolve()
    }

    public func execute() async throws -> TVOSRemoteResult {
        let controller = try TVOSController.live()
        return try await controller.pressRemote(
            button,
            udid: device.resolved,
            bundleId: target.bundleId,
            settleDelay: settleDelay,
            reportFocus: reportFocus
        )
    }

    public func format(_ result: TVOSRemoteResult) -> CommandOutput {
        // The HID fast path presses without observing; don't render a
        // misleading "no focused element -> no focused element".
        guard result.before != nil || result.after != nil else {
            return .line("Pressed \(result.button.rawValue)")
        }
        return .line("Pressed \(result.button.rawValue): \(focusDescription(result.before)) -> \(focusDescription(result.after))")
    }

    private func focusDescription(_ entry: Outline.Entry?) -> String {
        guard let entry else { return "no focused element" }
        return "@\(entry.aliases.at) \(entry.role) \"\(entry.label)\""
    }
}

extension TVOSRemoteButton: ExpressibleByArgument {}
