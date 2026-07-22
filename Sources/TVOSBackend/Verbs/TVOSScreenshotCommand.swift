// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore

/// Captures the tvOS Simulator display. Two paths:
///
///   * no --bundle-id: `simctl io screenshot` — ~0.7 s, no Appium
///     involved, captures whatever is on screen right now
///   * --bundle-id: the Appium WebDriver endpoint, whose session restores
///     the target app to the foreground first (the cold-WDA recovery)
///
/// Bypasses the sim-use daemon either way: one path has its own transport,
/// the other is a single simctl invocation.
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
        let outputURL = try Self.prepareOutputURL(output: output, deviceID: device.resolved)
        if let bundleId = target.bundleId {
            // Appium path: the session brings the requested app to the
            // foreground before capturing.
            let controller = try TVOSController.live()
            let png = try await controller.screenshot(
                udid: device.resolved,
                bundleId: bundleId
            )
            try png.write(to: outputURL)
        } else {
            try await Self.captureViaSimctl(device.resolved, outputURL)
        }
        return ExecutionResult(path: outputURL.path)
    }

    /// `xcrun simctl io <udid> screenshot <path>` — replaceable in unit
    /// tests, which must not require a booted simulator.
    nonisolated(unsafe) static var captureViaSimctl: (String, URL) async throws -> Void = { udid, url in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "io", udid, "screenshot", url.path]
        let stderr = Pipe()
        process.standardOutput = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(
                data: stderr.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw CLIError(errorDescription: "simctl screenshot failed (exit \(process.terminationStatus)): \(message)")
        }
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
