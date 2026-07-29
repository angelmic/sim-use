// SPDX-License-Identifier: Apache-2.0
@testable import SimUse
import SimUseCore
import Testing

@Suite("Devices tvOS filtering")
struct DevicesTVOSFilterTests {
    @Test("--platform tvos returns only tvOS Simulators")
    func tvOSOnly() {
        let result = Devices.filterDevices(
            appleDevices: [ios, tvos],
            androidDevices: [android],
            platform: .tvos,
            includeAll: true
        )

        #expect(result == [tvos])
    }

    @Test("--platform ios excludes tvOS Simulators")
    func iOSOnly() {
        let result = Devices.filterDevices(
            appleDevices: [ios, tvos],
            androidDevices: [android],
            platform: .ios,
            includeAll: true
        )

        #expect(result == [ios])
    }

    private let ios = Device(
        udid: "ios-1",
        name: "iPhone 17 Pro",
        platform: .ios,
        state: Device.State.iosBooted,
        runtime: "iOS 26.0"
    )
    private let tvos = Device(
        udid: "tvos-1",
        name: "Apple TV 4K",
        platform: .tvos,
        state: Device.State.iosBooted,
        runtime: "tvOS 18.2"
    )
    private let android = Device(
        udid: "emulator-5554",
        name: "Pixel",
        platform: .android,
        state: Device.State.androidOnline,
        runtime: "Android"
    )
}

/// `sim-use devices` must list physical devices alongside Simulators, keep
/// the sim-vs-device `target` intact through filtering, and (without --all)
/// hide devices that aren't reachable right now.
@Suite("Devices physical-device filtering")
struct DevicesPhysicalDeviceFilterTests {
    @Test("--platform ios includes a connected physical iPhone and its device target")
    func iosIncludesPhysical() {
        let result = Devices.filterDevices(
            appleDevices: [iosSim, connectedIPhone, connectedAppleTV],
            androidDevices: [],
            platform: .ios,
            includeAll: false
        )
        #expect(result.contains(connectedIPhone))
        #expect(!result.contains(connectedAppleTV))
        #expect(result.first { $0.udid == connectedIPhone.udid }?.target == .device)
    }

    @Test("--platform tvos includes a physical Apple TV plus the tvOS sim")
    func tvosIncludesPhysicalAndSim() {
        let result = Devices.filterDevices(
            appleDevices: [tvosSim, connectedIPhone, connectedAppleTV],
            androidDevices: [],
            platform: .tvos,
            includeAll: false
        )
        #expect(Set(result) == [tvosSim, connectedAppleTV])
    }

    @Test("default (no --all) hides a disconnected physical device")
    func defaultHidesDisconnected() {
        let result = Devices.filterDevices(
            appleDevices: [connectedIPhone, disconnectedIPhone],
            androidDevices: [],
            platform: .ios,
            includeAll: false
        )
        #expect(result == [connectedIPhone])
    }

    @Test("--all surfaces the disconnected physical device too")
    func allIncludesDisconnected() {
        let result = Devices.filterDevices(
            appleDevices: [connectedIPhone, disconnectedIPhone],
            androidDevices: [],
            platform: .ios,
            includeAll: true
        )
        #expect(Set(result) == [connectedIPhone, disconnectedIPhone])
    }

    private let iosSim = Device(udid: "ios-sim-1", name: "iPhone 17 Pro", platform: .ios,
                                state: Device.State.iosBooted, runtime: "iOS 26.0", target: .sim)
    private let tvosSim = Device(udid: "tvos-sim-1", name: "Apple TV 4K", platform: .tvos,
                                 state: Device.State.iosBooted, runtime: "tvOS 18.2", target: .sim)
    private let connectedIPhone = Device(udid: "00008110-001234567890001E", name: "Test iPhone", platform: .ios,
                                         state: Device.State.deviceConnected, runtime: "iOS 18.7.8", target: .device)
    private let disconnectedIPhone = Device(udid: "00008130-001111111111101C", name: "Offline iPhone", platform: .ios,
                                            state: "disconnected", runtime: "iOS 26.5.2", target: .device)
    private let connectedAppleTV = Device(udid: "0123456789abcdef0123456789abcdef01234567", name: "Test Apple TV", platform: .tvos,
                                          state: Device.State.deviceConnected, runtime: "tvOS 26.5", target: .device)
}
