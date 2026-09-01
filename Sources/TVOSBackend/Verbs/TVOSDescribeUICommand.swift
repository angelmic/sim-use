// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import SimUseCore

/// Appium/XCUITest-backed tvOS UI hierarchy command. The W3C source is
/// normalised into the same `DescribeUIResult` used by the iOS and Android
/// backends, with tvOS's focused element retained as a `focused` state.
public struct TVOSDescribeUICommand: SimUseExecutableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "describe-ui",
        abstract: "Describe the foreground tvOS Simulator app and its focused element.",
        aliases: ["ui"]
    )

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

    public func execute() async throws -> DescribeUIResult {
        // Physical Apple TV: the device path renders the same outline but
        // gates `ui` off on tvOS ≤16 (WDA signal-9 crash). Simulator keeps
        // its controller.
        if PlatformRouter.looksLikeAppleDevice(device.resolved) {
            return try await TVOSDeviceController.live().describeUI(
                udid: device.resolved,
                includeRaw: jsonOutput,
                bundleId: target.bundleId
            )
        }
        return try await Self.performDescribeUI(
            udid: device.resolved,
            includeRaw: jsonOutput,
            bundleId: target.bundleId,
            controller: try TVOSController.live()
        )
    }

    public func format(_ result: DescribeUIResult) -> CommandOutput {
        .raw(result.outline)
    }

    public static func performDescribeUI(
        udid: String,
        includeRaw: Bool,
        bundleId: String? = nil,
        controller: TVOSController
    ) async throws -> DescribeUIResult {
        try await controller.describeUI(
            udid: udid,
            includeRaw: includeRaw,
            bundleId: bundleId
        )
    }
}
