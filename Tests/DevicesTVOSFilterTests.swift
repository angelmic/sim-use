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
