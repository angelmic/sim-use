// SPDX-License-Identifier: Apache-2.0
import AppiumCore
import Foundation
import SimUseCore
import XCTest
@testable import DeviceBackend

/// The capability shape is a function of the resolved device facts. These
/// pin the exact `appium:` wire keys for each branch so a future edit can't
/// silently drop `usePreinstalledWDA` or send Simulator caps to a device.
final class DeviceCapabilitiesTests: XCTestCase {
    private let config = DeviceCapabilityConfig()

    private func info(family: Device.Platform, major: Int) -> PhysicalDeviceInfo {
        PhysicalDeviceInfo(udid: "UDID-1", family: family, osMajorVersion: major, tunnelState: "connected")
    }

    // MARK: - iOS modern (preinstalled WDA)

    func testIOSModernUsesPreinstalledWDA() throws {
        let caps = try DeviceCapabilityBuilder.capabilities(
            for: info(family: .ios, major: 18), bundleId: nil, config: config
        )
        let wire = try encoded(caps)
        XCTAssertEqual(wire["platformName"] as? String, "iOS")
        XCTAssertEqual(wire["appium:automationName"] as? String, "XCUITest")
        XCTAssertEqual(wire["appium:udid"] as? String, "UDID-1")
        XCTAssertEqual(wire["appium:usePreinstalledWDA"] as? Bool, true)
        XCTAssertEqual(wire["appium:updatedWDABundleId"] as? String, "com.catchplay.WebDriverAgentRunner")
        XCTAssertEqual(wire["appium:wdaLocalPort"] as? Int, 8100)
        XCTAssertEqual(wire["appium:newCommandTimeout"] as? Int, 120)
        // The device path must not leak the tvOS xcodebuild or classic keys.
        XCTAssertNil(wire["appium:xcodeOrgId"])
        XCTAssertNil(wire["appium:webDriverAgentUrl"])
    }

    // MARK: - tvOS 26 (xcodebuild flow)

    func testTVOSModernUsesXcodebuildFlow() throws {
        let caps = try DeviceCapabilityBuilder.capabilities(
            for: info(family: .tvos, major: 26), bundleId: "com.catchplay.tvos", config: config
        )
        let wire = try encoded(caps)
        XCTAssertEqual(wire["platformName"] as? String, "tvOS")
        XCTAssertEqual(wire["appium:xcodeOrgId"] as? String, "MKK9DM2XD9")
        XCTAssertEqual(wire["appium:xcodeSigningId"] as? String, "Apple Development")
        XCTAssertEqual(wire["appium:updatedWDABundleId"] as? String, "com.catchplay.wda")
        XCTAssertEqual(wire["appium:bundleId"] as? String, "com.catchplay.tvos")
        // wdaLocalPort applies to tvOS too, so a second task-owned server can
        // dodge a port another Appium already holds (P0-C2 recovery).
        XCTAssertEqual(wire["appium:wdaLocalPort"] as? Int, 8100)
        // No preinstalled path on tvOS: usePreinstalledWDA must be absent.
        XCTAssertNil(wire["appium:usePreinstalledWDA"])
        XCTAssertNil(wire["appium:webDriverAgentUrl"])
    }

    // MARK: - Classic ≤16.x (external WDA URL / fail-fast)

    func testClassicUsesExternalWDAURLWhenSet() throws {
        var cfg = config
        cfg.externalWDAURL = "http://127.0.0.1:8104"
        let caps = try DeviceCapabilityBuilder.capabilities(
            for: info(family: .tvos, major: 16), bundleId: nil, config: cfg
        )
        let wire = try encoded(caps)
        XCTAssertEqual(wire["appium:webDriverAgentUrl"] as? String, "http://127.0.0.1:8104")
        XCTAssertNil(wire["appium:usePreinstalledWDA"])
        XCTAssertNil(wire["appium:xcodeOrgId"])
    }

    func testClassicWithoutWDAURLFailsFastWithRecipe() {
        XCTAssertThrowsError(
            try DeviceCapabilityBuilder.capabilities(
                for: info(family: .tvos, major: 16), bundleId: nil, config: config
            )
        ) { error in
            guard case DevicePreflightError.classicWDAMissing(_, let bundleId) = error else {
                return XCTFail("expected .classicWDAMissing, got \(error)")
            }
            XCTAssertEqual(bundleId, "com.catchplay.wda")
            let hint = (error as? HintProviding)?.hint ?? ""
            XCTAssertTrue(hint.contains("idevicedebug"))
            XCTAssertTrue(hint.contains("iproxy 8104:8100"))
            XCTAssertTrue(hint.contains("SIM_USE_WDA_URL"))
        }
    }

    func testBlankBundleIdIsOmitted() throws {
        let caps = try DeviceCapabilityBuilder.capabilities(
            for: info(family: .ios, major: 18), bundleId: "   ", config: config
        )
        XCTAssertNil(try encoded(caps)["appium:bundleId"])
    }

    // MARK: - Config env parsing

    func testLiveConfigReadsEnvironmentOverrides() {
        let cfg = DeviceCapabilityConfig.live(environment: [
            "SIM_USE_WDA_BUNDLE_ID": "com.acme.WDA",
            "SIM_USE_WDA_LOCAL_PORT": "8199",
            "SIM_USE_TVOS_WDA_BUNDLE_ID": "com.acme.tvwda",
            "SIM_USE_XCODE_ORG_ID": "TEAM123456",
            "SIM_USE_XCODE_SIGNING_ID": "iPhone Developer",
            "SIM_USE_WDA_URL": "http://127.0.0.1:9",
        ])
        XCTAssertEqual(cfg.iosWDABundleId, "com.acme.WDA")
        XCTAssertEqual(cfg.wdaLocalPort, 8199)
        XCTAssertEqual(cfg.tvosWDABundleId, "com.acme.tvwda")
        XCTAssertEqual(cfg.xcodeOrgId, "TEAM123456")
        XCTAssertEqual(cfg.xcodeSigningId, "iPhone Developer")
        XCTAssertEqual(cfg.externalWDAURL, "http://127.0.0.1:9")
    }

    func testLiveConfigDefaultsWhenEnvironmentEmpty() {
        let cfg = DeviceCapabilityConfig.live(environment: [:])
        XCTAssertEqual(cfg.iosWDABundleId, "com.catchplay.WebDriverAgentRunner")
        XCTAssertEqual(cfg.tvosWDABundleId, "com.catchplay.wda")
        XCTAssertEqual(cfg.xcodeOrgId, "MKK9DM2XD9")
        XCTAssertNil(cfg.externalWDAURL)
    }

    private func encoded(_ caps: AppiumCapabilities) throws -> [String: Any] {
        let data = try JSONEncoder().encode(caps)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
