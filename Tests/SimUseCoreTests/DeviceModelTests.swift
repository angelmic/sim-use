// SPDX-License-Identifier: Apache-2.0
@testable import SimUseCore
import XCTest

/// Guards the `Device` model contract: `isUsable` must match each
/// platform's "right now reachable" semantic, and Codable shape stays
/// the wire format the Viewer + scripts consume.
final class DeviceModelTests: XCTestCase {

    // MARK: - isUsable

    func testIOSBootedIsUsable() {
        let d = Device(udid: "X", name: "iPhone", platform: .ios, state: "Booted", runtime: "iOS 18.6")
        XCTAssertTrue(d.isUsable)
    }

    func testIOSShutdownIsNotUsable() {
        let d = Device(udid: "X", name: "iPhone", platform: .ios, state: "Shutdown", runtime: "iOS 18.6")
        XCTAssertFalse(d.isUsable)
    }

    func testTVOSBootedIsUsable() {
        let d = Device(udid: "X", name: "Apple TV", platform: .tvos, state: "Booted", runtime: "tvOS 18.2")
        XCTAssertTrue(d.isUsable)
    }

    func testTVOSShutdownIsNotUsable() {
        let d = Device(udid: "X", name: "Apple TV", platform: .tvos, state: "Shutdown", runtime: "tvOS 18.2")
        XCTAssertFalse(d.isUsable)
    }

    func testIOSTransitionalStatesAreNotUsable() {
        // sim-use can't drive HID against a half-booted sim, so be strict.
        for state in ["Booting", "Shutting Down", "Creating"] {
            let d = Device(udid: "X", name: "iPhone", platform: .ios, state: state, runtime: "iOS 18.6")
            XCTAssertFalse(d.isUsable, "iOS state \(state) should not be usable")
        }
    }

    func testAndroidDeviceStateIsUsable() {
        let d = Device(udid: "emulator-5554", name: "Pixel", platform: .android, state: "device", runtime: "Android")
        XCTAssertTrue(d.isUsable)
    }

    func testAndroidOfflineAndUnauthorisedAreNotUsable() {
        for state in ["offline", "unauthorized", "no device"] {
            let d = Device(udid: "emulator-5554", name: "Pixel", platform: .android, state: state, runtime: "Android")
            XCTAssertFalse(d.isUsable, "Android state '\(state)' should not be usable")
        }
    }

    // MARK: - JSON encoding (wire format)

