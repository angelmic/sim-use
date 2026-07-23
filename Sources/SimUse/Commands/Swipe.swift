// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore
import AndroidBackend
import iOSSimBackend
import DeviceBackend

/// Top-level cross-platform `swipe` verb. Owns the verb-specific flag
/// surface, resolves the target platform via `PlatformRouter`, then
/// delegates to the per-backend command struct (`IOSSimSwipeCommand`
/// for iOS UDIDs, `AndroidSwipeCommand.performSwipe` for adb
/// serials). Shared flag groups (`DeviceOptions`, `JSONOutputOptions`)
/// live in `SimUseCore/Options/` so the declaration is identical to
/// the one consumed by `sim-use ios swipe`.
struct Swipe: SimUseExecutableCommand {
    typealias ExecutionResult = IOSSimSwipeCommand.ExecutionResult

    static let configuration = CommandConfiguration(
        abstract: "Perform a swipe gesture from one point to another on the screen."
    )

    @OptionGroup var coordinates: SwipeCoordinateOptions

    @Option(name: .customLong("duration"), help: "Duration of the swipe in seconds.")
    var duration: Double?

    @Option(name: .customLong("delta"), help: "Distance between touch points in pixels.")
    var delta: Double?

    @Option(name: .customLong("pre-delay"), help: "Delay before starting the swipe in seconds.")
    var preDelay: Double?

    @Option(name: .customLong("post-delay"), help: "Delay after completing the swipe in seconds.")
    var postDelay: Double?

    @OptionGroup var device: DeviceOptions

    @Option(
        name: .customLong("bundle-id"),
        help: "Physical Apple device only: attach the WebDriverAgent session to this app and bring it to the foreground, so the swipe targets that app instead of the home screen. Ignored on the iOS Simulator and Android."
    )
    var bundleId: String?

    @OptionGroup var json: JSONOutputOptions

    var jsonOutput: Bool { json.enabled }

    mutating func resolveDeferredArguments() throws {
        try device.resolve()
    }

    var simulatorUDIDForDaemon: String? { device.resolved }

    /// The FBSimulator daemon drives only iOS Simulators; tvOS and physical
    /// Apple devices run through Appium, so reject/route in-process instead
    /// of spawning a per-UDID daemon for a target it cannot drive.
    var daemonBypass: Bool { PlatformRouter.bypassesSimulatorDaemon(udid: device.resolved) }

    /// Mirror `Tap` / `Button`'s "✓ … completed successfully" line.
    /// Without this the cross-platform `sim-use swipe` is silent on
    /// success in non-JSON mode, which is inconsistent with the other
    /// verbs and surprised users during release testing. Coordinates
    /// are rendered as integers for compactness; the iOS HID layer
    /// happens to consume them as Doubles but the user-facing
    /// numbers stay readable.
    func format(_ result: ExecutionResult) -> CommandOutput {
        .line("✓ Swipe \(result.coordinates.displaySummary) completed successfully")
    }

    func validate() throws {
        _ = try coordinates.resolve()
        try IOSSimSwipeCommand.validateTimingOptions(
            duration: duration,
            delta: delta,
            preDelay: preDelay,
            postDelay: postDelay
        )
    }

    func resolvedCoordinates() throws -> SwipeCoordinates {
        try coordinates.resolve()
    }

    func execute() async throws -> ExecutionResult {
        switch PlatformRouter.resolve(udid: device.resolved) {
        case .android:
            return try await executeAndroid()
        case .tvOSSim:
            throw TVOSCapabilityError(command: "swipe")
        case .appleDevice:
            return try await executeAppleDevice()
        case .iOSSim, .none:
            return try await executeIOSSim()
        }
    }

    private func executeIOSSim() async throws -> ExecutionResult {
        let sub = makeIOSSubcommand()
        return try await sub.execute()
    }

    /// Physical iOS device: a W3C pointer swipe from start to end over the
    /// requested duration (300 ms when unspecified). tvOS is rejected by
    /// the controller with `TVOSCapabilityError`.
    private func executeAppleDevice() async throws -> ExecutionResult {
        let coords = try resolvedCoordinates()
        let durationMs = duration.map { Int(($0 * 1000).rounded()) } ?? 300
        try await AppleDeviceController.live().swipe(
            udid: device.resolved,
            from: (x: coords.startX, y: coords.startY),
            to: (x: coords.endX, y: coords.endY),
            durationMs: durationMs,
            bundleId: bundleId
        )
        return ExecutionResult(coordinates: coords)
    }

    /// Construct the backend command and copy every parsed flag across.
    /// A missed field stays in ArgumentParser's wrapper-definition state
    /// and traps on first read (#42) — pinned by
    /// `ForwarderInitializationGuardTests`.
    func makeIOSSubcommand() -> IOSSimSwipeCommand {
        var sub = IOSSimSwipeCommand()
        sub.coordinates = coordinates
        sub.duration = duration
        sub.delta = delta
        sub.preDelay = preDelay
        sub.postDelay = postDelay
        sub.device = device
        sub.json = json
        return sub
    }

    /// Android dispatch. `duration` (iOS seconds) is re-mapped to
    /// milliseconds (Android bridge unit). `--delta` is iOS-HID
    /// granularity and has no Android equivalent (dispatchGesture
    /// interpolates internally), so it's silently ignored here.
    /// `pre-delay` / `post-delay` honored via `Task.sleep` around
    /// the bridge call — mirrors `Gesture.swift`'s `executeAndroid`.
    private func executeAndroid() async throws -> ExecutionResult {
        let coords = try coordinates.resolve()
        let durationMs = max(1, Int((duration ?? 0.3) * 1000))
        if let preDelay, preDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(preDelay * 1_000_000_000))
        }
        try AndroidSwipeCommand.performSwipe(
            udid: device.resolved,
            startX: coords.roundedStartX,
            startY: coords.roundedStartY,
            endX: coords.roundedEndX,
            endY: coords.roundedEndY,
            durationMs: durationMs
        )
        if let postDelay, postDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(postDelay * 1_000_000_000))
        }
        return ExecutionResult(coordinates: coords)
    }
}
