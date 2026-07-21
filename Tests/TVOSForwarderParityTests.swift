// SPDX-License-Identifier: Apache-2.0
@testable import SimUse
import SimUseCore
import Testing

@Suite("tvOS top-level forwarding parity")
struct TVOSForwarderParityTests {
    private let tvosUDID = "8737CB71-6462-41EC-B13E-E7C5E8F033E9"

    @Test("describe-ui selects the tvOS backend for a tvOS Simulator")
    func describeUISelectsTVOSBackend() {
        let backend = DescribeUI.executionBackend(for: .tvOSSim)

        #expect(backend == .tvOSSimulator)
    }

    @Test("describe-ui forwards the cold-start target bundle")
    func describeUIForwardsTargetBundle() throws {
        let sut = try DescribeUI.parse([
            "--device", tvosUDID,
            "--bundle-id", "com.example.TVApp",
        ])

        let forwarded = sut.makeTVOSSubcommand()

        #expect(forwarded.target.bundleId == "com.example.TVApp")
    }

    @Test("screenshot selects the tvOS backend for a tvOS Simulator")
    func screenshotSelectsTVOSBackend() {
        let backend = Screenshot.executionBackend(for: .tvOSSim)

        #expect(backend == .tvOSSimulator)
    }

    @Test("screenshot forwards the cold-start target bundle")
    func screenshotForwardsTargetBundle() throws {
        let sut = try Screenshot.parse([
            "--device", tvosUDID,
            "--bundle-id", "com.example.TVApp",
        ])

        let forwarded = sut.makeTVOSSubcommand()

        #expect(forwarded.target.bundleId == "com.example.TVApp")
    }
}
