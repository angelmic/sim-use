// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import SimUseCore

/// Enters a whole string through the tvOS focus keyboard. Focus must
/// already sit on a text field (`tvos ui` shows it as `TextField` +
/// `focused`); the command opens the keyboard with `select`, sends the
/// string over the WebDriver element surface, and commits with `menu`.
public struct TVOSTypeCommand: SimUseExecutableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "type",
        abstract: "Type a string into the focused tvOS text field through the focus keyboard."
    )

    @Argument(help: "Text to enter into the focused text field.")
    public var text: String

    @OptionGroup public var device: DeviceOptions
    @OptionGroup public var target: TVOSTargetOptions
    @OptionGroup public var json: JSONOutputOptions

    public var jsonOutput: Bool { json.enabled }
    public var daemonBypass: Bool { true }
    public var simulatorUDIDForDaemon: String? { device.resolved }

    public init() {}

    public mutating func resolveDeferredArguments() throws {
        try device.resolve(allowPhysical: true)
    }

    public func execute() async throws -> TVOSTypeResult {
        if PlatformRouter.looksLikeAppleDevice(device.resolved) {
            return try await TVOSDeviceController.live().typeText(
                text,
                udid: device.resolved,
                bundleId: target.bundleId
            )
        }
        return try await TVOSController.live().typeText(
            text,
            udid: device.resolved,
            bundleId: target.bundleId
        )
    }

    public func format(_ result: TVOSTypeResult) -> CommandOutput {
        .line("Typed \"\(result.text)\"")
    }
}
