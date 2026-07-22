// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Executable-wired fast path into the simulator HID stack for the tvOS
/// backend.
///
/// tvOS Simulators accept HID keyboard events on the same Indigo channel
/// iOS ones do, and map them onto Siri Remote semantics (arrows move
/// focus, Return selects, Escape is Menu) — measured at ~0.3 s per press
/// against ~2.5 s for an Appium session. `TVOSBackend` deliberately does
/// not link the FB frameworks that own that channel, so the SimUse
/// executable installs this hook at startup (the same pattern as
/// `DaemonDispatch.livenessProbe`). When unset — unit tests, hosts
/// without the iOS backend — the tvOS backend falls back to its Appium
/// paths.
public enum TVOSHIDBridge {
    /// Press one HID keyboard key (keyboard usage-page keycode) on the
    /// simulator with the given UDID.
    nonisolated(unsafe) public static var pressKey: (@Sendable (_ keycode: UInt32, _ udid: String) async throws -> Void)?
}
