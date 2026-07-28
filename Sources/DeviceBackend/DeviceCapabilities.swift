// SPDX-License-Identifier: Apache-2.0
import Foundation
import AppiumCore
import SimUseCore

/// Tunables for physical-device capability assembly, all overridable by
/// environment so a differently-signed WebDriverAgent or a non-default
/// port needs no rebuild. Defaults are app/team-agnostic (D7: the CLI never
/// bakes in a value specific to one app or developer account) — the WDA
/// bundle ids follow the upstream WebDriverAgent naming convention, and the
/// Team id has no universal default (see `xcodeOrgId`).
public struct DeviceCapabilityConfig: Sendable, Equatable {
    /// iOS preinstalled WDA product id, **without** the `.xctrunner`
    /// suffix — the XCUITest driver appends it when launching. Override for
    /// a re-signed WDA via `SIM_USE_WDA_BUNDLE_ID`.
    public var iosWDABundleId: String
    /// Mac-side port the driver binds to proxy on-device WDA
    /// (`appium:wdaLocalPort`), for both iOS and tvOS. Explicit rather than
    /// left to the driver's default 8100 so a second task-owned server can
    /// dodge a port already held by another Appium (P0-C2's "change
    /// wdaLocalPort to bypass" recovery).
    public var wdaLocalPort: Int
    /// Optional device-side port where WDA actually listens
    /// (`appium:wdaRemotePort`). Leave nil so Appium keeps its normal
    /// local/remote-port coupling; set `SIM_USE_WDA_REMOTE_PORT` only when a
    /// preinstalled WDA is known to listen on a different device-side port.
    public var wdaRemotePort: Int?
    /// tvOS WDA product id (again suffix-free). The installed-runner
    /// supervisor appends `.xctrunner`; the xcodebuild repair path uses the
    /// same id. Override via `SIM_USE_TVOS_WDA_BUNDLE_ID`.
    public var tvosWDABundleId: String
    /// Apple Developer **Team id** for an xcodebuild WDA build. tvOS needs it
    /// on its build path; iOS uses it to enable its verified prebuilt cache
    /// and automatic signing repair. No universal default exists, so callers
    /// supply it via `SIM_USE_XCODE_ORG_ID`.
    public var xcodeOrgId: String?
    /// Signing identity for an iOS/tvOS xcodebuild WDA build. "Apple
    /// Development" is Apple's generic identity name (not account-specific);
    /// override via `SIM_USE_XCODE_SIGNING_ID`.
    public var xcodeSigningId: String
    /// External WebDriverAgent URL for classic (≤16.x) devices. Nil unless
    /// `SIM_USE_WDA_URL` is set; a classic device without it fails fast.
    public var externalWDAURL: String?
    /// Session `newCommandTimeout` (seconds). 120 is the insurance value
    /// from the ticket — long enough that a slow observe/act pair never
    /// trips the idle reaper mid-command.
    public var newCommandTimeout: Int

    public init(
        iosWDABundleId: String = "com.facebook.WebDriverAgentRunner",
        wdaLocalPort: Int = 8100,
        wdaRemotePort: Int? = nil,
        tvosWDABundleId: String = "com.facebook.WebDriverAgentRunner",
        xcodeOrgId: String? = nil,
        xcodeSigningId: String = "Apple Development",
        externalWDAURL: String? = nil,
        newCommandTimeout: Int = 120
    ) {
        self.iosWDABundleId = iosWDABundleId
        self.wdaLocalPort = wdaLocalPort
        self.wdaRemotePort = wdaRemotePort
        self.tvosWDABundleId = tvosWDABundleId
        self.xcodeOrgId = xcodeOrgId
        self.xcodeSigningId = xcodeSigningId
        self.externalWDAURL = externalWDAURL
        self.newCommandTimeout = newCommandTimeout
    }

    public static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> DeviceCapabilityConfig {
        var config = DeviceCapabilityConfig()
        if let value = environment["SIM_USE_WDA_BUNDLE_ID"]?.nonBlank { config.iosWDABundleId = value }
        if let value = environment["SIM_USE_WDA_LOCAL_PORT"].flatMap({ Int($0) }) { config.wdaLocalPort = value }
        if let value = environment["SIM_USE_WDA_REMOTE_PORT"].flatMap({ Int($0) }) { config.wdaRemotePort = value }
        if let value = environment["SIM_USE_TVOS_WDA_BUNDLE_ID"]?.nonBlank { config.tvosWDABundleId = value }
        if let value = environment["SIM_USE_XCODE_ORG_ID"]?.nonBlank { config.xcodeOrgId = value }
        if let value = environment["SIM_USE_XCODE_SIGNING_ID"]?.nonBlank { config.xcodeSigningId = value }
        config.externalWDAURL = environment["SIM_USE_WDA_URL"]?.nonBlank
        return config
    }
}

