// SPDX-License-Identifier: Apache-2.0
import AppiumCore
import DeviceBackend
import Foundation
import SimUseCore

/// The physical Apple TV path for the focus-driven tvOS verbs. Distinct
/// from `TVOSController` (the Simulator) because a real device needs the
/// DeviceBackend preflight (server + tunnel) and an XCTest-backed installed
/// WDA lifecycle (with xcodebuild retained as a repair path), and because
/// the Simulator's HID fast path and
/// `simctl io screenshot` shortcut do not exist on a device — every verb
/// goes through one preflighted, always-deleted Appium session.
///
    /// Verb matrix by OS (tvOS 26 Addendum): 17+/26 → ui + remote + screenshot
    /// + type; ≤16.x → remote + screenshot only, because operations that read
    /// the a11y hierarchy crash WebDriverAgent (signal 9) on those releases.
public struct TVOSDeviceController: Sendable {
    private let client: AppiumClient
    private let preflight: DevicePreflight
    private let config: DeviceCapabilityConfig
    private let defaultBundleId: String?
    private let wdaCache: WDADeviceCache
    private let wdaEndpointProvider: TVOSWDAEndpointProvider

    public init(
        client: AppiumClient,
        preflight: DevicePreflight,
        config: DeviceCapabilityConfig,
        defaultBundleId: String? = nil,
        wdaCache: WDADeviceCache = .disabled(),
        wdaEndpointProvider: TVOSWDAEndpointProvider = .disabled()
    ) {
        self.client = client
        self.preflight = preflight
        self.config = config
        self.defaultBundleId = defaultBundleId?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil
        self.wdaCache = wdaCache
        self.wdaEndpointProvider = wdaEndpointProvider
    }

