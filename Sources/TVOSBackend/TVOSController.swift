// SPDX-License-Identifier: Apache-2.0
import AppiumCore
import Foundation
import SimUseCore

public enum TVOSRemoteButton: String, Codable, CaseIterable, Sendable {
    case up
    case down
    case left
    case right
    case select
    case menu
    case playPause = "play-pause"
    case home

    var appiumName: String {
        switch self {
        case .playPause: return "playpause"
        default: return rawValue
        }
    }

    /// HID keyboard usage the tvOS Simulator maps onto this remote button
    /// (arrows move focus, Return selects, Escape is Menu — the same
    /// bindings Simulator.app uses for a hardware keyboard). nil = no
    /// keyboard equivalent; those buttons only exist on the Appium path.
    var hidKeycode: UInt32? {
        switch self {
        case .up: return 82
        case .down: return 81
        case .left: return 80
        case .right: return 79
        case .select: return 40
        case .menu: return 41
        case .playPause, .home: return nil
        }
    }
}

public struct TVOSRemoteResult: Codable, Equatable, Sendable {
    public let button: TVOSRemoteButton
    public let before: Outline.Entry?
    public let after: Outline.Entry?

    public init(button: TVOSRemoteButton, before: Outline.Entry?, after: Outline.Entry?) {
        self.button = button
        self.before = before
        self.after = after
    }
}

/// High-level tvOS observe/action API shared by CLI commands and tests.
/// Every operation owns exactly one Appium session so failures cannot leave a
/// device claimed and block the next agent action.
public struct TVOSController: Sendable {
    private let client: AppiumClient
    private let defaultBundleId: String?

    public init(client: AppiumClient, defaultBundleId: String? = nil) {
        self.client = client
        self.defaultBundleId = TVOSController.normalized(bundleId: defaultBundleId)
    }

    public static func live() throws -> TVOSController {
        let environment = ProcessInfo.processInfo.environment
        return TVOSController(
            client: try .live(environment: environment),
            defaultBundleId: environment["SIM_USE_TVOS_BUNDLE_ID"]
        )
    }

    public func describeUI(
        udid: String,
        includeRaw: Bool,
        bundleId: String? = nil
    ) async throws -> DescribeUIResult {
        try await client.withSession(capabilities: makeCapabilities(udid: udid, bundleId: bundleId)) { session in
            let source = try await session.source()
            return try TVOSOutlineRenderer.render(source: source, includeRaw: includeRaw)
        }
    }

    public func pressRemote(
        _ button: TVOSRemoteButton,
        udid: String,
        bundleId: String? = nil,
        settleDelay: TimeInterval = 0.35,
        reportFocus: Bool = false
    ) async throws -> TVOSRemoteResult {
        // HID fast path (~0.3 s vs ~2.5 s for an Appium session): no
        // session, no focus report. Buttons without a keyboard binding
        // (play-pause, home) and --report-focus take the Appium path,
        // which observes the before/after focus for free.
        if !reportFocus,
           let keycode = button.hidKeycode,
           let pressKey = TVOSHIDBridge.pressKey {
            try await pressKey(keycode, udid)
            if settleDelay > 0 {
                try await Task.sleep(nanoseconds: UInt64(settleDelay * 1_000_000_000))
            }
            return TVOSRemoteResult(button: button, before: nil, after: nil)
        }

        return try await client.withSession(capabilities: makeCapabilities(udid: udid, bundleId: bundleId)) { session in
            let beforeSource = try await session.source()
            let before = try TVOSOutlineRenderer
                .render(source: beforeSource, includeRaw: false)
                .entries.first(where: { $0.states.contains("focused") })
            try await session.pressRemote(button)
            // The focus engine animates the move; sampling immediately can
            // still see the pre-press focus and misreport the transition.
            if settleDelay > 0 {
                try await Task.sleep(nanoseconds: UInt64(settleDelay * 1_000_000_000))
            }
            let afterSource = try await session.source()
            let after = try TVOSOutlineRenderer
                .render(source: afterSource, includeRaw: false)
                .entries.first(where: { $0.states.contains("focused") })
            return TVOSRemoteResult(button: button, before: before, after: after)
        }
    }

