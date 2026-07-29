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
    typealias ConfigResolver = @Sendable (PhysicalDeviceInfo) -> DeviceCapabilityConfig

    private let client: AppiumClient
    private let preflight: DevicePreflight
    private let configResolver: ConfigResolver
    private let cacheHome: URL
    private let wdaCache: WDADeviceCache
    private let activationSettler: @Sendable () async throws -> Void

    public init(
        client: AppiumClient,
        preflight: DevicePreflight,
        config: DeviceCapabilityConfig,
        cacheHome: URL = OutlineCache.homeDirectory,
        wdaCache: WDADeviceCache = .disabled()
    ) {
        self.init(
            client: client,
            preflight: preflight,
            config: config,
            cacheHome: cacheHome,
            wdaCache: wdaCache,
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
        wdaCache: WDADeviceCache = .disabled(),
        configResolver: ConfigResolver? = nil,
        activationSettler: @escaping @Sendable () async throws -> Void
    ) {
        self.client = client
        self.preflight = preflight
        self.configResolver = configResolver ?? { _ in config }
        self.cacheHome = cacheHome
        self.wdaCache = wdaCache
        self.activationSettler = activationSettler
    }

    public static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> AppleDeviceController {
        let wdaCache = WDADeviceCache.live(environment: environment)
        return AppleDeviceController(
            client: try .live(environment: environment),
            preflight: try .live(environment: environment),
            config: .live(environment: environment),
            cacheHome: OutlineCache.homeDirectory,
            wdaCache: wdaCache,
            configResolver: { info in
                wdaCache.resolvedConfig(for: info, environment: environment)
            },
            activationSettler: {
                try await Task.sleep(for: .milliseconds(500))
            }
        )
    }

    // MARK: - describe-ui

    public func describeUI(
        udid: String,
        includeRaw: Bool,
        bundleId: String? = nil
    ) async throws -> DescribeUIResult {
        let info = try await preflight.run(udid: udid)
        let config = configResolver(info)
        let caps = try capabilities(for: info, bundleId: bundleId, config: config)
        let result = try await withActivatedSession(
            info: info,
            capabilities: caps,
            config: config,
            bundleId: bundleId
        ) { session in
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
        let config = configResolver(info)
        let caps = try capabilities(for: info, bundleId: bundleId, config: config)

        switch target {
        case .point(let x, let y):
            try await withActivatedSession(
                info: info,
                capabilities: caps,
                config: config,
                bundleId: bundleId
            ) { session in
                try await session.performPointerActions(PointerAction.tap(x: x, y: y, holdMs: holdMs))
            }
            return (x, y)

        case .cachedAlias(let raw):
            // Cache-backed: resolve the center before opening the session.
            let resolved = try OutlineAliasResolver.resolve(raw, udid: udid, home: cacheHome)
            try await withActivatedSession(
                info: info,
                capabilities: caps,
                config: config,
                bundleId: bundleId
            ) { session in
                try await session.performPointerActions(
                    PointerAction.tap(x: resolved.point.x, y: resolved.point.y, holdMs: holdMs)
                )
            }
            return resolved.point

        case .selector(let selector):
            return try await withActivatedSession(
                info: info,
                capabilities: caps,
                config: config,
                bundleId: bundleId
            ) { session in
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
        let config = configResolver(info)
        let caps = try capabilities(for: info, bundleId: bundleId, config: config)
        try await withActivatedSession(
            info: info,
            capabilities: caps,
            config: config,
            bundleId: bundleId
        ) { session in
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
        let config = configResolver(info)
        let caps = try capabilities(for: info, bundleId: bundleId, config: config)
        try await withActivatedSession(
            info: info,
            capabilities: caps,
            config: config,
            bundleId: bundleId
        ) { session in
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
        let config = configResolver(info)
        let caps = try capabilities(for: info, bundleId: bundleId, config: config)
        let encoded = Data(text.utf8).base64EncodedString()
        try await withActivatedSession(
            info: info,
            capabilities: caps,
            config: config,
            bundleId: bundleId
        ) { session in
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
        let config = configResolver(info)
        let caps = try capabilities(for: info, bundleId: bundleId, config: config)
        return try await withActivatedSession(
            info: info,
            capabilities: caps,
            config: config,
            bundleId: bundleId
        ) { session in
            try await session.screenshot()
        }
    }

    // MARK: - Helpers

    private func capabilities(
        for info: PhysicalDeviceInfo,
        bundleId: String?,
        config: DeviceCapabilityConfig
    ) throws -> AppiumCapabilities {
        try DeviceCapabilityBuilder.capabilities(for: info, bundleId: bundleId, config: config)
    }

    /// Open a session and, when a bundle is targeted, foreground that app at
    /// its current screen with `mobile: activateApp` (activate — not launch)
    /// before running the verb, so navigation from a prior command survives.
    private func withActivatedSession<Result>(
        info: PhysicalDeviceInfo,
        capabilities: AppiumCapabilities,
        config: DeviceCapabilityConfig,
        bundleId: String?,
        operation: @escaping (AppiumSession) async throws -> Result
    ) async throws -> Result {
        guard info.family == .ios,
              wdaCache.canManage(info: info, config: config)
        else {
            return try await runInstalledSession(
                capabilities: capabilities,
                bundleId: bundleId,
                operation: operation
            )
        }

        return try await wdaCache.withExclusiveRepairLock(for: info.udid) {
            // Resolve both signing inputs and the trust plan only after the
            // device lock is held. A process that waited behind a repair must
            // see the signing config that process just committed, rather than
            // repairing once more with a stale pre-lock Team/bundle.
            let lockedConfig = configResolver(info)
            guard wdaCache.canManage(info: info, config: lockedConfig) else {
                return try await runInstalledSession(
                    capabilities: self.capabilities(
                        for: info,
                        bundleId: bundleId,
                        config: lockedConfig
                    ),
                    bundleId: bundleId,
                    operation: operation
                )
            }
            let plan = wdaCache.plan(for: info, config: lockedConfig)

            do {
                return try await runActivatedSession(
                    capabilities: repairCapabilities(
                        for: info,
                        bundleId: bundleId,
                        plan: plan,
                        config: lockedConfig,
                        usePrebuiltWDA: plan.usePrebuiltWDA
                    ),
                    bundleId: bundleId,
                    onSessionCreated: {
                        recordCacheSuccess(
                            plan,
                            info: info,
                            config: lockedConfig
                        )
                    },
                    operation: operation
                )
            } catch let cachedError as AppiumSessionCreationError {
                // A locally valid prebuilt app can still be rejected after a
                // device trust/profile change. Invalidate its trust record
                // and spend one final incremental build/sign attempt. A
                // cache miss already used that build path, so it stops here.
                guard plan.usePrebuiltWDA,
                      Self.isRecoverableWDAFailure(cachedError.underlying)
                else {
                    throw cachedError.underlying
                }
                try? wdaCache.invalidate(udid: info.udid)
                do {
                    return try await runActivatedSession(
                        capabilities: repairCapabilities(
                            for: info,
                            bundleId: bundleId,
                            plan: plan,
                            config: lockedConfig,
                            usePrebuiltWDA: false
                        ),
                        bundleId: bundleId,
                        onSessionCreated: {
                            recordCacheSuccess(
                                plan,
                                info: info,
                                config: lockedConfig
                            )
                        },
                        operation: operation
                    )
                } catch let repairError as AppiumSessionCreationError {
                    throw repairError.underlying
                }
            }
        }
    }

    private func runInstalledSession<Result>(
        capabilities: AppiumCapabilities,
        bundleId: String?,
        operation: @escaping (AppiumSession) async throws -> Result
    ) async throws -> Result {
        do {
            return try await runActivatedSession(
                capabilities: capabilities,
                bundleId: bundleId,
                onSessionCreated: {},
                operation: operation
            )
        } catch let creationError as AppiumSessionCreationError {
            throw creationError.underlying
        }
    }

    private func runActivatedSession<Result>(
        capabilities: AppiumCapabilities,
        bundleId: String?,
        onSessionCreated: @escaping @Sendable () -> Void,
        operation: @escaping (AppiumSession) async throws -> Result
    ) async throws -> Result {
        try await client.withSession(
            capabilities: capabilities,
            classifyCreationFailure: true
        ) { session in
            onSessionCreated()
            if let bundleId = bundleId?.trimmingCharacters(in: .whitespacesAndNewlines), !bundleId.isEmpty {
                try await session.execute(script: "mobile: activateApp", args: [["bundleId": bundleId]])
                try await activationSettler()
            }
            return try await operation(session)
        }
    }

    private func repairCapabilities(
        for info: PhysicalDeviceInfo,
        bundleId: String?,
        plan: WDADeviceCache.Plan,
        config: DeviceCapabilityConfig,
        usePrebuiltWDA: Bool
    ) throws -> AppiumCapabilities {
        var capabilities = try self.capabilities(
            for: info,
            bundleId: bundleId,
            config: config
        )
        capabilities.usePreinstalledWDA = nil
        capabilities.usePrebuiltWDA = usePrebuiltWDA ? true : nil
        capabilities.derivedDataPath = plan.derivedDataPath.path
        capabilities.xcodeOrgId = config.xcodeOrgId
        capabilities.xcodeSigningId = config.xcodeSigningId
        return capabilities
    }

    private func recordCacheSuccess(
        _ plan: WDADeviceCache.Plan,
        info: PhysicalDeviceInfo,
        config: DeviceCapabilityConfig
    ) {
        do {
            try wdaCache.recordSigningConfiguration(for: info, config: config)
            try wdaCache.recordSuccessfulLaunch(plan)
        } catch {
            // The device verb succeeded. The timestamp/cache is an
            // optimization and must never reverse that result.
            FileHandle.standardError.write(Data(
                "warning: could not update WDA signing cache: \(error.localizedDescription)\n".utf8
            ))
        }
    }

    private static func isRecoverableWDAFailure(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return [
            "webdriveragent",
            "xcodebuild",
            "test-without-building",
            "prebuilt wda",
            "preinstalled runner",
        ].contains { message.contains($0) }
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
