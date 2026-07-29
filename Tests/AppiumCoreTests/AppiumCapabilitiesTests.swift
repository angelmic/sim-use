// SPDX-License-Identifier: Apache-2.0
import AppiumCore
import Foundation
import XCTest

/// `AppiumCapabilities` is the one place a session's W3C `alwaysMatch`
/// object is assembled, so its wire format is asserted directly here: the
/// `appium:` vendor prefixes, and — critically — that absent fields are
/// omitted rather than serialized as `null`. Three assemblies are pinned:
/// the tvOS Simulator caps TVOSBackend already ships (must stay identical),
/// and the two device assemblies P0-C proved (iOS 17+ real device, tvOS
/// classic) that T3 will wire up.
final class AppiumCapabilitiesTests: XCTestCase {
    func testTVOSSimulatorCapabilitiesMatchShippingWireFormat() throws {
        let json = try encodedJSON(AppiumCapabilities(
            platformName: "tvOS",
            automationName: "XCUITest",
            udid: "8737CB71-6462-41EC-B13E-E7C5E8F033E9",
            bundleId: "com.apple.TVSettings",
            autoLaunch: true,
            noReset: true,
            useNewWDA: false,
            newCommandTimeout: 300
        ))

        XCTAssertEqual(json["platformName"] as? String, "tvOS")
        XCTAssertEqual(json["appium:automationName"] as? String, "XCUITest")
        XCTAssertEqual(json["appium:udid"] as? String, "8737CB71-6462-41EC-B13E-E7C5E8F033E9")
        XCTAssertEqual(json["appium:bundleId"] as? String, "com.apple.TVSettings")
        XCTAssertEqual(json["appium:autoLaunch"] as? Bool, true)
        XCTAssertEqual(json["appium:noReset"] as? Bool, true)
        XCTAssertEqual(json["appium:useNewWDA"] as? Bool, false)
        XCTAssertEqual(json["appium:newCommandTimeout"] as? Int, 300)
        // Device-only caps must not leak into the Simulator assembly.
        for absent in [
            "appium:usePreinstalledWDA",
            "appium:updatedWDABundleId",
            "appium:wdaLocalPort",
            "appium:wdaRemotePort",
            "appium:webDriverAgentUrl",
        ] {
            XCTAssertNil(json[absent], "\(absent) must be omitted for tvOS Simulator caps")
        }
    }

    func testNilBundleIdIsOmittedNotNulled() throws {
        let json = try encodedJSON(AppiumCapabilities(
            platformName: "tvOS",
            automationName: "XCUITest",
            udid: "8737CB71-6462-41EC-B13E-E7C5E8F033E9",
            bundleId: nil,
            autoLaunch: false,
            noReset: true,
            useNewWDA: false,
            newCommandTimeout: 300
        ))

        XCTAssertFalse(json.keys.contains("appium:bundleId"), "a nil bundleId must not appear as null")
        XCTAssertEqual(json["appium:autoLaunch"] as? Bool, false)
    }

    func testIOSRealDeviceCapabilitiesUsePreinstalledWDA() throws {
        // P0-C C2: the caps that produced a live iOS 18.7 session.
        let json = try encodedJSON(AppiumCapabilities(
            platformName: "iOS",
            automationName: "XCUITest",
            udid: "00008110-001234567890001E",
            wdaLocalPort: 8110,
            wdaRemotePort: 8100,
            usePreinstalledWDA: true,
            updatedWDABundleId: "com.example.WebDriverAgentRunner"
        ))

        XCTAssertEqual(json["platformName"] as? String, "iOS")
        XCTAssertEqual(json["appium:automationName"] as? String, "XCUITest")
        XCTAssertEqual(json["appium:udid"] as? String, "00008110-001234567890001E")
        XCTAssertEqual(json["appium:wdaLocalPort"] as? Int, 8110)
        XCTAssertEqual(json["appium:wdaRemotePort"] as? Int, 8100)
        XCTAssertEqual(json["appium:usePreinstalledWDA"] as? Bool, true)
        XCTAssertEqual(json["appium:updatedWDABundleId"] as? String, "com.example.WebDriverAgentRunner")
        for absent in [
            "appium:noReset",
            "appium:useNewWDA",
            "appium:newCommandTimeout",
            "appium:autoLaunch",
            "appium:webDriverAgentUrl",
            "appium:bundleId",
        ] {
            XCTAssertNil(json[absent], "\(absent) must be omitted for the iOS real-device assembly")
        }
    }

    func testTVOSClassicDeviceCapabilitiesUseWebDriverAgentURL() throws {
        // P0-C C3: external WDA reached over iproxy, no xcodebuild.
        let json = try encodedJSON(AppiumCapabilities(
            platformName: "tvOS",
            automationName: "XCUITest",
            udid: "0123456789abcdef0123456789abcdef01234567",
            webDriverAgentUrl: "http://127.0.0.1:8104"
        ))

        XCTAssertEqual(json["platformName"] as? String, "tvOS")
        XCTAssertEqual(json["appium:udid"] as? String, "0123456789abcdef0123456789abcdef01234567")
        XCTAssertEqual(json["appium:webDriverAgentUrl"] as? String, "http://127.0.0.1:8104")
        for absent in [
            "appium:usePreinstalledWDA",
            "appium:updatedWDABundleId",
            "appium:wdaLocalPort",
            "appium:wdaRemotePort",
        ] {
            XCTAssertNil(json[absent], "\(absent) must be omitted for the tvOS classic assembly")
        }
    }

    private func encodedJSON(_ capabilities: AppiumCapabilities) throws -> [String: Any] {
        let data = try JSONEncoder().encode(capabilities)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }
}