    public func screenshot(udid: String, bundleId: String? = nil) async throws -> Data {
        try await client.withSession(capabilities: makeCapabilities(udid: udid, bundleId: bundleId)) { session in
            try await session.screenshot()
        }
    }

    /// Enter a whole string through the focus keyboard: `select` opens the
    /// editing session (skipped when a keyboard is already up), the string
    /// is sent to the keyboard's text field over the WebDriver element
    /// surface — the only string-entry channel tvOS exposes; WDA has no
    /// keyboardInput/W3C-key-actions there — and `menu` commits the text
    /// and dismisses the keyboard.
    public func typeText(
        _ text: String,
        udid: String,
        bundleId: String? = nil
    ) async throws -> TVOSTypeResult {
        try await client.withSession(capabilities: makeCapabilities(udid: udid, bundleId: bundleId)) { session in
            let before = try TVOSOutlineRenderer.render(
                source: try await session.source(),
                includeRaw: false
            )
            let keyboardIsOpen = before.entries.contains { $0.role == "Keyboard" }
            if !keyboardIsOpen {
                let focused = before.entries.first { $0.states.contains("focused") }
                guard let focused, Self.textEntryRoles.contains(focused.role) else {
                    throw TVOSTypeError(focusedRole: focused?.role)
                }
                try await session.pressRemote(.select)
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
            let field = try await session.findElement(className: "XCUIElementTypeTextField")
            try await session.sendKeys(text, elementID: field)
            try await Task.sleep(nanoseconds: 300_000_000)
            try await session.pressRemote(.menu)
            try await Task.sleep(nanoseconds: 350_000_000)
            return TVOSTypeResult(text: text)
        }
    }

    /// Roles whose `select` opens the system keyboard.
    private static let textEntryRoles: Set<String> = ["TextField", "SecureTextField", "SearchField", "TextView"]

    /// The tvOS Simulator capability assembly Appium's XCUITest driver
    /// expects. A per-call `bundleId` wins over the client's default; with
    /// neither, the session attaches to the foreground app (`autoLaunch`
    /// off). This is the wire format TVOSBackend has always sent — it just
    /// lives here now instead of inside the client.
    private func makeCapabilities(udid: String, bundleId: String?) -> AppiumCapabilities {
        let resolvedBundleId = TVOSController.normalized(bundleId: bundleId) ?? defaultBundleId
        return AppiumCapabilities(
            platformName: "tvOS",
            automationName: "XCUITest",
            udid: udid,
            bundleId: resolvedBundleId,
            autoLaunch: resolvedBundleId != nil,
            noReset: true,
            useNewWDA: false,
            newCommandTimeout: 300
        )
    }

    private static func normalized(bundleId: String?) -> String? {
        let value = bundleId?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }
}

/// A tvOS remote press is Appium's `mobile: pressButton` — the platform
/// semantic that keeps AppiumCore's `execute` primitive generic. Internal
/// (not private) so the physical-device path (`TVOSDeviceController`) shares
/// the one definition.
extension AppiumSession {
    func pressRemote(_ button: TVOSRemoteButton) async throws {
        try await execute(script: "mobile: pressButton", args: [["name": button.appiumName]])
    }
}

public struct TVOSTypeResult: Codable, Equatable, Sendable {
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

/// `type` needs the focus to already sit on a text field — there is no
/// coordinate fallback on tvOS to find one.
public struct TVOSTypeError: Error, LocalizedError, HintProviding, Equatable {
    public let focusedRole: String?

    public init(focusedRole: String?) {
        self.focusedRole = focusedRole
    }

    public var errorDescription: String? {
        let current = focusedRole.map { "the focused element is a \($0)" } ?? "no element is focused"
        return "tvos type needs focus on a text field, but \(current)."
    }

    public var hint: String? {
        "Run `sim-use tvos ui` to inspect the screen and move focus onto the text field with `sim-use tvos remote <direction>` first."
    }
}
