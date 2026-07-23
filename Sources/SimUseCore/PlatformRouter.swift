// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The platforms `sim-use` can target: iOS/tvOS Simulator, Android, and
/// physical Apple devices (iOS/tvOS, WebDriverAgent-backed — verbs land in
/// the DeviceBackend, xd 2.0 Phase 1 T3).
///
/// `appleDevice` deliberately carries no iOS-vs-tvOS family: a bare UDID
/// cannot tell an iPhone from an Apple TV. Routing (which backend owns the
/// command) only needs "this is a physical Apple device"; the family is a
/// listing concern, resolved from `devicectl`'s DeviceClass when enumerating
/// (`Device.Platform` = `.ios` / `.tvos`), not from the UDID shape here.
public enum Platform: Equatable, Sendable {
    case iOSSim
    case tvOSSim
    case android
    case appleDevice
}

/// Centralises the UDID-shape heuristics used to decide which backend
/// owns a command invocation. Top-level forwarders ask
/// `PlatformRouter.resolve(udid:)` instead of carrying their own
/// `looksLikeAndroid` checks (the pattern that grew to ~17 sites and
/// motivated this module).
///
/// Resolution layers, in priority order:
///   1. Explicit `--platform` flag — handled by the caller; we accept
///      a pre-resolved override.
///   2. Daemon pidfile platform tag — also caller-side (the daemon
///      knows its own platform).
///   3. UDID-shape inference (this module).
public enum PlatformRouter {

    /// Classify a UDID into a target platform. Returns `nil` when the
    /// shape doesn't fit any known platform; callers can choose to fail
    /// fast or fall back to a default.
    public static func resolve(
        udid: String,
        simulatorPlatformLookup: (String) -> Platform? = SimulatorPlatformResolver.livePlatform(for:)
    ) -> Platform? {
        let trimmed = udid.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        // Physical Apple devices are checked *before* the Android fallback:
        // a dash-form device UDID otherwise satisfies `looksLikeAndroid`
        // (length 25, has digits, allowed charset) and mis-routes to adb
        // (`adb is not on PATH` — P0 breakpoint #2).
        if looksLikeAppleDevice(trimmed) { return .appleDevice }
        if looksLikeAndroid(trimmed) { return .android }
        if looksLikeIOSSim(trimmed) {
            // A lookup miss (unknown UUID, unsupported runtime family such
            // as watchOS, or a custom device set with simctl unavailable)
            // keeps the historical iOS fallback: the iOS backend owns the
            // clearer "not booted / not found" error surface.
            return simulatorPlatformLookup(trimmed) ?? .iOSSim
        }
        return nil
    }

    /// `true` when the UDID looks like an Apple Simulator UDID
    /// (8-4-4-4-12 hex, as emitted by `simctl list`).
    public static func looksLikeIOSSim(_ udid: String) -> Bool {
        let pattern = "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"
        return udid.range(of: pattern, options: .regularExpression) != nil
    }

    /// A physical Apple device UDID in the modern ECID-derived form:
    /// 8 hex, a dash, then 16 hex — e.g. `00008140-00096D5C0CEA801C`
    /// (iPhone 15/16/17-generation, as emitted by `idevice_id -l` and
    /// `devicectl`'s `hardwareProperties.udid`). Uppercase as Apple emits it.
    static let appleDeviceDashUDIDPattern = "^[0-9A-F]{8}-[0-9A-F]{16}$"

    /// A physical Apple device UDID in the classic 40-hex form —
    /// e.g. `c311e5afe90ee702b80e8b64e1e12796e04e63a0` (older iPhone and
    /// Apple TV). Lowercase, no dashes, exactly 40 characters.
    static let appleDeviceClassicUDIDPattern = "^[0-9a-f]{40}$"

    /// `true` when the UDID looks like a physical Apple device (iOS or tvOS),
    /// in either the modern dash form or the classic 40-hex form. Checked
    /// before `looksLikeAndroid` in `resolve` so a device never falls into
    /// the adb path (P0 breakpoint #2). Neither pattern overlaps the
    /// Simulator UUID shape (which carries four dashes), so the ordering is
    /// safe.
    public static func looksLikeAppleDevice(_ udid: String) -> Bool {
        let trimmed = udid.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        if trimmed.range(of: appleDeviceDashUDIDPattern, options: .regularExpression) != nil { return true }
        if trimmed.range(of: appleDeviceClassicUDIDPattern, options: .regularExpression) != nil { return true }
        return false
    }

    /// `true` when the UDID looks like an Android serial.
    ///
    /// Heuristic, in order:
    ///   1. `emulator-…` prefix → always Android.
    ///   2. Apple Simulator UDID shape → never Android.
    ///   3. Physical Apple device UDID shape → never Android.
    ///   4. ASCII-only, length 4–32, allowed `[A-Za-z0-9._:-]`, with at
    ///      least one digit → Android.
    ///
    /// Rule 3 keeps typos like `--udid foo` (too short) or
    /// `--udid mycoolphone` (no digits) out of the adb path; they fall
    /// through to the iOS resolver, which surfaces a clearer error
    /// faster than waiting 5 s for `adb -s <typo> …` to time out.
    public static func looksLikeAndroid(_ udid: String) -> Bool {
        let trimmed = udid.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        if trimmed.hasPrefix("emulator-") { return true }
        if looksLikeIOSSim(trimmed) { return false }
        // Physical Apple device UDIDs (dash form fits the length/charset
        // rule below) are never adb serials — exclude them explicitly so
        // rule 3 can't claim them.
        if looksLikeAppleDevice(trimmed) { return false }
        guard trimmed.count >= 4, trimmed.count <= 32 else { return false }
        let allowed: (Character) -> Bool = { ch in
            ch.isASCII && (
                ch.isLetter || ch.isNumber || ch == "-" || ch == "." || ch == ":" || ch == "_"
            )
        }
        guard trimmed.allSatisfy(allowed) else { return false }
        guard trimmed.contains(where: { $0.isNumber }) else { return false }
        return true
    }
}