    public static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> TVOSDeviceController {
        TVOSDeviceController(
            client: try .live(environment: environment),
            preflight: try .live(environment: environment),
            config: .live(environment: environment),
            defaultBundleId: environment["SIM_USE_TVOS_BUNDLE_ID"],
            wdaCache: .live(environment: environment),
            wdaEndpointProvider: .live(environment: environment)
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
        return try await withActivatedSession(info, bundleId: bundleId) { session in
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
        return try await withActivatedSession(info, bundleId: bundleId) { session in
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
        return try await withActivatedSession(info, bundleId: bundleId) { session in
            try await session.screenshot()
        }
    }

    public func typeText(
        _ text: String,
        udid: String,
        bundleId: String? = nil
    ) async throws -> TVOSTypeResult {
        let info = try await preflight.run(udid: udid)
        guard info.isModern else {
            throw TVOSDeviceTypeUnsupportedError(udid: udid, osMajorVersion: info.osMajorVersion)
        }
        return try await withActivatedSession(info, bundleId: bundleId) { session in
            try await TVOSTextInput.perform(text, in: session)
        }
    }

    private func focusedEntry(_ session: AppiumSession) async throws -> Outline.Entry? {
        try TVOSOutlineRenderer
            .render(source: try await session.source(), includeRaw: false)
            .entries.first { $0.states.contains("focused") }
    }

    private func resolvedBundleId(_ bundleId: String?) -> String? {
        bundleId?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil ?? defaultBundleId
    }

    /// Open a session and, when a bundle is targeted, foreground it at its
    /// current screen with `mobile: activateApp` (activate — not launch)
    /// before the verb runs, matching the iOS device path.
    private func withActivatedSession<Result>(
        _ info: PhysicalDeviceInfo,
        bundleId: String?,
        operation: @escaping (AppiumSession) async throws -> Result
    ) async throws -> Result {
        let resolved = resolvedBundleId(bundleId)

        // With an explicit tunnel registry, modern tvOS has an
        // installed-runner fast path that sim-use owns: launch it as a real
        // XCTest through testmanagerd, keep that lifecycle alive, and give
        // Appium only its local URL. With no registry the provider returns
        // nil and the normal Appium-managed WDA/signing-cache path below owns
        // the lifecycle instead.
        if let resolved,
           let endpoint = try await wdaEndpointProvider.endpoint(
               for: info,
               targetBundleId: resolved,
               config: config
           )
        {
            let capabilities = try DeviceCapabilityBuilder.capabilities(
                for: info,
                bundleId: resolved,
                config: config,
                externalWDAURL: endpoint.absoluteString
            )
            do {
                return try await runSession(
                    capabilities: capabilities,
                    resolvedBundleId: resolved,
                    onSessionCreated: {},
                    operation: operation
                )
            } catch let creationError as AppiumSessionCreationError {
                // The endpoint provider owns this WDA. Do not cross from
                // attach-only into an implicit xcodebuild/sign retry.
                throw creationError.underlying
            }
        }

        let plan = wdaCache.plan(for: info, config: config)
        var capabilities = try DeviceCapabilityBuilder.capabilities(
            for: info,
            bundleId: resolved,
            config: config
        )
        apply(plan: plan, to: &capabilities)

        do {
            let result = try await runSession(
                capabilities: capabilities,
                resolvedBundleId: resolved,
                onSessionCreated: { recordCacheSuccess(plan) },
                operation: operation
            )
            return result
        } catch let creationError as AppiumSessionCreationError {
            // A validated prebuilt artifact can still become unusable after
            // a device/profile state change. Invalidate only its trust
            // record and make one incremental build attempt in the same
            // DerivedData directory. Never retry an operation after the
            // session was created — remote/select/source verbs are not all
            // idempotent.
            guard plan.usePrebuiltWDA,
                  Self.isRecoverableFastPathFailure(creationError.underlying)
            else {
                throw creationError.underlying
            }
            try? wdaCache.invalidate(udid: info.udid)
            var repairCapabilities = try DeviceCapabilityBuilder.capabilities(
                for: info,
                bundleId: resolved,
                config: config
            )
            repairCapabilities.derivedDataPath = plan.derivedDataPath.path
            repairCapabilities.usePrebuiltWDA = nil
            do {
                return try await runSession(
                    capabilities: repairCapabilities,
                    resolvedBundleId: resolved,
                    onSessionCreated: { recordCacheSuccess(plan) },
                    operation: operation
                )
            } catch let repairError as AppiumSessionCreationError {
                // The repair budget is exactly one. Preserve the underlying
                // Appium error and do not recurse into another build.
                throw repairError.underlying
            }
        }
    }

    private func runSession<Result>(
        capabilities: AppiumCapabilities,
        resolvedBundleId: String?,
        onSessionCreated: @escaping @Sendable () -> Void,
        operation: @escaping (AppiumSession) async throws -> Result
    ) async throws -> Result {
        try await client.withSession(
            capabilities: capabilities,
            classifyCreationFailure: true
        ) { session in
            onSessionCreated()
            if let resolvedBundleId {
                try await session.execute(
                    script: "mobile: activateApp",
                    args: [["bundleId": resolvedBundleId]]
                )
            }
            return try await operation(session)
        }
    }

    private func apply(
        plan: WDADeviceCache.Plan,
        to capabilities: inout AppiumCapabilities
    ) {
        // Disabled/non-xcodebuild strategies stay byte-for-byte unchanged.
        guard plan.missReason != .cacheDisabled,
              plan.missReason != .strategyNotCacheable
        else { return }
        capabilities.derivedDataPath = plan.derivedDataPath.path
        capabilities.usePrebuiltWDA = plan.usePrebuiltWDA ? true : nil
    }

    private func recordCacheSuccess(_ plan: WDADeviceCache.Plan) {
        do {
            try wdaCache.recordSuccessfulLaunch(plan)
        } catch {
            // The user-visible verb already succeeded. A cache is an
            // optimization, so report its failure on stderr without
            // changing the command outcome.
            FileHandle.standardError.write(Data(
                "warning: could not update WDA signing cache: \(error.localizedDescription)\n".utf8
            ))
        }
    }

    private static func isRecoverableFastPathFailure(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return [
            "webdriveragent",
            "xcodebuild",
            "test-without-building",
            "prebuilt wda",
        ].contains { message.contains($0) }
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

public struct TVOSDeviceTypeUnsupportedError: Error, LocalizedError, HintProviding, Equatable {
    public let udid: String
    public let osMajorVersion: Int?

    public init(udid: String, osMajorVersion: Int?) {
        self.udid = udid
        self.osMajorVersion = osMajorVersion
    }

    public var errorDescription: String? {
        let version = osMajorVersion.map { "tvOS \($0).x" } ?? "this tvOS version"
        return "`type` is not supported on \(version) physical devices (\(udid)): reading keyboard focus crashes WebDriverAgent on tvOS ≤16."
    }

    public var hint: String? {
        "Use `sim-use tvos remote <button>` and `sim-use tvos screenshot` on this device. Physical `tvos type` needs tvOS 17+."
    }
}

extension String {
    fileprivate var nonEmptyOrNil: String? { isEmpty ? nil : self }
}