    func testJSONShapeMatchesWireExpectation() throws {
        let d = Device(udid: "u", name: "n", platform: .ios, state: "Booted", runtime: "iOS 18.6")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = String(data: try encoder.encode(d), encoding: .utf8)
        // Field order is sorted (sortedKeys); platform is the rawValue
        // string, not an integer. `deviceId` is the canonical wire key;
        // the legacy `udid` key was dual-emitted during the deprecation
        // window and is no longer written as of Phase 2. Decoding still
        // accepts `udid`-only payloads (see testJSONAcceptsUDIDOnly).
        // `target` (sim|device) is always emitted so consumers can tell a
        // bootable Simulator from a connected physical device.
        XCTAssertEqual(json, #"{"deviceId":"u","name":"n","platform":"ios","runtime":"iOS 18.6","state":"Booted","target":"sim"}"#)
        XCTAssertFalse(json?.contains(#""udid""#) ?? true,
                       "legacy `udid` key must not be emitted, got: \(json ?? "nil")")
    }

    func testJSONAcceptsDeviceIdOnly() throws {
        // Legacy consumers shipped only `udid`. Verify the new decode
        // path accepts payloads that have only `deviceId` (the Phase 2
        // shape) so the wire migration can complete without breaking
        // the in-tree decoder.
        let payload = #"{"deviceId":"abc","name":"x","platform":"ios","state":"Booted"}"#
        let d = try JSONDecoder().decode(Device.self, from: Data(payload.utf8))
        XCTAssertEqual(d.udid, "abc")
    }

    func testTVOSJSONUsesDistinctPlatformDiscriminator() throws {
        let d = Device(udid: "tv", name: "Apple TV", platform: .tvos, state: "Booted", runtime: "tvOS 18.2")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(data: try encoder.encode(d), encoding: .utf8)
        XCTAssertEqual(json, #"{"deviceId":"tv","name":"Apple TV","platform":"tvos","runtime":"tvOS 18.2","state":"Booted","target":"sim"}"#)
    }

    func testJSONAcceptsUDIDOnly() throws {
        // Pre-dual-key payloads with only `udid` must still decode.
        let payload = #"{"udid":"abc","name":"x","platform":"ios","state":"Booted"}"#
        let d = try JSONDecoder().decode(Device.self, from: Data(payload.utf8))
        XCTAssertEqual(d.udid, "abc")
    }

    func testJSONRejectsPayloadMissingBothKeys() throws {
        let payload = #"{"name":"x","platform":"ios","state":"Booted"}"#
        XCTAssertThrowsError(try JSONDecoder().decode(Device.self, from: Data(payload.utf8)))
    }

    func testJSONRoundTrip() throws {
        let original = Device(udid: "emulator-5554", name: "Pixel", platform: .android, state: "device", runtime: "Android")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Device.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testNilRuntimeIsOmittedFromJSON() throws {
        // Per Swift's default JSONEncoder behaviour, nil optional fields
        // are omitted entirely (not encoded as JSON null). Consumers
        // (the Viewer server, jq scripts) must treat a missing `runtime`
        // and an explicit null identically — both mean "platform has no
        // runtime to report".
        let d = Device(udid: "u", name: "n", platform: .android, state: "device", runtime: nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(data: try encoder.encode(d), encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("runtime"),
                       "runtime: nil should be omitted from JSON, got: \(json)")
        // Round-trips back to nil regardless.
        let decoded = try JSONDecoder().decode(Device.self, from: Data(json.utf8))
        XCTAssertNil(decoded.runtime)
    }

    // MARK: - target (sim vs physical device)

    func testTargetDefaultsToSim() {
        // Existing construction sites (SimctlDeviceLister, test fixtures)
        // that don't pass `target` keep the historic Simulator meaning.
        let d = Device(udid: "u", name: "n", platform: .ios, state: "Booted", runtime: "iOS 18.6")
        XCTAssertEqual(d.target, .sim)
    }

    func testConnectedPhysicalDeviceIsUsable() {
        // A physical device is never "Booted"; usability keys off the
        // devicectl tunnel state instead.
        let iphone = Device(udid: "00008110-001234567890001E", name: "Test iPhone",
                            platform: .ios, state: Device.State.deviceConnected, runtime: "iOS 18.7.8", target: .device)
        XCTAssertTrue(iphone.isUsable)
        let appleTV = Device(udid: "0123456789abcdef0123456789abcdef01234567", name: "Test Apple TV",
                             platform: .tvos, state: Device.State.deviceConnected, runtime: "tvOS 26.5", target: .device)
        XCTAssertTrue(appleTV.isUsable)
    }

    func testDisconnectedPhysicalDeviceIsNotUsable() {
        for state in ["disconnected", "unavailable"] {
            let d = Device(udid: "X", name: "iPhone", platform: .ios, state: state, runtime: "iOS 18.7", target: .device)
            XCTAssertFalse(d.isUsable, "device tunnelState '\(state)' should not be usable")
        }
    }

    func testSimulatorUsabilityRuleUnchangedByTarget() {
        // The device-target rule must not leak into the Simulator path:
        // a .sim iOS device is usable only when Booted, not "connected".
        let bootedSim = Device(udid: "S", name: "iPhone", platform: .ios, state: "Booted", runtime: "iOS 18.6", target: .sim)
        XCTAssertTrue(bootedSim.isUsable)
        let connectedSim = Device(udid: "S", name: "iPhone", platform: .ios, state: "connected", runtime: "iOS 18.6", target: .sim)
        XCTAssertFalse(connectedSim.isUsable)
    }

    func testJSONIncludesTargetField() throws {
        let d = Device(udid: "u", name: "n", platform: .ios, state: "connected", runtime: "iOS 18.7", target: .device)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(data: try encoder.encode(d), encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains(#""target":"device""#), "target must be emitted, got: \(json)")
    }

    func testJSONDecodeDefaultsMissingTargetToSim() throws {
        // Legacy payloads predating the target field decode as Simulators.
        let payload = #"{"deviceId":"abc","name":"x","platform":"ios","state":"Booted"}"#
        let d = try JSONDecoder().decode(Device.self, from: Data(payload.utf8))
        XCTAssertEqual(d.target, .sim)
    }

    func testTargetRoundTrips() throws {
        let original = Device(udid: "u", name: "n", platform: .tvos, state: "connected", runtime: "tvOS 26.5", target: .device)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Device.self, from: data)
        XCTAssertEqual(original, decoded)
        XCTAssertEqual(decoded.target, .device)
    }
}
