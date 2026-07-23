// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore
import AndroidBackend
import iOSSimBackend
import TVOSBackend
import DeviceBackend

/// Top-level cross-platform `describe-ui` verb. Owns the flag surface
/// and resolves the target platform, then delegates to the per-backend
/// command (`IOSSimDescribeUICommand` for iOS Simulator UDIDs,
/// `AndroidDescribeUICommand.performDescribeUI` for adb serials).
///
/// `--include-offscreen` is Android-only — silently ignored on iOS
/// (the iOS pipeline has no equivalent visibility flag).
struct DescribeUI: SimUseExecutableCommand {
    typealias ExecutionResult = IOSSimDescribeUICommand.ExecutionResult

    enum ExecutionBackend: Equatable {
        case android
        case iOSSimulator
        case tvOSSimulator
        case appleDevice
    }

    static let configuration = CommandConfiguration(
        abstract: "Describes the UI hierarchy of a booted simulator using accessibility information.",
        aliases: ["ui"]
    )

    @OptionGroup var device: DeviceOptions
    @OptionGroup var tvosTarget: TVOSTargetOptions

    @Option(
        name: .customLong("point"),
        help: ArgumentHelp(
            "Describe only the accessibility element at screen coordinates x,y.",
            valueName: "x,y"
        )
    )
    var point: CoordinatePair?

    @Option(
        name: .customLong("max-probes"),
        help: ArgumentHelp(
            "Probe budget for collapsed-children / blind-zone recovery (default 300). Higher values expand coverage in large WebView-like regions at the cost of latency.",
            valueName: "n"
        )
    )
    var maxProbes: Int = 300

    @Option(
        name: .customLong("min-cell-size"),
        help: ArgumentHelp(
            "Minimum quadtree cell size in points (default 14). Lower values reach finer elements (thin nav bars, tiny icons) at the cost of more probes.",
            valueName: "pt"
        )
    )
    var minCellSize: Double = 14

    @Option(
        name: .customLong("seed-cell-width"),
        help: ArgumentHelp(
            "Initial X-stride of the quadtree seed grid in points (default 160). Advanced tuning — smaller values give finer X-resolution but more seed probes; larger values are faster on wide-element screens.",
            valueName: "pt"
        )
    )
    var seedCellWidth: Double = 160

    @Option(
        name: .customLong("seed-cell-height"),
        help: ArgumentHelp(
            "Initial Y-stride of the quadtree seed grid in points (default 80). Advanced tuning — lower it if the screen has many thin horizontal rows you want to reach in the first probe pass.",
            valueName: "pt"
        )
    )
    var seedCellHeight: Double = 80

    @OptionGroup var json: JSONOutputOptions

    var jsonOutput: Bool { json.enabled }

    /// tvOS and physical Apple devices use short-lived Appium sessions and
    /// must not be routed through the iOS FBSimulator daemon.
    var daemonBypass: Bool {
        PlatformRouter.bypassesSimulatorDaemon(udid: device.resolved)
    }

    @Flag(
        name: .customLong("include-offscreen"),
        help: "Android-only. Include nodes whose `isVisibleToUser` is false (recycled list cells, off-screen ViewPager neighbours, fragments mid-detach). Default is to filter them out — they pad the outline with rows the user can't actually see. Ignored on iOS (the iOS pipeline has no equivalent visibility flag)."
    )
    var includeOffscreen: Bool = false

    mutating func resolveDeferredArguments() throws {
        try device.resolve()
    }

    var simulatorUDIDForDaemon: String? { device.resolved }

    func validate() throws {
        try IOSSimDescribeUICommand.validatePoint(point)
        try IOSSimDescribeUICommand.validateOptions(
            maxProbes: maxProbes,
            minCellSize: minCellSize,
            seedCellWidth: seedCellWidth,
            seedCellHeight: seedCellHeight
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

    func format(_ result: ExecutionResult) -> CommandOutput {
        .raw(result.outline)
    }

    private func executeIOSSim() async throws -> ExecutionResult {
        let sub = makeIOSSubcommand()
        return try await sub.execute()
    }

    private func executeTVOS() async throws -> ExecutionResult {
        let sub = makeTVOSSubcommand()
        return reshape(try await sub.execute())
    }

    /// Physical Apple device: an Apple TV renders through the tvOS device
    /// path (focus-aware, ≤16 ui fail-fast); an iPhone/iPad through the iOS
    /// device outline (#id selectors). Family comes from `devicectl`; an
    /// unresolved UDID defaults to the iOS path, whose preflight surfaces
    /// the clearer not-found / tunnel error.
    private func executeAppleDevice() async throws -> ExecutionResult {
        let bundleId = tvosTarget.bundleId
        if DeviceInfoResolver().resolve(udid: device.resolved)?.family == .tvos {
            return reshape(try await TVOSDeviceController.live().describeUI(
                udid: device.resolved, includeRaw: jsonOutput, bundleId: bundleId
            ))
        }
        return reshape(try await AppleDeviceController.live().describeUI(
            udid: device.resolved, includeRaw: jsonOutput, bundleId: bundleId
        ))
    }

    /// Map the shared cross-platform envelope into this command's local
    /// `ExecutionResult` so every backend surfaces one shape.
    private func reshape(_ result: DescribeUIResult) -> ExecutionResult {
        ExecutionResult(
            platform: result.platform.rawValue,
            raw: result.raw,
            outline: result.outline,
            entries: result.entries,
            lists: result.lists,
            screen: result.screen,
            appLabel: result.appLabel,
            appPackage: result.appPackage,
            crashDialog: result.crashDialog
        )
    }

    /// Construct the tvOS backend command and copy every parsed flag across.
    /// In particular, the target bundle keeps a cold WDA launch from leaving
    /// the source request attached to the tvOS Home screen.
    func makeTVOSSubcommand() -> TVOSDescribeUICommand {
        var sub = TVOSDescribeUICommand()
        sub.device = device
        sub.target = tvosTarget
        sub.json = json
        return sub
    }

    /// Construct the backend command and copy every parsed flag across.
    /// A missed field stays in ArgumentParser's wrapper-definition state
    /// and traps on first read (#42) — pinned by
    /// `ForwarderInitializationGuardTests`.
    func makeIOSSubcommand() -> IOSSimDescribeUICommand {
        var sub = IOSSimDescribeUICommand()
        sub.point = point
        sub.maxProbes = maxProbes
        sub.minCellSize = minCellSize
        sub.seedCellWidth = seedCellWidth
        sub.seedCellHeight = seedCellHeight
        sub.device = device
        sub.json = json
        return sub
    }

    /// Android dispatch: routes through `AndroidDescribeUICommand.performDescribeUI`
    /// (shared with `sim-use android describe-ui`) and reshapes the
    /// cross-platform `DescribeUIResult` into this command's local
    /// `ExecutionResult` shape so callers — including the daemon
    /// wire — see a single envelope regardless of platform.
    private func executeAndroid() throws -> ExecutionResult {
        let result = try AndroidDescribeUICommand.performDescribeUI(
            udid: device.resolved,
            includeOffscreen: includeOffscreen,
            includeRaw: jsonOutput
        )
        return ExecutionResult(
            platform: result.platform.rawValue,
            raw: result.raw,
            outline: result.outline,
            entries: result.entries,
            lists: result.lists,
            screen: result.screen,
            appLabel: result.appLabel,
            appPackage: result.appPackage,
            crashDialog: result.crashDialog
        )
    }
}
