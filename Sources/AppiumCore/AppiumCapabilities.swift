// SPDX-License-Identifier: Apache-2.0
import Foundation

public struct AppiumCapabilities: Sendable, Encodable {
    public var platformName: String
    public var automationName: String?
    public var udid: String?
    public var bundleId: String?
    public var autoLaunch: Bool?
    public var noReset: Bool?
    public var useNewWDA: Bool?
    public var newCommandTimeout: Int?
    public var wdaLocalPort: Int?
    public var usePreinstalledWDA: Bool?
    public var updatedWDABundleId: String?
    public var webDriverAgentUrl: String?

    public init(
        platformName: String,
        automationName: String? = nil,
        udid: String? = nil,
        bundleId: String? = nil,
        autoLaunch: Bool? = nil,
        noReset: Bool? = nil,
        useNewWDA: Bool? = nil,
        newCommandTimeout: Int? = nil,
        wdaLocalPort: Int? = nil,
        usePreinstalledWDA: Bool? = nil,
        updatedWDABundleId: String? = nil,
        webDriverAgentUrl: String? = nil
    ) {
        self.platformName = platformName
        self.automationName = automationName
        self.udid = udid
        self.bundleId = bundleId
        self.autoLaunch = autoLaunch
        self.noReset = noReset
        self.useNewWDA = useNewWDA
        self.newCommandTimeout = newCommandTimeout
        self.wdaLocalPort = wdaLocalPort
        self.usePreinstalledWDA = usePreinstalledWDA
        self.updatedWDABundleId = updatedWDABundleId
        self.webDriverAgentUrl = webDriverAgentUrl
    }

    enum CodingKeys: String, CodingKey {
        case platformName
        case automationName = "appium:automationName"
        case udid = "appium:udid"
        case bundleId = "appium:bundleId"
        case autoLaunch = "appium:autoLaunch"
        case noReset = "appium:noReset"
        case useNewWDA = "appium:useNewWDA"
        case newCommandTimeout = "appium:newCommandTimeout"
        case wdaLocalPort = "appium:wdaLocalPort"
        case usePreinstalledWDA = "appium:usePreinstalledWDA"
        case updatedWDABundleId = "appium:updatedWDABundleId"
        case webDriverAgentUrl = "appium:webDriverAgentUrl"
    }

    /// Optional fields are emitted with `encodeIfPresent`, never as
    /// explicit `null`: an assembly sets only the caps its platform needs,
    /// and a `null` the shipping tvOS Simulator path never sent could
    /// change how the Appium server negotiates the session.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(platformName, forKey: .platformName)
        try container.encodeIfPresent(automationName, forKey: .automationName)
        try container.encodeIfPresent(udid, forKey: .udid)
        try container.encodeIfPresent(bundleId, forKey: .bundleId)
        try container.encodeIfPresent(autoLaunch, forKey: .autoLaunch)
        try container.encodeIfPresent(noReset, forKey: .noReset)
        try container.encodeIfPresent(useNewWDA, forKey: .useNewWDA)
        try container.encodeIfPresent(newCommandTimeout, forKey: .newCommandTimeout)
        try container.encodeIfPresent(wdaLocalPort, forKey: .wdaLocalPort)
        try container.encodeIfPresent(usePreinstalledWDA, forKey: .usePreinstalledWDA)
        try container.encodeIfPresent(updatedWDABundleId, forKey: .updatedWDABundleId)
        try container.encodeIfPresent(webDriverAgentUrl, forKey: .webDriverAgentUrl)
    }
}
