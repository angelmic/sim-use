// SPDX-License-Identifier: Apache-2.0
import Foundation
import AppiumCore
import SimUseCore

/// Tunables for physical-device capability assembly, all overridable by
/// environment so a differently-signed WebDriverAgent or a non-default
/// port needs no rebuild. Defaults are the values validated against the
/// office devices in Phase 0 (P0-C2/C3, tvOS 26 Addendum).
public struct DeviceCapabilityConfig: Sendable, Equatable {
    /// iOS preinstalled WDA product id, **without** the `.xctrunner`
    /// suffix — the XCUITest driver appends it when launching.
    public var iosWDABundleId: String
    /// Mac-side port the driver binds to proxy on-device WDA
    /// (`appium:wdaLocalPort`), for both iOS and tvOS. Explicit rather than
    /// left to the driver's default 8100 so a second task-owned server can
    /// dodge a port already held by another Appium (P0-C2's "change
    /// wdaLocalPort to bypass" recovery).
    public var wdaLocalPort: Int
    /// tvOS xcodebuild-flow WDA product id (again suffix-free).
    public var tvosWDABundleId: String
    /// Team id and signing identity for the tvOS xcodebuild WDA build.
    public var xcodeOrgId: String
    public var xcodeSigningId: String
    /// External WebDriverAgent URL for classic (≤16.x) devices. Nil unless
    /// `SIM_USE_WDA_URL` is set; a classic device without it fails fast.
    public var externalWDAURL: String?
    /// Session `newCommandTimeout` (seconds). 120 is the insurance value
    /// from the ticket — long enough that a slow observe/act pair never
    /// trips the idle reaper mid-command.
    public var newCommandTimeout: Int

    public init(
        iosWDABundleId: String = "com.catchplay.WebDriverAgentRunner",
        wdaLocalPort: Int = 8100,
        tvosWDABundleId: String = "com.catchplay.wda",
        xcodeOrgId: String = "MKK9DM2XD9",
        xcodeSigningId: String = "Apple Development",
        externalWDAURL: String? = nil,
        newCommandTimeout: Int = 120
    ) {
        self.iosWDABundleId = iosWDABundleId
        self.wdaLocalPort = wdaLocalPort
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
///   * iOS 17+ — `usePreinstalledWDA` against the pre-signed on-device
///     WDA, addressed by `updatedWDABundleId` + `wdaLocalPort` (P0-C2).
///   * tvOS 17+/26 — the xcodebuild flow (no preinstalled path exists on
///     tvOS): `xcodeOrgId` + `xcodeSigningId` + `updatedWDABundleId`
///     (tvOS 26 Addendum).
///   * ≤16.x (either family) — the classic external `webDriverAgentUrl`;
///     absent `SIM_USE_WDA_URL` is a fail-fast, not a silent hang.
public enum DeviceCapabilityBuilder {
    public static func capabilities(
        for info: PhysicalDeviceInfo,
        bundleId: String?,
        config: DeviceCapabilityConfig
    ) throws -> AppiumCapabilities {
        let platformName = info.family == .tvos ? "tvOS" : "iOS"
        var caps = AppiumCapabilities(
            platformName: platformName,
            automationName: "XCUITest",
            udid: info.udid,
            bundleId: bundleId?.nonBlank,
            newCommandTimeout: config.newCommandTimeout
        )

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

        // Both modern families proxy WDA over a Mac-side port; set it
        // explicitly so a second task-owned server can avoid a port an
        // existing Appium already holds.
        caps.wdaLocalPort = config.wdaLocalPort
        switch info.family {
        case .tvos:
            caps.updatedWDABundleId = config.tvosWDABundleId
            caps.xcodeOrgId = config.xcodeOrgId
            caps.xcodeSigningId = config.xcodeSigningId
        case .ios, .android:
            // .android never reaches here (PhysicalDeviceInfo rejects it);
            // the iOS preinstalled-WDA path is the default modern branch.
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
