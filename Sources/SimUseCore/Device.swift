// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Cross-platform identifier for one connected device sim-use can target —
/// an iOS/tvOS Simulator runtime from `simctl list devices`, an Android
/// device / emulator from `adb devices`, or a physical Apple device from
/// `devicectl` / `idevice_id` discovery. The platforms originally shipped
/// with separate listing commands (`list-simulators`, `android devices`) and
/// ad-hoc output shapes; `Device` is the unified row that the top-level
/// `sim-use devices` verb emits so external tooling (the Viewer, future
/// IDE integrations, agents) only needs one schema.
///
/// `platform` answers "which OS", `kind` answers "which carrier" —
/// deliberately orthogonal axes, because capabilities follow the kind
/// (an iOS *simulator* takes coordinate HID; an iOS *physical* device
/// takes WebDriverAgent sessions) while the verb vocabulary follows the
/// platform. `target` is the two-valued sim-vs-device view of `kind`,
/// kept on the wire for existing consumers.
///
/// `state` is intentionally a free-form string: iOS reports
/// `Booted` / `Shutdown` / `Shutting Down` / `Booting` / `Creating`, and
/// Android reports `device` / `offline` / `unauthorized`. Callers that
/// just want "can I act on this now?" should use `isUsable`, which
/// applies the per-platform rule.
public struct Device: Codable, Equatable, Hashable, Sendable {
    /// Custom keys for the device-id wire migration. `deviceId` is the
    /// canonical cross-platform key and the only one emitted; `udid`
    /// is the historic name, still accepted on decode as a deprecated
    /// fallback (to be removed in a future release).
    private enum CodingKeys: String, CodingKey {
        case udid
        case deviceId
        case name
        case platform
        case kind
        case state
        case runtime
        case target
    }

    public enum Platform: String, Codable, Sendable, CaseIterable {
        case ios
        case tvos
        case android
    }

    /// What carries the OS: a Simulator runtime, an Android emulator, or
    /// real hardware. Orthogonal to `platform`.
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case simulator
        case emulator
        case physical
    }

    /// Whether a row is a Simulator/emulator or a physical device — the
    /// two-valued view of `kind` (`.physical` → `.device`, everything
    /// else → `.sim`). Kept on the wire alongside `kind` so existing
    /// `--json` consumers keep working; the listers stamp `kind` and
    /// `target` is derived from it.
    public enum Target: String, Codable, Sendable {
        case sim
        case device
    }

    /// Platform-state strings as the underlying tools emit them.
    /// Extracted as named constants so a future renaming of an iOS
    /// state ("Booted" → something else in a future simctl) or an
    /// Android one is a single-source change instead of grepping
    /// for the literal across Device, SimctlDeviceLister, Devices,
    /// DeviceModelTests.
    public enum State {
        public static let iosBooted = "Booted"
        public static let iosShutdown = "Shutdown"
        public static let androidOnline = "device"
        public static let androidOffline = "offline"
        public static let androidUnauthorized = "unauthorized"
        /// Physical Apple device reachable either through CoreDevice
        /// (`connectionProperties.tunnelState` from `devicectl`) or through
        /// a live `idevice_id -l` USB attachment. The usable state for
        /// `target == .device`; "disconnected" and "unavailable" are the
        /// not-reachable-now counterparts.
        public static let deviceConnected = "connected"
    }

    public let udid: String
    public let name: String
    public let platform: Platform
    public let kind: Kind
    public let state: String
    /// Human-readable runtime label. Apple platforms: the simctl runtime
    /// (`iOS 18.6`, `tvOS 18.2`) or the physical device's OS (`iOS 26.6`);
    /// Android: `Android` (we don't fetch the OS version via adb to keep
    /// `devices` cheap). Nil when the platform genuinely has none to report.
    public let runtime: String?
    /// Simulator/emulator vs physical device — derived from `kind` so the
    /// two axes can never drift apart.
    public var target: Target { kind == .physical ? .device : .sim }

    public init(
        udid: String,
        name: String,
        platform: Platform,
        kind: Kind,
        state: String,
        runtime: String?
    ) {
        self.udid = udid
        self.name = name
        self.platform = platform
        self.kind = kind
        self.state = state
        self.runtime = runtime
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let deviceId = try c.decodeIfPresent(String.self, forKey: .deviceId)
        let udid = try c.decodeIfPresent(String.self, forKey: .udid)
        guard let resolved = deviceId ?? udid else {
            throw DecodingError.keyNotFound(
                CodingKeys.deviceId,
                .init(codingPath: decoder.codingPath, debugDescription: "Device payload missing both `deviceId` and `udid`.")
            )
        }
        self.udid = resolved
        self.name = try c.decode(String.self, forKey: .name)
        self.platform = try c.decode(Platform.self, forKey: .platform)
        self.state = try c.decode(String.self, forKey: .state)
        self.runtime = try c.decodeIfPresent(String.self, forKey: .runtime)
        // Payloads from before the `kind` field carry enough to infer it:
        // a `target` field (fork wire) maps directly, and failing both,
        // pre-kind iOS/tvOS listings only ever contained simulators while
        // the Android emulator serial prefix is the same signal `adb`
        // consumers have always used.
        if let kind = try c.decodeIfPresent(Kind.self, forKey: .kind) {
            self.kind = kind
        } else if let target = try c.decodeIfPresent(Target.self, forKey: .target) {
            switch target {
            case .device: kind = .physical
            case .sim:    kind = platform == .android ? .emulator : .simulator
            }
        } else {
            switch platform {
            case .ios, .tvos: kind = .simulator
            case .android:    kind = resolved.hasPrefix("emulator-") ? .emulator : .physical
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(udid, forKey: .deviceId)
        try c.encode(name, forKey: .name)
        try c.encode(platform, forKey: .platform)
        try c.encode(kind, forKey: .kind)
        try c.encode(state, forKey: .state)
        try c.encodeIfPresent(runtime, forKey: .runtime)
        try c.encode(target, forKey: .target)
    }

    /// Whether sim-use can talk to this device right now. iOS/tvOS: only
    /// `Booted` sims accept UI operations. Android: `device` is the online
    /// state; `offline` / `unauthorized` aren't reachable through the
    /// bridge.
    public var isUsable: Bool {
        switch platform {
        case .ios, .tvos:
            // A physical device is reachable when its merged effective state
            // is "connected"; a Simulator is reachable only when Booted.
            return target == .device ? state == State.deviceConnected : state == State.iosBooted
        case .android: return state == State.androidOnline
        }
    }
}
