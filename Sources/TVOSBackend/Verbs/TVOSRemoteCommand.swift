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
            settleDelay: settleDelay
        )
    }

    public func format(_ result: TVOSRemoteResult) -> CommandOutput {
        .line("Pressed \(result.button.rawValue): \(focusDescription(result.before)) -> \(focusDescription(result.after))")
    }

    private func focusDescription(_ entry: Outline.Entry?) -> String {
        guard let entry else { return "no focused element" }
        return "@\(entry.aliases.at) \(entry.role) \"\(entry.label)\""
    }
}

extension TVOSRemoteButton: ExpressibleByArgument {}
