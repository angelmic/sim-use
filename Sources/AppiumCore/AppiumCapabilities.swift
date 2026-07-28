// SPDX-License-Identifier: Apache-2.0
import Foundation

public struct AppiumCapabilities: Sendable, Encodable {
    public var platformName: String
    /// Exact device OS version. Appium requires the vendor-prefixed
    /// `appium:platformVersion` capability; XCUITest uses it to select
    /// RemoteXPC/deployment behavior without probing or guessing from the
    /// UDID.
    public var platformVersion: String?
    public var automationName: String?
    public var udid: String?
    public var bundleId: String?
    public var autoLaunch: Bool?
    public var noReset: Bool?
    public var useNewWDA: Bool?
    /// Reuse a previously built WDA product and run only
    /// `test-without-building`. DeviceBackend sets this only after its
    /// fingerprint and code-signing cache validates.
    public var usePrebuiltWDA: Bool?
    /// Stable per-device Xcode DerivedData location. It is emitted even on
    /// a cache miss so the repair build remains incremental.
    public var derivedDataPath: String?
    public var newCommandTimeout: Int?
    public var wdaLocalPort: Int?
    /// Port WebDriverAgent listens on on the physical device. This is
    /// intentionally independent from `wdaLocalPort`: a preinstalled WDA
    /// commonly remains on 8100 while the Mac-side proxy must use another
    /// port because 8100 is already occupied.
    public var wdaRemotePort: Int?
    public var usePreinstalledWDA: Bool?
    public var updatedWDABundleId: String?
    public var webDriverAgentUrl: String?
    /// Leave the app-under-test running when the session ends, so the next
    /// command's session can re-foreground it (via `mobile: activateApp`) at
    /// the screen a previous command navigated to rather than a cold start.
    /// Nil (driver default) off the device path.
    public var shouldTerminateApp: Bool?
    /// Apple Developer Team id for the xcodebuild WDA flow. Physical tvOS
    /// 17+/26 has no `usePreinstalledWDA` path: Appium builds and launches
    /// WDA via xcodebuild with automatic signing, which needs the Team id
    /// (a 10-character account identifier) and a signing identity. Unused by
    /// the Simulator and the iOS preinstalled-WDA paths, so it stays nil there.
    public var xcodeOrgId: String?
    public var xcodeSigningId: String?

    public init(
        platformName: String,
        platformVersion: String? = nil,
        automationName: String? = nil,
        udid: String? = nil,
        bundleId: String? = nil,
        autoLaunch: Bool? = nil,
        noReset: Bool? = nil,
        useNewWDA: Bool? = nil,
        usePrebuiltWDA: Bool? = nil,
        derivedDataPath: String? = nil,
        newCommandTimeout: Int? = nil,
        wdaLocalPort: Int? = nil,
        wdaRemotePort: Int? = nil,
        usePreinstalledWDA: Bool? = nil,
        updatedWDABundleId: String? = nil,
        webDriverAgentUrl: String? = nil,
        shouldTerminateApp: Bool? = nil,
        xcodeOrgId: String? = nil,
        xcodeSigningId: String? = nil
    ) {
        self.platformName = platformName
        self.platformVersion = platformVersion
        self.automationName = automationName
        self.udid = udid
        self.bundleId = bundleId
        self.autoLaunch = autoLaunch
        self.noReset = noReset
        self.useNewWDA = useNewWDA
        self.usePrebuiltWDA = usePrebuiltWDA
        self.derivedDataPath = derivedDataPath
        self.newCommandTimeout = newCommandTimeout
        self.wdaLocalPort = wdaLocalPort
        self.wdaRemotePort = wdaRemotePort
        self.usePreinstalledWDA = usePreinstalledWDA
        self.updatedWDABundleId = updatedWDABundleId
        self.webDriverAgentUrl = webDriverAgentUrl
        self.shouldTerminateApp = shouldTerminateApp
        self.xcodeOrgId = xcodeOrgId
        self.xcodeSigningId = xcodeSigningId
    }

    enum CodingKeys: String, CodingKey {
        case platformName
        case platformVersion = "appium:platformVersion"
        case automationName = "appium:automationName"
        case udid = "appium:udid"
        case bundleId = "appium:bundleId"
        case autoLaunch = "appium:autoLaunch"
        case noReset = "appium:noReset"
        case useNewWDA = "appium:useNewWDA"
        case usePrebuiltWDA = "appium:usePrebuiltWDA"
        case derivedDataPath = "appium:derivedDataPath"
        case newCommandTimeout = "appium:newCommandTimeout"
        case wdaLocalPort = "appium:wdaLocalPort"
        case wdaRemotePort = "appium:wdaRemotePort"
        case usePreinstalledWDA = "appium:usePreinstalledWDA"
        case updatedWDABundleId = "appium:updatedWDABundleId"
        case webDriverAgentUrl = "appium:webDriverAgentUrl"
        case shouldTerminateApp = "appium:shouldTerminateApp"
        case xcodeOrgId = "appium:xcodeOrgId"
        case xcodeSigningId = "appium:xcodeSigningId"
    }

    /// Optional fields are emitted with `encodeIfPresent`, never as
    /// explicit `null`: an assembly sets only the caps its platform needs,
    /// and a `null` the shipping tvOS Simulator path never sent could
    /// change how the Appium server negotiates the session.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(platformName, forKey: .platformName)
        try container.encodeIfPresent(platformVersion, forKey: .platformVersion)
        try container.encodeIfPresent(automationName, forKey: .automationName)
        try container.encodeIfPresent(udid, forKey: .udid)
        try container.encodeIfPresent(bundleId, forKey: .bundleId)
        try container.encodeIfPresent(autoLaunch, forKey: .autoLaunch)
        try container.encodeIfPresent(noReset, forKey: .noReset)
        try container.encodeIfPresent(useNewWDA, forKey: .useNewWDA)
        try container.encodeIfPresent(usePrebuiltWDA, forKey: .usePrebuiltWDA)
        try container.encodeIfPresent(derivedDataPath, forKey: .derivedDataPath)
        try container.encodeIfPresent(newCommandTimeout, forKey: .newCommandTimeout)
        try container.encodeIfPresent(wdaLocalPort, forKey: .wdaLocalPort)
        try container.encodeIfPresent(wdaRemotePort, forKey: .wdaRemotePort)
        try container.encodeIfPresent(usePreinstalledWDA, forKey: .usePreinstalledWDA)
        try container.encodeIfPresent(updatedWDABundleId, forKey: .updatedWDABundleId)
        try container.encodeIfPresent(webDriverAgentUrl, forKey: .webDriverAgentUrl)
        try container.encodeIfPresent(shouldTerminateApp, forKey: .shouldTerminateApp)
        try container.encodeIfPresent(xcodeOrgId, forKey: .xcodeOrgId)
        try container.encodeIfPresent(xcodeSigningId, forKey: .xcodeSigningId)
    }
}
