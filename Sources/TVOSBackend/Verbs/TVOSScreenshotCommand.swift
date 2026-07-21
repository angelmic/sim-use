// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore

/// Captures the foreground tvOS Simulator through Appium's WebDriver
/// screenshot endpoint. The command bypasses the sim-use daemon because the
/// Appium session already provides the transport and is deliberately scoped
/// to this one operation.
public struct TVOSScreenshotCommand: SimUseExecutableCommand {
    public struct ExecutionResult: Codable, Equatable, Sendable {
        public let path: String

        public init(path: String) {
            self.path = path
        }
    }

    public static let configuration = CommandConfiguration(
        commandName: "screenshot",
        abstract: "Capture a screenshot from the tvOS Simulator and save it as a PNG file."
    )

    @OptionGroup public var device: DeviceOptions
    @OptionGroup public var target: TVOSTargetOptions

    @Option(help: "Output PNG file path. Defaults to 'tvOS Screenshot - <device> - <timestamp>.png' in the current directory.")
    public var output: String?

    @OptionGroup public var json: JSONOutputOptions

    public var jsonOutput: Bool { json.enabled }
    public var daemonBypass: Bool { true }
    public var simulatorUDIDForDaemon: String? { device.resolved }

    public init() {}

    public mutating func resolveDeferredArguments() throws {
        try device.resolve()
    }

    public func execute() async throws -> ExecutionResult {
        let controller = try TVOSController.live()
        let png = try await controller.screenshot(
            udid: device.resolved,
            bundleId: target.bundleId
        )
        let outputURL = try Self.prepareOutputURL(output: output, deviceID: device.resolved)
        try png.write(to: outputURL)
        return ExecutionResult(path: outputURL.path)
    }

    public func format(_ result: ExecutionResult) -> CommandOutput {
        CommandOutput(
            stdout: result.path + "\n",
            stderr: "Screenshot saved to \(result.path)\n"
        )
    }

    /// Resolve `--output` using the same file-or-directory rules as the iOS
    /// screenshot command while keeping the default name recognisably tvOS.
    public static func prepareOutputURL(output: String?, deviceID: String) throws -> URL {
        let fileManager = FileManager.default
        let providedPath = output?.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultFilename = "tvOS Screenshot - \(deviceID) - \(formatTimestamp(Date())).png"
        let resolvedPath: String
        if let providedPath, !providedPath.isEmpty {
            resolvedPath = (providedPath as NSString).expandingTildeInPath
        } else {
            resolvedPath = defaultFilename
        }

        let baseURL = resolvedPath.hasPrefix("/")
            ? URL(fileURLWithPath: resolvedPath)
            : URL(fileURLWithPath: fileManager.currentDirectoryPath).appendingPathComponent(resolvedPath)

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: baseURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return baseURL.appendingPathComponent(defaultFilename)
        }

        let directoryURL = baseURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directoryURL.path) {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
        if fileManager.fileExists(atPath: baseURL.path) {
            try fileManager.removeItem(at: baseURL)
        }
        return baseURL
    }

    private static func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter.string(from: date)
    }
}
