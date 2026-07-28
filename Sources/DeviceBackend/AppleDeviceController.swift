// SPDX-License-Identifier: Apache-2.0
import Foundation
import AppiumCore
import SimUseCore

/// How a `tap` names its target. Explicit coordinates and cached `@N`/`#N`
/// aliases resolve without a live tree; a `DeviceSelector` needs a fresh
/// `source` inside the tap's own session so the match reflects the screen
/// as it is now.
public enum DeviceTapTarget: Sendable, Equatable {
    case point(x: Double, y: Double)
    case cachedAlias(String)
    case selector(DeviceSelector)
}

/// The physical-device verb engine for the **iOS** family: describe-ui,
/// tap, swipe, type, paste, screenshot over WebDriverAgent. Every verb runs
/// the fail-fast preflight, then does its work inside exactly one Appium
/// session (`AppiumClient.withSession` always deletes it), so a failure
/// never leaves the device claimed for the next agent action (P0-C3).
///
/// Coordinate verbs reject a tvOS device with `TVOSCapabilityError` — tvOS
/// is focus-driven and its verbs live under `sim-use tvos`. `screenshot`
/// is family-agnostic (the caps assembler picks the right WDA path), and
/// `describeUI` renders the iOS outline; the CLI routes a tvOS device's
/// `ui` to the tvOS path instead.
public struct AppleDeviceController: Sendable {
    private let client: AppiumClient
    private let preflight: DevicePreflight
    private let config: DeviceCapabilityConfig
    private let cacheHome: URL
    private let activationSettler: @Sendable () async throws -> Void

    public init(
        client: AppiumClient,
        preflight: DevicePreflight,
        config: DeviceCapabilityConfig,
        cacheHome: URL = OutlineCache.homeDirectory
    ) {
        self.init(
            client: client,
            preflight: preflight,
            config: config,
            cacheHome: cacheHome,
            activationSettler: {
                // `mobile: activateApp` returns while iOS is still animating
                // from SpringBoard. A command issued immediately afterwards
                // can therefore capture or interact with the outgoing frame.
                try await Task.sleep(for: .milliseconds(500))
            }
        )
    }

    init(
        client: AppiumClient,
        preflight: DevicePreflight,
        config: DeviceCapabilityConfig,
        cacheHome: URL,
        activationSettler: @escaping @Sendable () async throws -> Void
    ) {
        self.client = client
        self.preflight = preflight
        self.config = config
        self.cacheHome = cacheHome
        self.activationSettler = activationSettler
    }

    public static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> AppleDeviceController {
        AppleDeviceController(
            client: try .live(environment: environment),
            preflight: try .live(environment: environment),
            config: .live(environment: environment)
        )
    }

    // MARK: - describe-ui

    public func describeUI(
        udid: String,
        includeRaw: Bool,
        bundleId: String? = nil
    ) async throws -> DescribeUIResult {
        let info = try await preflight.run(udid: udid)
        let caps = try capabilities(for: info, bundleId: bundleId)
        let result = try await withActivatedSession(capabilities: caps, bundleId: bundleId) { session in
            try DeviceOutlineRenderer.render(source: try await session.source(), includeRaw: includeRaw)
        }
        // Persist the alias cache so `tap @N` / `#N` resolve cross-command,
        // exactly like the iOS Simulator path. Best-effort: a cache write
        // failure must not fail the observation the user already got.
        let outline = Outline(
            text: result.outline,
            entries: result.entries,
            lists: result.lists,
            screen: result.screen,
            appLabel: result.appLabel
        )
        try? OutlineCache.write(outline: outline, udid: udid, home: cacheHome)
        return result
    }

    // MARK: - tap

    @discardableResult
    public func tap(
        udid: String,
        target: DeviceTapTarget,
        bundleId: String? = nil,
        holdMs: Int = 0
    ) async throws -> (x: Double, y: Double) {
        let info = try await preflight.run(udid: udid)
        try requireIOS(info, command: "tap")
        let caps = try capabilities(for: info, bundleId: bundleId)

        switch target {
        case .point(let x, let y):
            try await withActivatedSession(capabilities: caps, bundleId: bundleId) { session in
                try await session.performPointerActions(PointerAction.tap(x: x, y: y, holdMs: holdMs))
            }
            return (x, y)

        case .cachedAlias(let raw):
            // Cache-backed: resolve the center before opening the session.
            let resolved = try OutlineAliasResolver.resolve(raw, udid: udid, home: cacheHome)
            try await withActivatedSession(capabilities: caps, bundleId: bundleId) { session in
                try await session.performPointerActions(
                    PointerAction.tap(x: resolved.point.x, y: resolved.point.y, holdMs: holdMs)
                )
            }
            return resolved.point

        case .selector(let selector):
            return try await withActivatedSession(capabilities: caps, bundleId: bundleId) { session in
                let result = try DeviceOutlineRenderer.render(source: try await session.source(), includeRaw: false)
                let entry = try DeviceSelectorResolver.resolve(selector, in: result.entries, screen: result.screen)
                let point = DeviceSelectorResolver.center(of: entry)
                try await session.performPointerActions(PointerAction.tap(x: point.x, y: point.y, holdMs: holdMs))
                return point
            }
        }
    }

