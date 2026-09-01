// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore
import AndroidBackend
import iOSSimBackend
import TVOSBackend
import DeviceBackend

/// Top-level cross-platform `screenshot` verb. Owns the flag surface
/// and resolves the target platform, then delegates to the per-backend
/// command (`IOSSimScreenshotCommand` for iOS Simulator UDIDs,
/// `AndroidScreenshotCommand.performScreenshot` for adb serials).
///
/// Output path resolution differs slightly between platforms — the
/// iOS default filename embeds the FBSimulator friendly name; the
/// Android default uses the adb serial because the friendly name
/// isn't available at the bridge layer. Both honour `--output`
/// pointing at either a file or a directory.
struct Screenshot: SimUseExecutableCommand {
    typealias ExecutionResult = IOSSimScreenshotCommand.ExecutionResult

    enum ExecutionBackend: Equatable {
        case android
        case iOSSimulator
        case tvOSSimulator
        case appleDevice
    }

    static let configuration = CommandConfiguration(
        commandName: "screenshot",
        abstract: "Capture a screenshot from the simulator display and save it as a PNG file"
    )

    @OptionGroup var device: DeviceOptions
    @OptionGroup var tvosTarget: TVOSTargetOptions

    /// The shared target option is also the physical-iOS app target. Keep
    /// this named seam visible to tests so the device branch cannot silently
    /// drop a parsed `--bundle-id` again.
    var appleDeviceBundleId: String? { tvosTarget.bundleId }

    @Option(help: "Output PNG file path. Defaults to 'Simulator Screenshot - <device name> - <timestamp>.png' in the current directory.")
    var output: String?

    @OptionGroup var json: JSONOutputOptions

    var jsonOutput: Bool { json.enabled }

    mutating func resolveDeferredArguments() throws {
        try device.resolve(allowPhysical: true)
    }

    var simulatorUDIDForDaemon: String? { device.resolved }

    var daemonBypass: Bool { true }

    func format(_ result: ExecutionResult) -> CommandOutput {
        CommandOutput(
            stdout: result.path + "\n",
            stderr: "Screenshot saved to \(result.path)\n"
        )
    }

    func execute() async throws -> ExecutionResult {
        switch Self.executionBackend(for: PlatformRouter.resolve(udid: device.resolved)) {
        case .android:
            return try executeAndroid()
        case .tvOSSimulator:
            return try await executeTVOS()
        case .iOSSimulator:
            return try await executeIOSSim()
        case .appleDevice:
            return try await executeAppleDevice()
        }
    }

    static func executionBackend(for platform: Platform?) -> ExecutionBackend {
        switch platform {
        case .android:
            return .android
        case .tvOSSim:
            return .tvOSSimulator
        case .appleDevice:
            return .appleDevice
        case .iOSSim, .none:
            return .iOSSimulator
        }
    }

    private func executeIOSSim() async throws -> ExecutionResult {
        let sub = makeIOSSubcommand()
        return try await sub.execute()
    }

    private func executeTVOS() async throws -> ExecutionResult {
        let sub = makeTVOSSubcommand()
        let result = try await sub.execute()
        return ExecutionResult(path: result.path)
    }

    /// Construct the tvOS backend command and copy every parsed flag across.
    /// Keeping this explicit mirrors the iOS forwarder and lets the guard test
    /// catch any future uninitialised ArgumentParser wrapper.
    func makeTVOSSubcommand() -> TVOSScreenshotCommand {
        var sub = TVOSScreenshotCommand()
        sub.output = output
        sub.device = device
        sub.target = tvosTarget
        sub.json = json
        return sub
    }

    /// Construct the backend command and copy every parsed flag across.
    /// A missed field stays in ArgumentParser's wrapper-definition state
    /// and traps on first read (#42) — pinned by
    /// `ForwarderInitializationGuardTests`.
    func makeIOSSubcommand() -> IOSSimScreenshotCommand {
        var sub = IOSSimScreenshotCommand()
        sub.output = output
        sub.device = device
        sub.json = json
        return sub
    }

    private func executeAndroid() throws -> ExecutionResult {
        let png = try AndroidScreenshotCommand.performScreenshot(udid: device.resolved)
        return try write(png, defaultLabel: "Android Screenshot", id: device.resolved)
    }

    /// Physical iOS/tvOS device: capture through the Appium session (the
    /// caps assembler picks the right WDA path per family) and save the PNG.
    private func executeAppleDevice() async throws -> ExecutionResult {
        let png = try await AppleDeviceController.live().screenshot(
            udid: device.resolved,
            bundleId: appleDeviceBundleId
        )
        return try write(png, defaultLabel: "Device Screenshot", id: device.resolved)
    }

    /// Resolve the output path, create the directory, and write the PNG —
    /// shared by the Android and physical-device paths (the iOS Simulator
    /// path owns its own FBSimulator-friendly naming).
    private func write(_ png: Data, defaultLabel: String, id: String) throws -> ExecutionResult {
        let url = URL(fileURLWithPath: resolveOutputPath(defaultLabel: defaultLabel, id: id))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: url)
        return ExecutionResult(path: url.path)
    }

    private func resolveOutputPath(defaultLabel: String, id: String) -> String {
        let stamp = IOSSimScreenshotCommand.formatTimestamp(Date())
        // The adb-serial and Apple-UDID charsets the router accepts already
        // exclude path separators; the sanitiser is defence in depth should
        // those routing rules ever loosen.
        let defaultName = "\(defaultLabel) - \(OutputFilePath.safeFilenameComponent(id)) - \(stamp).png"
        guard let provided = output?.trimmingCharacters(in: .whitespacesAndNewlines), !provided.isEmpty else {
            return FileManager.default.currentDirectoryPath + "/" + defaultName
        }
        let expanded = (provided as NSString).expandingTildeInPath
        let absolute = expanded.hasPrefix("/")
            ? expanded
            : FileManager.default.currentDirectoryPath + "/" + expanded
        // If the user pointed `--output` at a directory (existing or
        // with a trailing slash), append the stamped filename there.
        // Otherwise treat the path as a file destination. Mirrors the
        // iOS-side `--output` behaviour where the same expansion rules
        // apply.
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: absolute, isDirectory: &isDirectory)
        if (exists && isDirectory.boolValue) || absolute.hasSuffix("/") {
            let dir = absolute.hasSuffix("/") ? String(absolute.dropLast()) : absolute
            return dir + "/" + defaultName
        }
        return absolute
    }
}
