// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore

public enum TVOSAppiumError: Error, LocalizedError, HintProviding, Equatable {
    case invalidEndpoint(String)
    case connectionFailed(endpoint: String, message: String)
    case webdriver(status: Int, message: String)
    case invalidResponse(String)
    case invalidScreenshot

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint(let value):
            return "Invalid Appium endpoint: \(value)"
        case .connectionFailed(let endpoint, let message):
            return "Cannot reach Appium at \(endpoint): \(message)"
        case .webdriver(let status, let message):
            return "Appium WebDriver request failed (HTTP \(status)): \(message)"
        case .invalidResponse(let message):
            return "Appium returned an invalid WebDriver response: \(message)"
        case .invalidScreenshot:
            return "Appium returned screenshot data that was not valid base64."
        }
    }

    public var hint: String? {
        switch self {
        case .connectionFailed(let endpoint, _):
            let port = URL(string: endpoint)?.port ?? 4723
            return "Start Appium with `appium --port \(port)` and ensure the XCUITest driver is installed (`appium driver install xcuitest`)."
        case .webdriver:
            return "Run `appium driver doctor xcuitest`, then retry with the tvOS Simulator booted."
        case .invalidEndpoint, .invalidResponse, .invalidScreenshot:
            return nil
        }
    }
}

/// Small W3C WebDriver client for Appium's XCUITest tvOS surface. A fresh
/// session launches the requested bundle id, or attaches to the currently
/// foreground application when none is provided. It performs one command and
/// is always deleted before returning.
public struct TVOSAppiumClient: Sendable {
    public let baseURL: URL
    private let defaultBundleId: String?
    private let transport: any TVOSAppiumTransport

    public init(
        baseURL: URL,
        defaultBundleId: String? = nil,
        transport: any TVOSAppiumTransport = URLSessionTVOSAppiumTransport()
    ) {
        self.baseURL = baseURL
        self.defaultBundleId = Self.normalized(bundleId: defaultBundleId)
        self.transport = transport
    }

    public static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> TVOSAppiumClient {
        let raw = environment["SIM_USE_APPIUM_URL"] ?? "http://127.0.0.1:4723"
        guard let url = URL(string: raw), url.scheme != nil, url.host != nil else {
            throw TVOSAppiumError.invalidEndpoint(raw)
        }
        return TVOSAppiumClient(
            baseURL: url,
            defaultBundleId: environment["SIM_USE_TVOS_BUNDLE_ID"]
        )
    }

    func withSession<Result>(
        udid: String,
        bundleId: String? = nil,
        operation: (TVOSAppiumSession) async throws -> Result
    ) async throws -> Result {
        let resolvedBundleId = Self.normalized(bundleId: bundleId) ?? defaultBundleId
        let sessionID = try await createSession(udid: udid, bundleId: resolvedBundleId)
        let session = TVOSAppiumSession(id: sessionID, client: self)
        do {
            let result = try await operation(session)
            await deleteSessionBestEffort(sessionID)
            return result
        } catch {
            await deleteSessionBestEffort(sessionID)
            throw error
        }
    }

    /// Session teardown is cleanup, not the command's outcome: once the
    /// operation has produced a result, a failed DELETE must not turn the
    /// whole command into a failure (Appium's newCommandTimeout reaps the
    /// session regardless). Say so on stderr, then move on.
    private func deleteSessionBestEffort(_ sessionID: String) async {
        do {
            try await deleteSession(sessionID)
        } catch {
            FileHandle.standardError.write(Data(
                "warning: failed to close Appium session \(sessionID): \(error.localizedDescription)\n".utf8
            ))
        }
    }

    fileprivate func source(sessionID: String) async throws -> String {
        let response = try await send(method: "GET", path: "/session/\(sessionID)/source")
        return try decodeValue(String.self, from: response)
    }

    fileprivate func pressRemote(
        _ button: TVOSRemoteButton,
        sessionID: String
    ) async throws {
        let body = ExecuteRequest(
            script: "mobile: pressButton",
            args: [.init(name: button.appiumName)]
        )
        let response = try await send(
            method: "POST",
            path: "/session/\(sessionID)/execute/sync",
            body: try JSONEncoder().encode(body)
        )
        try validate(response)
    }

    fileprivate func screenshot(sessionID: String) async throws -> Data {
        let response = try await send(method: "GET", path: "/session/\(sessionID)/screenshot")
        let encoded = try decodeValue(String.self, from: response)
        guard let data = Data(base64Encoded: encoded) else {
            throw TVOSAppiumError.invalidScreenshot
        }
        return data
    }

