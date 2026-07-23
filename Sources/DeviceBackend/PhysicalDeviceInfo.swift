// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore

/// The facts about one connected physical Apple device that the device
/// backend needs before it opens an Appium session: which family it is
/// (iOS vs tvOS decides the capability shape and the verb matrix), which
/// OS major version it runs (the modern ≥17 WebDriverAgent path vs the
/// classic ≤16 one), and whether the CoreDevice tunnel is up right now.
///
/// Resolved from the same `devicectl` enumeration the `sim-use devices`
/// verb uses (`AppleDeviceLister`), so a device that lists there resolves
/// here with identical family/version/reachability facts.
public struct PhysicalDeviceInfo: Sendable, Equatable {
    public let udid: String
    public let family: Device.Platform
    /// Major OS version (18 for "iOS 18.7.8", 26 for "tvOS 26.5"). `nil`
    /// when the lister could not report a runtime — only happens on the
    /// bare `idevice_id` fallback row, which is always iOS and always a
    /// modern device, so the ≥17 gate treats a nil major as modern.
    public let osMajorVersion: Int?
    /// `connectionProperties.tunnelState` verbatim ("connected" when the
    /// device is reachable; "disconnected" / "unavailable" otherwise).
    public let tunnelState: String

    public init(udid: String, family: Device.Platform, osMajorVersion: Int?, tunnelState: String) {
        self.udid = udid
        self.family = family
        self.osMajorVersion = osMajorVersion
        self.tunnelState = tunnelState
    }

    /// The CoreDevice tunnel is up — a session can be created. Keys off the
    /// same "connected" literal `Device.isUsable` uses for physical devices.
    public var isConnected: Bool { tunnelState == Device.State.deviceConnected }

    /// The device runs iOS/tvOS 17 or newer, i.e. the WebDriverAgent
    /// `usePreinstalledWDA` / xcodebuild-flow path rather than the classic
    /// external-`webDriverAgentUrl` one. A nil major (idevice_id fallback,
    /// always iOS) counts as modern.
    public var isModern: Bool {
        guard let osMajorVersion else { return true }
        return osMajorVersion >= 17
    }

    /// Build a `PhysicalDeviceInfo` from a `Device` row emitted by
    /// `AppleDeviceLister`. Returns nil for a Simulator/emulator or an
    /// Android row — only physical Apple devices reach the device backend.
    public init?(device: Device) {
        guard device.target == .device,
              device.platform == .ios || device.platform == .tvos
        else { return nil }
        self.init(
            udid: device.udid,
            family: device.platform,
            osMajorVersion: Self.majorVersion(fromRuntime: device.runtime),
            tunnelState: device.state
        )
    }

    /// Pull the major version out of a runtime label such as "iOS 18.7.8"
    /// or "tvOS 26.5" — the first integer run after the family word.
    /// Robust to a missing/odd label (returns nil rather than guessing).
    static func majorVersion(fromRuntime runtime: String?) -> Int? {
        guard let runtime else { return nil }
        // Scan for the first maximal digit run and read it as the major.
        var digits = ""
        for ch in runtime {
            if ch.isNumber {
                digits.append(ch)
            } else if !digits.isEmpty {
                break
            }
        }
        return Int(digits)
    }
}

/// Resolves a UDID to its `PhysicalDeviceInfo` by scanning the connected
/// physical-device list. The list provider is injectable so the backend's
/// preflight and family routing are unit-testable without a cabled device;
/// production reads it from `AppleDeviceLister`.
public struct DeviceInfoResolver: Sendable {
    public typealias Provider = @Sendable () -> [Device]

    private let provider: Provider

    public init(provider: @escaping Provider = { AppleDeviceLister.listPhysicalDevices() }) {
        self.provider = provider
    }

    /// The matching device's info, or nil when no connected physical Apple
    /// device carries this UDID (not cabled, not trusted, or a typo).
    public func resolve(udid: String) -> PhysicalDeviceInfo? {
        let trimmed = udid.trimmingCharacters(in: .whitespacesAndNewlines)
        return provider()
            .lazy
            .filter { $0.udid == trimmed }
            .compactMap(PhysicalDeviceInfo.init(device:))
            .first
    }
}