    // MARK: - swipe

    public func swipe(
        udid: String,
        from: (x: Double, y: Double),
        to: (x: Double, y: Double),
        durationMs: Int,
        bundleId: String? = nil
    ) async throws {
        let info = try await preflight.run(udid: udid)
        try requireIOS(info, command: "swipe")
        let caps = try capabilities(for: info, bundleId: bundleId)
        try await withActivatedSession(capabilities: caps, bundleId: bundleId) { session in
            try await session.performPointerActions(
                PointerAction.swipe(fromX: from.x, fromY: from.y, toX: to.x, toY: to.y, durationMs: durationMs)
            )
        }
    }

    // MARK: - type

    public func type(
        udid: String,
        text: String,
        bundleId: String? = nil
    ) async throws {
        let info = try await preflight.run(udid: udid)
        try requireIOS(info, command: "type")
        let caps = try capabilities(for: info, bundleId: bundleId)
        try await withActivatedSession(capabilities: caps, bundleId: bundleId) { session in
            let element = try await session.activeElement()
            try await session.sendKeys(text, elementID: element)
        }
    }

    // MARK: - paste

    public func paste(
        udid: String,
        text: String,
        bundleId: String? = nil
    ) async throws {
        let info = try await preflight.run(udid: udid)
        try requireIOS(info, command: "paste")
        let caps = try capabilities(for: info, bundleId: bundleId)
        let encoded = Data(text.utf8).base64EncodedString()
        try await withActivatedSession(capabilities: caps, bundleId: bundleId) { session in
            // Seed the device pasteboard (bypasses IME composition), then
            // deliver the text into the focused field. WDA has no
            // hardware-Cmd+V on a physical device, so the send is what
            // actually lands the text; the pasteboard seed makes a
            // subsequent in-app paste consistent.
            try await session.execute(
                script: "mobile: setPasteboard",
                args: [["content": encoded, "encoding": "base64"]]
            )
            let element = try await session.activeElement()
            try await session.sendKeys(text, elementID: element)
        }
    }

    // MARK: - screenshot

    /// Family-agnostic: the caps assembler picks the iOS or tvOS WDA path,
    /// and the base64→PNG decode happens in `AppiumClient.screenshot`.
    public func screenshot(
        udid: String,
        bundleId: String? = nil
    ) async throws -> Data {
        let info = try await preflight.run(udid: udid)
        let caps = try capabilities(for: info, bundleId: bundleId)
        return try await withActivatedSession(capabilities: caps, bundleId: bundleId) { session in
            try await session.screenshot()
        }
    }

    // MARK: - Helpers

    private func capabilities(for info: PhysicalDeviceInfo, bundleId: String?) throws -> AppiumCapabilities {
        try DeviceCapabilityBuilder.capabilities(for: info, bundleId: bundleId, config: config)
    }

    /// Open a session and, when a bundle is targeted, foreground that app at
    /// its current screen with `mobile: activateApp` (activate — not launch)
    /// before running the verb, so navigation from a prior command survives.
    private func withActivatedSession<Result>(
        capabilities: AppiumCapabilities,
        bundleId: String?,
        operation: @escaping (AppiumSession) async throws -> Result
    ) async throws -> Result {
        try await client.withSession(capabilities: capabilities) { session in
            if let bundleId = bundleId?.trimmingCharacters(in: .whitespacesAndNewlines), !bundleId.isEmpty {
                try await session.execute(script: "mobile: activateApp", args: [["bundleId": bundleId]])
                try await activationSettler()
            }
            return try await operation(session)
        }
    }

    /// Coordinate/keyboard verbs have no meaning on focus-driven tvOS —
    /// reject before any side effect and point at the remote surface,
    /// exactly as the tvOS Simulator path does.
    private func requireIOS(_ info: PhysicalDeviceInfo, command: String) throws {
        if info.family == .tvos {
            throw TVOSCapabilityError(command: command)
        }
    }
}
