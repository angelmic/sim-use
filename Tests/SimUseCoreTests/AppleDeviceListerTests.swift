// SPDX-License-Identifier: Apache-2.0
@testable import SimUseCore
import Foundation
import Testing

/// Parsing is fixture-driven with a shape-preserving synthetic
/// `devicectl list devices --json-output` document, so the test pins Xcode's
/// keys without committing host or device identity.
@Suite("AppleDeviceLister — devicectl JSON parsing")
struct AppleDeviceListerParseTests {
    private func fixture(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            "missing fixture \(name).json"
        )
        return try Data(contentsOf: url)
    }

    @Test("parses all five devices from the fixture")
    func parsesAllDevices() throws {
        let devices = try AppleDeviceLister.parseDevicectlJSON(fixture("devicectl-list-devices"))
        #expect(devices.count == 5)
        // Every physical device is tagged as a device, never a Simulator.
        #expect(devices.allSatisfy { $0.target == .device })
    }

    @Test("takes the hardware UDID, not the CoreDevice identifier")
    func usesHardwareUDID() throws {
        let devices = try AppleDeviceLister.parseDevicectlJSON(fixture("devicectl-list-devices"))
        let udids = Set(devices.map(\.udid))
        #expect(udids.contains("00008110-001234567890001E"))
        // The top-level `identifier` (CoreDevice UUID) must not leak through.
        #expect(!udids.contains("44444444-5555-6666-7777-888888888888"))
    }

    @Test("classifies the iPhone with iOS platform, runtime, and connected state")
    func classifiesIPhone() throws {
        let devices = try AppleDeviceLister.parseDevicectlJSON(fixture("devicectl-list-devices"))
        let cp = try #require(devices.first { $0.udid == "00008110-001234567890001E" })
        #expect(cp.name == "Test iPhone")
        #expect(cp.platform == .ios)
        #expect(cp.state == "connected")
        #expect(cp.runtime == "iOS 18.7.8")
        #expect(cp.target == .device)
        #expect(cp.isUsable)
    }

    @Test("classifies the Apple TV (classic 40-hex UDID) with tvOS platform")
    func classifiesAppleTV() throws {
        let devices = try AppleDeviceLister.parseDevicectlJSON(fixture("devicectl-list-devices"))
        let tv = try #require(devices.first { $0.udid == "0123456789abcdef0123456789abcdef01234567" })
        #expect(tv.name == "Test Apple TV")
        #expect(tv.platform == .tvos)
        #expect(tv.runtime == "tvOS 26.5")
        #expect(tv.isUsable)
    }

    @Test("disconnected / unavailable devices parse but are not usable")
    func unreachableDevicesNotUsable() throws {
        let devices = try AppleDeviceLister.parseDevicectlJSON(fixture("devicectl-list-devices"))
        let offlinePhone = try #require(devices.first { $0.name == "Offline iPhone" })
        #expect(offlinePhone.state == "disconnected")
        #expect(!offlinePhone.isUsable)
        let offlineTV = try #require(devices.first { $0.name == "Offline Apple TV" })
        #expect(offlineTV.platform == .tvos)
        #expect(offlineTV.state == "unavailable")
        #expect(!offlineTV.isUsable)
    }

    @Test("malformed JSON throws")
    func malformedThrows() {
        #expect(throws: (any Error).self) {
            _ = try AppleDeviceLister.parseDevicectlJSON(Data("not json".utf8))
        }
    }
}

@Suite("AppleDeviceLister — idevice_id merge / dedupe")
struct AppleDeviceListerMergeTests {
    private let devicectlRows = [
        Device(udid: "00008110-001234567890001E", name: "Test iPhone",
               platform: .ios, state: "connected", runtime: "iOS 18.7.8", target: .device),
    ]

    @Test("a UDID already known to devicectl is not duplicated")
    func dedupesOverlap() {
        let merged = AppleDeviceLister.mergeIdeviceIDUDIDs(
            into: devicectlRows,
            udids: ["00008110-001234567890001E"]
        )
        #expect(merged.count == 1)
        // The rich devicectl row wins over a bare idevice_id UDID.
        #expect(merged[0].name == "Test iPhone")
    }

