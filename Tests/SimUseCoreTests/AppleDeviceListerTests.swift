// SPDX-License-Identifier: Apache-2.0
@testable import SimUseCore
import Foundation
import Testing

/// Parsing is fixture-driven (a real `devicectl list devices --json-output`
/// capture), so the test pins the exact shape Xcode emits without needing a
/// device attached. The live enumeration is exercised by the integration
/// test below, which skips when no device / tool is present.
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
        #expect(udids.contains("00008140-00096D5C0CEA801C"))
        // The top-level `identifier` (CoreDevice UUID) must not leak through.
        #expect(!udids.contains("B98CC0CB-CF18-5867-9595-869A35AFE502"))
    }

    @Test("classifies the iPhone with iOS platform, runtime, and connected state")
    func classifiesIPhone() throws {
        let devices = try AppleDeviceLister.parseDevicectlJSON(fixture("devicectl-list-devices"))
        let cp = try #require(devices.first { $0.udid == "00008140-00096D5C0CEA801C" })
        #expect(cp.name == "CP 16 Pro Max")
        #expect(cp.platform == .ios)
        #expect(cp.state == "connected")
        #expect(cp.runtime == "iOS 18.7.8")
        #expect(cp.target == .device)
        #expect(cp.isUsable)
    }

    @Test("classifies the Apple TV (classic 40-hex UDID) with tvOS platform")
    func classifiesAppleTV() throws {
        let devices = try AppleDeviceLister.parseDevicectlJSON(fixture("devicectl-list-devices"))
        let tv = try #require(devices.first { $0.udid == "c311e5afe90ee702b80e8b64e1e12796e04e63a0" })
        #expect(tv.name == "辦公桌tv理查")
        #expect(tv.platform == .tvos)
        #expect(tv.runtime == "tvOS 26.5")
        #expect(tv.isUsable)
    }

    @Test("disconnected / unavailable devices parse but are not usable")
    func unreachableDevicesNotUsable() throws {
        let devices = try AppleDeviceLister.parseDevicectlJSON(fixture("devicectl-list-devices"))
        let richard = try #require(devices.first { $0.name == "Richard iPhone" })
        #expect(richard.state == "disconnected")
        #expect(!richard.isUsable)
        let study = try #require(devices.first { $0.name == "書房" })
        #expect(study.platform == .tvos)
        #expect(study.state == "unavailable")
        #expect(!study.isUsable)
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
        Device(udid: "00008140-00096D5C0CEA801C", name: "CP 16 Pro Max",
               platform: .ios, state: "connected", runtime: "iOS 18.7.8", target: .device),
    ]

    @Test("a UDID already known to devicectl is not duplicated")
    func dedupesOverlap() {
        let merged = AppleDeviceLister.mergeIdeviceIDUDIDs(
            into: devicectlRows,
            udids: ["00008140-00096D5C0CEA801C"]
        )
        #expect(merged.count == 1)
        // The rich devicectl row wins over a bare idevice_id UDID.
        #expect(merged[0].name == "CP 16 Pro Max")
    }

    @Test("a UDID seen only via idevice_id is added as a minimal device row")
    func addsIdeviceOnly() {
        let merged = AppleDeviceLister.mergeIdeviceIDUDIDs(
            into: devicectlRows,
            udids: ["c311e5afe90ee702b80e8b64e1e12796e04e63a0"]
        )
        #expect(merged.count == 2)
        let extra = try? #require(merged.first { $0.udid == "c311e5afe90ee702b80e8b64e1e12796e04e63a0" })
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
