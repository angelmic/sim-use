// SPDX-License-Identifier: Apache-2.0
@testable import SimUseCore
import Testing

/// The FBSimulator daemon drives only iOS Simulators. Physical Apple
/// devices (Appium/WDA) must bypass it — routing one through the daemon
/// spawns a per-UDID daemon that can't attach, which hangs instead of
/// failing fast. (The tvOS-Simulator true case is exercised through
/// `resolve` in the routing suite; these cases avoid the simctl lookup a
/// Simulator UUID would trigger.)
@Suite("PlatformRouter — daemon bypass")
struct PlatformRouterDaemonBypassTests {
    private let dashDevice = "00008140-00096D5C0CEA801C"
    private let classicDevice = "c311e5afe90ee702b80e8b64e1e12796e04e63a0"
    private let androidSerial = "R58N30ABCDE"

    @Test("physical Apple devices bypass the simulator daemon")
    func physicalDevicesBypass() {
        #expect(PlatformRouter.bypassesSimulatorDaemon(udid: dashDevice))
        #expect(PlatformRouter.bypassesSimulatorDaemon(udid: classicDevice))
    }

    @Test("Android and unrecognised UDIDs do not bypass")
    func othersDoNotBypass() {
        #expect(!PlatformRouter.bypassesSimulatorDaemon(udid: androidSerial))
        #expect(!PlatformRouter.bypassesSimulatorDaemon(udid: "abc"))
    }
}