    private func createSession(udid: String, bundleId: String?) async throws -> String {
        let body = SessionRequest(
            capabilities: .init(alwaysMatch: .init(udid: udid, bundleId: bundleId))
        )
        let response = try await send(
            method: "POST",
            path: "/session",
            body: try JSONEncoder().encode(body)
        )
        try validate(response)
        let envelope: SessionEnvelope
        do {
            envelope = try JSONDecoder().decode(SessionEnvelope.self, from: response.body)
        } catch {
            throw TVOSAppiumError.invalidResponse(error.localizedDescription)
        }
        guard let sessionID = envelope.sessionId ?? envelope.value?.sessionId,
              !sessionID.isEmpty
        else {
            throw TVOSAppiumError.invalidResponse("session response did not include a session id")
        }
        // The id is interpolated into every request path. Reject
        // URL-hostile characters here, deterministically — depending on
        // URL(string:) to fail is unreliable, since newer Foundation
        // percent-encodes invalid characters instead of returning nil.
        guard sessionID.range(of: "^[A-Za-z0-9._:-]+$", options: .regularExpression) != nil else {
            throw TVOSAppiumError.invalidResponse("session id contains unsupported characters: \(sessionID)")
        }
        return sessionID
    }

    private func deleteSession(_ sessionID: String) async throws {
        let response = try await send(method: "DELETE", path: "/session/\(sessionID)")
        try validate(response)
    }

    private func send(method: String, path: String, body: Data? = nil) async throws -> TVOSAppiumResponse {
        let suffix = path.hasPrefix("/") ? String(path.dropFirst()) : path
        // Defence in depth behind the createSession id validation: never
        // crash on a force-unwrap if an unvalidated value reaches a path.
        guard let url = URL(string: baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + suffix) else {
            throw TVOSAppiumError.invalidResponse("cannot build a request URL for path \(path)")
        }
        do {
            return try await transport.send(TVOSAppiumRequest(method: method, url: url, body: body))
        } catch let error as TVOSAppiumError {
            throw error
        } catch {
            throw TVOSAppiumError.connectionFailed(
                endpoint: baseURL.absoluteString,
                message: error.localizedDescription
            )
        }
    }

    private func validate(_ response: TVOSAppiumResponse) throws {
        let webdriverError = try? JSONDecoder().decode(WebDriverErrorEnvelope.self, from: response.body)
        if !(200..<300).contains(response.statusCode) || webdriverError?.value.error != nil {
            let message = webdriverError?.value.message ?? "unknown WebDriver error"
            throw TVOSAppiumError.webdriver(status: response.statusCode, message: message)
        }
    }

    private func decodeValue<Value: Decodable>(
        _ type: Value.Type,
        from response: TVOSAppiumResponse
    ) throws -> Value {
        try validate(response)
        do {
            return try JSONDecoder().decode(ValueEnvelope<Value>.self, from: response.body).value
        } catch {
            throw TVOSAppiumError.invalidResponse(error.localizedDescription)
        }
    }

    private static func normalized(bundleId: String?) -> String? {
        let value = bundleId?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }
}

struct TVOSAppiumSession: Sendable {
    let id: String
    let client: TVOSAppiumClient

    func source() async throws -> String {
        try await client.source(sessionID: id)
    }

    func pressRemote(_ button: TVOSRemoteButton) async throws {
        try await client.pressRemote(button, sessionID: id)
    }

    func screenshot() async throws -> Data {
        try await client.screenshot(sessionID: id)
    }
}

private struct SessionRequest: Encodable {
    struct Capabilities: Encodable {
        struct AlwaysMatch: Encodable {
            let platformName = "tvOS"
            let automationName = "XCUITest"
            let udid: String
            let bundleId: String?
            let autoLaunch: Bool
            let noReset = true
            let useNewWDA = false
            let newCommandTimeout = 300

            init(udid: String, bundleId: String?) {
                self.udid = udid
                self.bundleId = bundleId
                autoLaunch = bundleId != nil
            }

            enum CodingKeys: String, CodingKey {
                case platformName
                case automationName = "appium:automationName"
                case udid = "appium:udid"
                case bundleId = "appium:bundleId"
                case autoLaunch = "appium:autoLaunch"
                case noReset = "appium:noReset"
                case useNewWDA = "appium:useNewWDA"
                case newCommandTimeout = "appium:newCommandTimeout"
            }
        }

        let alwaysMatch: AlwaysMatch
        let firstMatch: [[String: String]] = [[:]]
    }

    let capabilities: Capabilities
}

private struct SessionEnvelope: Decodable {
    struct Value: Decodable {
        let sessionId: String?
    }

    let sessionId: String?
    let value: Value?
}

private struct ExecuteRequest: Encodable {
    struct Argument: Encodable {
        let name: String
    }

    let script: String
    let args: [Argument]
}

private struct ValueEnvelope<Value: Decodable>: Decodable {
    let value: Value
}

private struct WebDriverErrorEnvelope: Decodable {
    struct Value: Decodable {
        let error: String?
        let message: String?
    }

    let value: Value
}
