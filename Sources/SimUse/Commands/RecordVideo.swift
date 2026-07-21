// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore
import SimUseVideo
import AndroidBackend
import iOSSimBackend

/// Top-level cross-platform `record-video` verb. Owns the flag
/// surface and resolves the target platform, then delegates to:
///
///   * `IOSSimRecordVideoCommand.execute()` for iOS Simulator UDIDs
///     (which drives `FBSimulatorVideoStream` eager H.264 at `--fps`).
///   * `AndroidRecordVideoCommand.record()` for adb serials (which
///     streams `adb exec-out screenrecord --output-format=h264` into
///     the shared H.264 → MP4 passthrough muxer).
struct RecordVideo: SimUseExecutableCommand {
    typealias ExecutionResult = IOSSimRecordVideoCommand.ExecutionResult

    static let configuration = CommandConfiguration(
        commandName: "record-video",
        abstract: "Record the simulator display to an MP4 file using H.264 encoding"
    )

    @OptionGroup var device: DeviceOptions

    @Option(help: "Frames per second (1-60, default: 30). Ignored on Android (screenrecord uses the device's native variable frame rate).")
    var fps: Int?

    @Option(help: "Quality factor (1-100) controlling bitrate (default: 80)")
    var quality: Int = 80

    @Option(help: "Scale factor (0.1-1.0, default: 1.0)")
    var scale: Double = 1.0

    @Option(help: "Output MP4 file path. Defaults to sim-use-video-<timestamp>.mp4 in the current directory.")
    var output: String?

    @OptionGroup var json: JSONOutputOptions

    var jsonOutput: Bool { json.enabled }

    mutating func resolveDeferredArguments() throws {
        try device.resolve()
    }

    var simulatorUDIDForDaemon: String? { device.resolved }

    var daemonBypass: Bool { true }

    func format(_ result: ExecutionResult) -> CommandOutput {
        CommandOutput(
            stdout: result.path + "\n",
            stderr: "Recording saved to \(result.path)\n"
        )
    }

    func validate() throws {
        try VideoRecordingOptions.validate(fps: fps, quality: quality, scale: scale)
    }

    func execute() async throws -> ExecutionResult {
        switch PlatformRouter.resolve(udid: device.resolved) {
        case .android:
            return try await executeAndroid()
        case .tvOSSim:
            throw TVOSCapabilityError(command: "record-video")
        case .iOSSim, .none:
            return try await executeIOSSim()
        }
    }

    private func executeIOSSim() async throws -> ExecutionResult {
        let sub = makeIOSSubcommand()
        return try await sub.execute()
    }

    /// Construct the backend command and copy every parsed flag across.
    /// A missed field stays in ArgumentParser's wrapper-definition state
    /// and traps on first read (#42) — pinned by
    /// `ForwarderInitializationGuardTests`.
    func makeIOSSubcommand() -> IOSSimRecordVideoCommand {
        var sub = IOSSimRecordVideoCommand()
        sub.fps = fps
        sub.quality = quality
        sub.scale = scale
        sub.output = output
        sub.device = device
        sub.json = json
        return sub
    }

    private func executeAndroid() async throws -> ExecutionResult {
        let outputURL = try await AndroidRecordVideoCommand.record(
            serial: device.resolved,
            output: output,
            fps: fps,
            quality: quality,
            scale: scale
        )
        return ExecutionResult(path: outputURL.path)
    }
}
