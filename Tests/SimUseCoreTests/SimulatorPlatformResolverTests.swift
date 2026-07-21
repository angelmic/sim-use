// SPDX-License-Identifier: Apache-2.0
@testable import SimUseCore
import XCTest

final class SimulatorPlatformResolverTests: XCTestCase {
    private let iosUDID = "AC274B6B-9C2B-41B1-B82C-5A1D223F4D4E"
    private let tvosUDID = "8737CB71-6462-41EC-B13E-E7C5E8F033E9"

    func testParsesIOSAndTVOSRuntimeFamilies() throws {
        let platforms = try SimulatorPlatformResolver.parse(fixture)

        XCTAssertEqual(platforms[iosUDID], .iOSSim)
        XCTAssertEqual(platforms[tvosUDID], .tvOSSim)
    }

    func testIgnoresUnsupportedAppleSimulatorFamilies() throws {
        let platforms = try SimulatorPlatformResolver.parse(fixture)

        XCTAssertNil(platforms["WATCH-UDID"])
    }

    func testPlatformRouterUsesRuntimeLookupForAppleUUID() {
        let resolved = PlatformRouter.resolve(udid: tvosUDID) { udid in
            udid == self.tvosUDID ? .tvOSSim : nil
        }

        XCTAssertEqual(resolved, .tvOSSim)
    }

    func testPlatformRouterKeepsIOSFallbackWhenRuntimeLookupMisses() {
        XCTAssertEqual(PlatformRouter.resolve(udid: iosUDID) { _ in nil }, .iOSSim)
    }

    func testAndroidRoutingDoesNotConsultSimulatorLookup() {
        var lookupCalled = false
        let resolved = PlatformRouter.resolve(udid: "emulator-5554") { _ in
            lookupCalled = true
            return .tvOSSim
        }

        XCTAssertEqual(resolved, .android)
        XCTAssertFalse(lookupCalled)
    }

    func testMalformedCatalogThrows() {
        XCTAssertThrowsError(try SimulatorPlatformResolver.parse(Data("not-json".utf8)))
    }

    // MARK: - device.plist fast path

    func testDevicePlistResolvesRuntimeFamilies() throws {
        let deviceSet = try makeDeviceSet([
            (udid: tvosUDID, runtime: "com.apple.CoreSimulator.SimRuntime.tvOS-18-2", isDeleted: false),
            (udid: iosUDID, runtime: "com.apple.CoreSimulator.SimRuntime.iOS-18-6", isDeleted: false),
        ])

        XCTAssertEqual(
            SimulatorPlatformResolver.devicePlistPlatform(for: tvosUDID, deviceSetURL: deviceSet),
            .tvOSSim
        )
        XCTAssertEqual(
            SimulatorPlatformResolver.devicePlistPlatform(for: iosUDID, deviceSetURL: deviceSet),
            .iOSSim
        )
    }

    func testDevicePlistLookupUppercasesTheUDID() throws {
        // simctl prints uppercase UUIDs and CoreSimulator names the device
        // directories the same way, but users paste lowercase too.
        let deviceSet = try makeDeviceSet([
            (udid: tvosUDID, runtime: "com.apple.CoreSimulator.SimRuntime.tvOS-18-2", isDeleted: false),
        ])

        XCTAssertEqual(
            SimulatorPlatformResolver.devicePlistPlatform(
                for: tvosUDID.lowercased(),
                deviceSetURL: deviceSet
            ),
            .tvOSSim
        )
    }

    func testDevicePlistIgnoresDeletedAndUnsupportedDevices() throws {
        let watchUDID = "3D1C0F8A-92E4-4C5B-8A6F-DD1B2C3E4F5A"
        let deviceSet = try makeDeviceSet([
            (udid: tvosUDID, runtime: "com.apple.CoreSimulator.SimRuntime.tvOS-18-2", isDeleted: true),
            (udid: watchUDID, runtime: "com.apple.CoreSimulator.SimRuntime.watchOS-11-5", isDeleted: false),
        ])

        XCTAssertNil(SimulatorPlatformResolver.devicePlistPlatform(for: tvosUDID, deviceSetURL: deviceSet))
        XCTAssertNil(SimulatorPlatformResolver.devicePlistPlatform(for: watchUDID, deviceSetURL: deviceSet))
    }

    func testDevicePlistMissingDeviceReturnsNil() throws {
        let deviceSet = try makeDeviceSet([])

        XCTAssertNil(SimulatorPlatformResolver.devicePlistPlatform(for: iosUDID, deviceSetURL: deviceSet))
    }

    private func makeDeviceSet(
        _ devices: [(udid: String, runtime: String, isDeleted: Bool)]
    ) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sim-use-device-set-\(UUID().uuidString)")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        for device in devices {
            let deviceDir = root.appendingPathComponent(device.udid)
            try FileManager.default.createDirectory(at: deviceDir, withIntermediateDirectories: true)
            let plist: [String: Any] = [
                "UDID": device.udid,
                "runtime": device.runtime,
                "isDeleted": device.isDeleted,
                "name": "Fixture Device",
            ]
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist,
                format: .xml,
                options: 0
            )
            try data.write(to: deviceDir.appendingPathComponent("device.plist"))
        }
        return root
    }

    private var fixture: Data {
        Data(#"""
        {
          "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-18-6": [
              {"udid": "AC274B6B-9C2B-41B1-B82C-5A1D223F4D4E", "name": "iPhone"}
            ],
            "com.apple.CoreSimulator.SimRuntime.tvOS-18-2": [
              {"udid": "8737CB71-6462-41EC-B13E-E7C5E8F033E9", "name": "Apple TV"}
            ],
            "com.apple.CoreSimulator.SimRuntime.watchOS-11-5": [
              {"udid": "WATCH-UDID", "name": "Apple Watch"}
            ]
          }
        }
        """#.utf8)
    }
}