/// Assembles the `AppiumCapabilities` for one physical-device session. The
/// shape is a function of the resolved device facts, not a guess:
///
///   * iOS 17+ — this builder emits the installed-WDA fallback, addressed by
///     `updatedWDABundleId` plus independent local/remote WDA ports (P0-C2).
///     When signing inputs are configured, `AppleDeviceController` replaces
///     it before session creation with the verified per-device prebuilt or
///     one-shot incremental build path.
///   * tvOS 17+/26 — normally attach-only to the XCTest-backed installed
///     runner owned by `TVOSWDASupervisor`. If that path is disabled or has
///     no target app, this builder retains the signed xcodebuild repair
///     path: `xcodeOrgId` + `xcodeSigningId` + `updatedWDABundleId`.
///   * ≤16.x (either family) — the classic external `webDriverAgentUrl`;
///     absent `SIM_USE_WDA_URL` is a fail-fast, not a silent hang.
public enum DeviceCapabilityBuilder {
    public static func capabilities(
        for info: PhysicalDeviceInfo,
        bundleId: String?,
        config: DeviceCapabilityConfig,
        externalWDAURL: String? = nil
    ) throws -> AppiumCapabilities {
        let platformName = info.family == .tvos ? "tvOS" : "iOS"
        // A bundle id makes the session attach to (and foreground) that app;
        // with none, it attaches to whatever is foreground. `autoLaunch`
        // gates that foregrounding on a bundle being present, and `noReset`
        // keeps the app's state across the one-session-per-command model so
        // a `tap` that navigated into a screen isn't reset by the next
        // `type`'s session — the mechanism the tvOS Simulator path proved.
        let resolvedBundleId = bundleId?.nonBlank
        // Activate semantics, not launch: keep autoLaunch off and let the
        // controller `mobile: activateApp` the bundle after the session opens.
        // `autoLaunch: true` cold-launches a real app back to its root screen
        // every session (there's no launch-arg to jump screens), losing
        // navigation across the one-session-per-command model; activate
        // foregrounds the already-running app at its current screen (P0-C
        // verified). `shouldTerminateApp: false` leaves it running at session
        // end so the next command can re-foreground it there.
        let targetsApp = resolvedBundleId != nil
        var caps = AppiumCapabilities(
            platformName: platformName,
            platformVersion: info.osVersion,
            automationName: "XCUITest",
            udid: info.udid,
            bundleId: resolvedBundleId,
            autoLaunch: targetsApp ? false : nil,
            noReset: true,
            newCommandTimeout: config.newCommandTimeout,
            shouldTerminateApp: targetsApp ? false : nil
        )

        // A caller-owned WDA lifecycle (currently the modern physical-tvOS
        // XCTest supervisor) is an attach-only Appium session. Return before
        // adding any xcodebuild, preinstalled-launch, or proxy-port
        // capabilities: those would make Appium try to own the same WDA a
        // second time.
        if let externalWDAURL = externalWDAURL?.nonBlank {
            caps.webDriverAgentUrl = externalWDAURL
            return caps
        }

        guard info.isModern else {
            // Classic ≤16.x: WDA can only be reached over an externally
            // started tunnel (idevicedebug + iproxy). No usePreinstalledWDA,
            // no xcodebuild — either we have a URL or we stop with the recipe.
            guard let url = config.externalWDAURL else {
                throw DevicePreflightError.classicWDAMissing(
                    udid: info.udid,
                    wdaBundleId: info.family == .tvos ? config.tvosWDABundleId : config.iosWDABundleId
                )
            }
            caps.webDriverAgentUrl = url
            return caps
        }

        // Both modern families proxy WDA over a Mac-side port. Emit a
        // device-side override only when the caller explicitly supplied one;
        // otherwise Appium keeps its normal local/remote-port coupling.
        caps.wdaLocalPort = config.wdaLocalPort
        caps.wdaRemotePort = config.wdaRemotePort
        switch info.family {
        case .tvos:
            // The tvOS xcodebuild flow signs WDA with the caller's Apple
            // Developer Team, which the CLI cannot guess — fail fast when it
            // is unset rather than emitting an unsigned build that hangs.
            guard let orgId = config.xcodeOrgId else {
                throw DevicePreflightError.xcodeOrgIdMissing(udid: info.udid)
            }
            caps.updatedWDABundleId = config.tvosWDABundleId
            caps.xcodeOrgId = orgId
            caps.xcodeSigningId = config.xcodeSigningId
        case .ios, .android:
            // .android never reaches here (PhysicalDeviceInfo rejects it);
            // this is also the iOS fallback when no signing/cache policy is
            // configured. AppleDeviceController replaces it before session
            // creation when the per-device cache can manage the runner.
            caps.usePreinstalledWDA = true
            caps.updatedWDABundleId = config.iosWDABundleId
        }
        return caps
    }
}

extension String {
    /// The trimmed string, or nil when it is empty/whitespace — so a blank
    /// env var or `--bundle-id ""` is treated as "unset" rather than a
    /// literal empty capability.
    fileprivate var nonBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
