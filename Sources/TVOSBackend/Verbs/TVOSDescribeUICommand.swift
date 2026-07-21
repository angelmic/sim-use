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
        try device.resolve()
    }

    public func execute() async throws -> DescribeUIResult {
        let controller = try TVOSController.live()
        return try await Self.performDescribeUI(
            udid: device.resolved,
            includeRaw: jsonOutput,
            bundleId: target.bundleId,
            controller: controller
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
