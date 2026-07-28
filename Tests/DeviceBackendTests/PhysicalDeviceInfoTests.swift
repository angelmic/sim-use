// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore
import XCTest
@testable import DeviceBackend

final class PhysicalDeviceInfoTests: XCTestCase {
    func testMajorVersionParsesRuntimeLabels() {
        XCTAssertEqual(PhysicalDeviceInfo.majorVersion(fromRuntime: "iOS 18.7.8"), 18)
        XCTAssertEqual(PhysicalDeviceInfo.majorVersion(fromRuntime: "tvOS 26.5"), 26)
        XCTAssertEqual(PhysicalDeviceInfo.majorVersion(fromRuntime: "tvOS 16.6"), 16)
        XCTAssertNil(PhysicalDeviceInfo.majorVersion(fromRuntime: nil))
        XCTAssertNil(PhysicalDeviceInfo.majorVersion(fromRuntime: "iOS"))
    }

    func testFullVersionParsesRuntimeLabels() {
        XCTAssertEqual(PhysicalDeviceInfo.version(fromRuntime: "iOS 18.7.8"), "18.7.8")
        XCTAssertEqual(PhysicalDeviceInfo.version(fromRuntime: "tvOS 26.5"), "26.5")
        XCTAssertEqual(PhysicalDeviceInfo.version(fromRuntime: "tvOS 26.5 beta"), "26.5")
        XCTAssertNil(PhysicalDeviceInfo.version(fromRuntime: nil))
        XCTAssertNil(PhysicalDeviceInfo.version(fromRuntime: "tvOS"))
    }

    func testModernGateKeysOnSeventeen() {
        XCTAssertFalse(info(major: 16).isModern)
        XCTAssertTrue(info(major: 17).isModern)
        XCTAssertTrue(info(major: 26).isModern)
        // A nil runtime only comes from the idevice_id fallback, always a
        // modern iOS device — treat it as modern rather than classic.
        XCTAssertTrue(info(major: nil).isModern)
    }

    func testInitFromDeviceRejectsSimulatorAndAndroid() {
        let sim = Device(udid: "u", name: "n", platform: .ios, state: "Booted", runtime: "iOS 18.4", target: .sim)
        let android = Device(udid: "emulator-5554", name: "n", platform: .android, state: "device", runtime: nil, target: .sim)
        XCTAssertNil(PhysicalDeviceInfo(device: sim))
        XCTAssertNil(PhysicalDeviceInfo(device: android))
    }

    func testInitFromDeviceCarriesFamilyAndTunnelState() throws {
        let tv = Device(udid: "c311", name: "TV", platform: .tvos, state: "connected", runtime: "tvOS 26.5", target: .device)
        let info = try XCTUnwrap(PhysicalDeviceInfo(device: tv))
        XCTAssertEqual(info.family, .tvos)
        XCTAssertEqual(info.osMajorVersion, 26)
        XCTAssertEqual(info.osVersion, "26.5")
        XCTAssertTrue(info.isConnected)
    }

    private func info(major: Int?) -> PhysicalDeviceInfo {
        PhysicalDeviceInfo(udid: "u", family: .ios, osMajorVersion: major, tunnelState: "connected")
    }
}
