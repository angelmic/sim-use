// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Fail-fast rejection when a verb is routed to a physical Apple device that
/// the device backend does not implement yet. `PlatformRouter.resolve`
/// recognises the device (so it is *not* misrouted to Android/adb — P0
/// breakpoint #2), but the verb machinery for physical devices lands in the
/// DeviceBackend (xd 2.0 Phase 1 T3). Until then this surfaces a clear
/// "not yet supported" message instead of an opaque adb or Simulator error.
public struct DeviceBackendUnsupportedError: Error, LocalizedError, HintProviding, Equatable {
    public let command: String
    public let deviceId: String?

    public init(command: String, deviceId: String? = nil) {
        self.command = command
        self.deviceId = deviceId
    }

    public var errorDescription: String? {
        let target = deviceId.map { " (\($0))" } ?? ""
        return "`\(command)` is not yet supported on physical Apple devices\(target). "
            + "Physical-device support is landing in the device backend (xd 2.0 Phase 1, T3)."
    }

    public var hint: String? {
        "Today only the iOS/tvOS Simulator and Android backends implement this verb. "
            + "Run it against a booted Simulator (see `sim-use devices`), or track the device backend work in T3."
    }
}