    @Test("a live USB overlap promotes a stale devicectl row without losing metadata")
    func promotesReachableOverlap() throws {
        let staleRows = [
            Device(udid: "00008110-001234567890001E", name: "Test iPhone",
                   platform: .ios, state: "connecting", runtime: "iOS 18.7.8", target: .device),
            Device(udid: "OTHER", name: "Offline iPhone",
                   platform: .ios, state: "unavailable", runtime: "iOS 18.7", target: .device),
        ]

        let merged = AppleDeviceLister.mergeIdeviceIDUDIDs(
            into: staleRows,
            udids: ["  00008110-001234567890001E  ", ""]
        )

        #expect(merged.count == 2)
        let cp = try #require(merged.first { $0.udid == "00008110-001234567890001E" })
        #expect(cp.name == "Test iPhone")
        #expect(cp.platform == .ios)
        #expect(cp.runtime == "iOS 18.7.8")
        #expect(cp.state == Device.State.deviceConnected)
        #expect(cp.isUsable)
        let offline = try #require(merged.first { $0.udid == "OTHER" })
        #expect(offline.state == "unavailable")
        #expect(!offline.isUsable)
    }

    @Test("a UDID seen only via idevice_id is added as a minimal device row")
    func addsIdeviceOnly() {
        let merged = AppleDeviceLister.mergeIdeviceIDUDIDs(
            into: devicectlRows,
            udids: ["0123456789abcdef0123456789abcdef01234567"]
        )
        #expect(merged.count == 2)
        let extra = try? #require(merged.first { $0.udid == "0123456789abcdef0123456789abcdef01234567" })
        #expect(extra?.target == .device)
        // idevice_id can't report platform; the fallback row is usable
        // (idevice_id only lists reachable USB devices).
        #expect(extra?.isUsable == true)
    }
}

/// Live enumeration against whatever is plugged into this host. Skips when
/// nothing is connected so CI (and a laptop with no cable) stays green.
@Suite("AppleDeviceLister — live enumeration")
struct AppleDeviceListerLiveTests {
    @Test("a live details probe promotes a stale paired Apple TV")
    func detailsProbePromotesAppleTV() throws {
        let officeTV = Device(
            udid: "0123456789abcdef0123456789abcdef01234567",
            name: "Test Apple TV",
            platform: .tvos,
            state: "disconnected",
            runtime: "tvOS 26.5",
            target: .device
        )
        let unavailableTV = Device(
            udid: "00008110-003333333333401E",
            name: "Offline Apple TV",
            platform: .tvos,
            state: "unavailable",
            runtime: "tvOS 26.5",
            target: .device
        )
        var probed: [String] = []

        let devices = AppleDeviceLister.promoteLiveDisconnectedAppleTVs(
            in: [officeTV, unavailableTV],
            devicectlDetailsProvider: { udid in
                probed.append(udid)
                return udid == "0123456789abcdef0123456789abcdef01234567"
                    ? Device.State.deviceConnected
                    : nil
            }
        )

        let tv = try #require(devices.first { $0.name == "Test Apple TV" })
        #expect(tv.state == Device.State.deviceConnected)
        #expect(tv.isUsable)
        #expect(probed == ["0123456789abcdef0123456789abcdef01234567"])
        let stillUnavailable = try #require(devices.first { $0.name == "Offline Apple TV" })
        #expect(stillUnavailable.state == "unavailable")
    }

    @Test("listPhysicalDevices returns device-target rows or an empty list")
    func liveList() throws {
        let devices = AppleDeviceLister.listPhysicalDevices()
        try withKnownIssue("no physical Apple device attached", isIntermittent: true) {
            try #require(!devices.isEmpty)
        }
        // Whatever came back must be tagged as physical devices.
        #expect(devices.allSatisfy { $0.target == .device })
    }
}
