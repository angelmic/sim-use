// SPDX-License-Identifier: Apache-2.0
@testable import SimUseCore
import Testing

/// Pins the UDID-shape routing that decides which backend owns a command.
/// The physical-Apple-device cases are the P0 breakpoint #2 fix: a dash-form
/// device UDID used to satisfy `looksLikeAndroid` (length 25, has digits,
/// allowed charset) and got routed to adb (`adb is not on PATH`); a classic
/// 40-hex UDID fell through to `nil`. Both must now resolve to `.appleDevice`
/// *before* the Android fallback runs.
@Suite("PlatformRouter — Apple physical device routing")
struct PlatformRouterAppleDeviceTests {
    // Real shapes captured from `idevice_id -l` / `devicectl list devices`:
    //   dash form  — iPhone 16 Pro Max "Test iPhone" (ECID-derived UDID)
    //   classic 40 — Apple TV "Test Apple TV" (older 40-hex UDID)
    private let dashDevice = "00008110-001234567890001E"
    private let classicDevice = "0123456789abcdef0123456789abcdef01234567"
    private let simUUID = "8C06D6B2-10CB-468B-BDBE-EC425EF08A34"
    private let androidEmulator = "emulator-5554"
    private let androidSerial = "R58N30ABCDE"

    // MARK: - looksLikeAppleDevice

    @Test("recognises the dash UDID form")
    func dashFormIsAppleDevice() {
        #expect(PlatformRouter.looksLikeAppleDevice(dashDevice))
    }

    @Test("recognises the classic 40-hex UDID form")
    func classicFormIsAppleDevice() {
        #expect(PlatformRouter.looksLikeAppleDevice(classicDevice))
    }

    @Test("does not mistake a Simulator UUID, Android serial, or junk for a device")
    func nonDeviceShapesRejected() {
        #expect(!PlatformRouter.looksLikeAppleDevice(simUUID))
        #expect(!PlatformRouter.looksLikeAppleDevice(androidEmulator))
        #expect(!PlatformRouter.looksLikeAppleDevice(androidSerial))
        #expect(!PlatformRouter.looksLikeAppleDevice(""))
        #expect(!PlatformRouter.looksLikeAppleDevice("abc"))
        // 39 hex chars — one short of the classic form; must not match.
        #expect(!PlatformRouter.looksLikeAppleDevice(String(repeating: "a", count: 39)))
    }

    // MARK: - looksLikeAndroid regression (P0 breakpoint #2)

    @Test("a physical device UDID is NOT classified as Android")
    func deviceUDIDsAreNotAndroid() {
        // The bug: dashDevice satisfied the generic Android serial heuristic
        // (len 25, digits, allowed charset). It must be excluded now.
        #expect(!PlatformRouter.looksLikeAndroid(dashDevice))
        #expect(!PlatformRouter.looksLikeAndroid(classicDevice))
    }

    @Test("genuine Android serials still classify as Android")
    func androidStillDetected() {
        #expect(PlatformRouter.looksLikeAndroid(androidEmulator))
        #expect(PlatformRouter.looksLikeAndroid(androidSerial))
        #expect(!PlatformRouter.looksLikeAndroid(simUUID))
    }

    // MARK: - resolve

    @Test("resolve routes both device UDID forms to .appleDevice")
    func resolveRoutesDevices() {
        #expect(PlatformRouter.resolve(udid: dashDevice) == .appleDevice)
        #expect(PlatformRouter.resolve(udid: classicDevice) == .appleDevice)
    }

    @Test("physical-device UDID matching is case-insensitive")
    func deviceUDIDCaseVariantsRouteToAppleDevice() {
        let lowercaseDash = dashDevice.lowercased()
        let uppercaseClassic = classicDevice.uppercased()

        #expect(PlatformRouter.looksLikeAppleDevice(lowercaseDash))
        #expect(PlatformRouter.looksLikeAppleDevice(uppercaseClassic))
        #expect(PlatformRouter.resolve(udid: lowercaseDash) == .appleDevice)
        #expect(PlatformRouter.resolve(udid: uppercaseClassic) == .appleDevice)
        #expect(!PlatformRouter.looksLikeAndroid(lowercaseDash))
        #expect(!PlatformRouter.looksLikeAndroid(uppercaseClassic))
    }

    @Test("resolve prefers .appleDevice over the Android fallback (P0 #2)")
    func resolveOrderingBeatsAndroid() {
        // Regression guard: before the fix this returned .android for the
        // dash form and the command then failed with "adb is not on PATH".
        #expect(PlatformRouter.resolve(udid: dashDevice) != .android)
        #expect(PlatformRouter.resolve(udid: dashDevice) == .appleDevice)
    }

    @Test("resolve still routes Android serials and Simulator UUIDs")
    func resolveKeepsExistingRoutes() {
        #expect(PlatformRouter.resolve(udid: androidEmulator) == .android)
        #expect(PlatformRouter.resolve(udid: androidSerial) == .android)
        #expect(PlatformRouter.resolve(udid: "") == nil)
        // Simulator UUID defers to the injected platform lookup.
        #expect(PlatformRouter.resolve(udid: simUUID, simulatorPlatformLookup: { _ in .tvOSSim }) == .tvOSSim)
        #expect(PlatformRouter.resolve(udid: simUUID, simulatorPlatformLookup: { _ in nil }) == .iOSSim)
    }
}
