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
