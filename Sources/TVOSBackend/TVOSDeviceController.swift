// SPDX-License-Identifier: Apache-2.0
import AppiumCore
import DeviceBackend
import Foundation
import SimUseCore

/// The physical Apple TV path for the focus-driven tvOS verbs. Distinct
/// from `TVOSController` (the Simulator) because a real device needs the
/// DeviceBackend preflight (server + tunnel) and the xcodebuild-flow
/// capabilities, and because the Simulator's HID fast path and
/// `simctl io screenshot` shortcut do not exist on a device — every verb
/// goes through one preflighted, always-deleted Appium session.
///
/// Verb matrix by OS (tvOS 26 Addendum): 17+/26 → ui + remote + screenshot;
/// ≤16.x → remote + screenshot only, `ui` fails fast because the a11y
/// hierarchy snapshot crashes WebDriverAgent (signal 9) on those releases.
public struct TVOSDeviceController: Sendable {
    private let client: AppiumClient
    private let preflight: DevicePreflight
    private let config: DeviceCapabilityConfig
    private let defaultBundleId: String?

    public init(
        client: AppiumClient,
        preflight: DevicePreflight,
        config: DeviceCapabilityConfig,
        defaultBundleId: String? = nil
    ) {
        self.client = client
        self.preflight = preflight
        self.config = config
        self.defaultBundleId = defaultBundleId?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil
    }

    public static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> TVOSDeviceController {
        TVOSDeviceController(
            client: try .live(environment: environment),
            preflight: try .live(environment: environment),
            config: .live(environment: environment),
            defaultBundleId: environment["SIM_USE_TVOS_BUNDLE_ID"]
        )
    }

    public func describeUI(
        udid: String,
        includeRaw: Bool,
        bundleId: String? = nil
    ) async throws -> DescribeUIResult {
        let info = try await preflight.run(udid: udid)
        // The ≤16.x a11y hierarchy crashes WDA (signal 9), so `ui` is
        // gated off there — before caps assembly, so the message is the
        // OS limitation, not a missing external-WDA URL.
        guard info.isModern else {
            throw TVOSDeviceUIUnsupportedError(udid: udid, osMajorVersion: info.osMajorVersion)
        }
        let caps = try capabilities(for: info, bundleId: bundleId)
        return try await withActivatedSession(caps, bundleId: bundleId) { session in
            try TVOSOutlineRenderer.render(source: try await session.source(), includeRaw: includeRaw)
        }
    }

    public func pressRemote(
        _ button: TVOSRemoteButton,
        udid: String,
        bundleId: String? = nil,
        settleDelay: TimeInterval = 0.35,
        reportFocus: Bool = false
    ) async throws -> TVOSRemoteResult {
        let info = try await preflight.run(udid: udid)
        let caps = try capabilities(for: info, bundleId: bundleId)
        return try await withActivatedSession(caps, bundleId: bundleId) { session in
            // No HID fast path on a physical TV — the press always goes
            // through Appium. Focus is observed only when asked, since each
            // source round-trip costs a WDA hierarchy fetch.
            let before = reportFocus ? try await focusedEntry(session) : nil
            try await session.pressRemote(button)
            if settleDelay > 0 {
                try await Task.sleep(nanoseconds: UInt64(settleDelay * 1_000_000_000))
            }
            let after = reportFocus ? try await focusedEntry(session) : nil
            return TVOSRemoteResult(button: button, before: before, after: after)
        }
    }

    public func screenshot(udid: String, bundleId: String? = nil) async throws -> Data {
        let info = try await preflight.run(udid: udid)
        let caps = try capabilities(for: info, bundleId: bundleId)
        return try await withActivatedSession(caps, bundleId: bundleId) { session in
            try await session.screenshot()
        }
    }

    private func focusedEntry(_ session: AppiumSession) async throws -> Outline.Entry? {
        try TVOSOutlineRenderer
            .render(source: try await session.source(), includeRaw: false)
            .entries.first { $0.states.contains("focused") }
    }

    private func capabilities(for info: PhysicalDeviceInfo, bundleId: String?) throws -> AppiumCapabilities {
        try DeviceCapabilityBuilder.capabilities(for: info, bundleId: resolvedBundleId(bundleId), config: config)
    }

    private func resolvedBundleId(_ bundleId: String?) -> String? {
        bundleId?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil ?? defaultBundleId
    }

    /// Open a session and, when a bundle is targeted, foreground it at its
    /// current screen with `mobile: activateApp` (activate — not launch)
    /// before the verb runs, matching the iOS device path.
    private func withActivatedSession<Result>(
        _ capabilities: AppiumCapabilities,
        bundleId: String?,
        operation: @escaping (AppiumSession) async throws -> Result
    ) async throws -> Result {
        let resolved = resolvedBundleId(bundleId)
        return try await client.withSession(capabilities: capabilities) { session in
            if let resolved {
                try await session.execute(script: "mobile: activateApp", args: [["bundleId": resolved]])
            }
            return try await operation(session)
        }
    }
}

/// `ui` is unavailable on tvOS ≤16.x devices: fetching the accessibility
/// hierarchy crashes WebDriverAgent (Exit due to signal: 9), so we reject
/// before touching the device rather than killing the WDA the other verbs
/// still need (P0-C3).
public struct TVOSDeviceUIUnsupportedError: Error, LocalizedError, HintProviding, Equatable {
    public let udid: String
    public let osMajorVersion: Int?

    public init(udid: String, osMajorVersion: Int?) {
        self.udid = udid
        self.osMajorVersion = osMajorVersion
    }

    public var errorDescription: String? {
        let version = osMajorVersion.map { "tvOS \($0).x" } ?? "this tvOS version"
        return "`ui` is not supported on \(version) physical devices (\(udid)): the accessibility hierarchy snapshot crashes WebDriverAgent on tvOS ≤16."
    }

    public var hint: String? {
        "Use `sim-use tvos remote <button>` to navigate by focus and `sim-use tvos screenshot` to see the screen. Full `ui` needs a tvOS 17+ device."
    }
}

extension String {
    fileprivate var nonEmptyOrNil: String? { isEmpty ? nil : self }
}
