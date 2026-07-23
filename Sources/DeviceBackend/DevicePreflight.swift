// SPDX-License-Identifier: Apache-2.0
import Foundation
import AppiumCore
import SimUseCore

/// The fail-fast gate every physical-device verb runs before it opens an
/// Appium session. Two cheap checks, in cost order:
///
///   1. `GET /status` against the Appium server with a 3 s ceiling — a
///      wedged or absent server answers here in seconds instead of hanging
///      the session POST for ~90 s (P0-C2).
///   2. The CoreDevice tunnel for the target device is `connected`
///      (resolved from `devicectl`) — an unplugged / untrusted device is
///      rejected before a session POST would silently stall on the WDA
///      handshake.
///
/// Both the status transport and the device-info source are injected so the
/// gate is unit-testable without a live server or a cabled device.
public struct DevicePreflight: Sendable {
    private let baseURL: URL
    private let statusTransport: any AppiumTransport
    private let infoResolver: DeviceInfoResolver

    public init(
        baseURL: URL,
        statusTransport: any AppiumTransport,
        infoResolver: DeviceInfoResolver = DeviceInfoResolver()
    ) {
        self.baseURL = baseURL
        self.statusTransport = statusTransport
        self.infoResolver = infoResolver
    }

    /// Live gate: endpoint from `SIM_USE_APPIUM_URL` (validated by
    /// `AppiumClient.live`), a dedicated 3 s-timeout URLSession for the
    /// `/status` probe (the session transport's 180 s ceiling is for the
    /// WDA-building session POST, far too long for a reachability check),
    /// and the production `devicectl` device list.
    public static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> DevicePreflight {
        let baseURL = try AppiumClient.live(environment: environment).baseURL
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 3
        return DevicePreflight(
            baseURL: baseURL,
            statusTransport: URLSessionAppiumTransport(session: URLSession(configuration: configuration))
        )
    }

    /// Run both checks and return the resolved device facts (family, OS
    /// major, tunnel state) so the caller can assemble capabilities without
    /// re-querying `devicectl`.
    @discardableResult
    public func run(udid: String) async throws -> PhysicalDeviceInfo {
        try await checkServerReachable()
        return try checkDeviceReachable(udid: udid)
    }

    /// `GET {baseURL}/status`. Any transport failure or non-2xx becomes
    /// `.appiumUnreachable` — the check is "can we talk to a healthy Appium
    /// right now", not a detailed health parse.
    public func checkServerReachable() async throws {
        let request = AppiumRequest(method: "GET", url: statusURL)
        let response: AppiumResponse
        do {
            response = try await statusTransport.send(request)
        } catch {
            throw DevicePreflightError.appiumUnreachable(
                endpoint: baseURL.absoluteString,
                detail: error.localizedDescription
            )
        }
        guard (200..<300).contains(response.statusCode) else {
            throw DevicePreflightError.appiumUnreachable(
                endpoint: baseURL.absoluteString,
                detail: "GET /status returned HTTP \(response.statusCode)"
            )
        }
    }

    /// Resolve the device and require a live tunnel. Returns the facts for
    /// downstream capability assembly.
    public func checkDeviceReachable(udid: String) throws -> PhysicalDeviceInfo {
        guard let info = infoResolver.resolve(udid: udid) else {
            throw DevicePreflightError.deviceNotFound(udid: udid)
        }
        guard info.isConnected else {
            throw DevicePreflightError.tunnelNotConnected(udid: udid, state: info.tunnelState)
        }
        return info
    }

    /// `{baseURL}/status`, built the same trailing-slash-tolerant way
    /// `AppiumClient` builds its request paths.
    private var statusURL: URL {
        let trimmed = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: trimmed + "/status") ?? baseURL
    }
}
