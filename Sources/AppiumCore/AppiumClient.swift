// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore

/// Marks the one failure phase that is safe for a caller to retry with a
/// different WDA startup strategy. The original error remains available so
/// callers that do not recover can preserve its exact user-facing message
/// and `HintProviding` conformance.
public struct AppiumSessionCreationError: Error, LocalizedError, @unchecked Sendable {
    public let underlying: Error

    public init(underlying: Error) {
        self.underlying = underlying
    }

    public var errorDescription: String? { underlying.localizedDescription }
}

/// Small W3C WebDriver client for Appium's XCUITest surface. A fresh session
/// is created from the caller's `AppiumCapabilities`, runs one operation, and
/// is always deleted before returning. It carries no platform knowledge:
/// capability assembly and command semantics (which `mobile:` scripts, which
/// buttons) belong to the backends that drive it.
public struct AppiumClient: Sendable {
    public let baseURL: URL
    private let transport: any AppiumTransport

    public init(
        baseURL: URL,
        transport: any AppiumTransport = URLSessionAppiumTransport()
    ) {
        self.baseURL = baseURL
        self.transport = transport
    }

    public static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> AppiumClient {
        let raw = environment["SIM_USE_APPIUM_URL"] ?? "http://127.0.0.1:4723"
        guard let url = URL(string: raw), url.scheme != nil, url.host != nil else {
            throw AppiumError.invalidEndpoint(raw)
        }
        return AppiumClient(baseURL: url)
    }

    public func withSession<Result>(
        capabilities: AppiumCapabilities,
        classifyCreationFailure: Bool = false,
        operation: (AppiumSession) async throws -> Result
    ) async throws -> Result {
        let sessionID: String
        do {
            sessionID = try await createSession(capabilities: capabilities)
        } catch {
            if classifyCreationFailure {
                throw AppiumSessionCreationError(underlying: error)
            }
            throw error
        }
        let session = AppiumSession(id: sessionID, client: self)
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

    /// Generic `execute/sync`: the pure-protocol primitive backends build
    /// their platform verbs on (e.g. tvOS `mobile: pressButton`). Coordinate
    /// tap scripts are deliberately rejected: XCUITest maps them to WDA's
    /// legacy `/wda/tap` route, which can return success without delivering
    /// an input event. Call `performActions` for every touch gesture.
    fileprivate func execute(
        script: String,
        args: [[String: String]],
        sessionID: String
    ) async throws {
        if script == "mobile: tap" || script == "mobile: tapWithNumberOfTaps" {
            throw AppiumError.unsupportedGestureScript(script)
        }
        let response = try await send(
            method: "POST",
            path: "/session/\(sessionID)/execute/sync",
            body: try JSONEncoder().encode(ExecuteRequest(script: script, args: args))
        )
        try validate(response)
    }

    fileprivate func screenshot(sessionID: String) async throws -> Data {
        let response = try await send(method: "GET", path: "/session/\(sessionID)/screenshot")
        let encoded = try decodeValue(String.self, from: response)
        guard let data = Data(base64Encoded: encoded) else {
            throw AppiumError.invalidScreenshot
        }
        return data
    }

    fileprivate func findElement(
        className: String,
        sessionID: String
    ) async throws -> String {
        let body = FindElementRequest(using: "class name", value: className)
        let response = try await send(
            method: "POST",
            path: "/session/\(sessionID)/element",
            body: try JSONEncoder().encode(body)
        )
        return try elementID(from: response)
    }

    fileprivate func activeElement(sessionID: String) async throws -> String {
        let response = try await send(method: "GET", path: "/session/\(sessionID)/element/active")
        return try elementID(from: response)
    }

    /// Extract the element id from a W3C element response. The id is wrapped
    /// under a spec-defined key (`element-6066-...`), so take the first
    /// value and reject URL-hostile ids before they reach a request path.
    private func elementID(from response: AppiumResponse) throws -> String {
        let element = try decodeValue([String: String].self, from: response)
        guard let elementID = element.values.first, !elementID.isEmpty,
              elementID.range(of: "^[A-Za-z0-9._:-]+$", options: .regularExpression) != nil
        else {
            throw AppiumError.invalidResponse("element response did not include a usable element id")
        }
        return elementID
    }

    fileprivate func sendKeys(
        _ text: String,
        elementID: String,
        sessionID: String
    ) async throws {
        let response = try await send(
            method: "POST",
            path: "/session/\(sessionID)/element/\(elementID)/value",
            body: try JSONEncoder().encode(SendKeysRequest(text: text))
        )
        try validate(response)
    }

    fileprivate func clear(
        elementID: String,
        sessionID: String
    ) async throws {
        let response = try await send(
            method: "POST",
            path: "/session/\(sessionID)/element/\(elementID)/clear"
        )
        try validate(response)
    }

    /// W3C `POST /actions` with a single pointer input source. The generic
    /// primitive iOS tap/swipe build on; the step list is the caller's
    /// concern. Coordinates round to integers as the spec requires.
    fileprivate func performActions(
        pointerType: String,
        actions: [PointerAction],
        sessionID: String
    ) async throws {
        let items = actions.map { action -> ActionItemPayload in
            switch action {
            case .moveTo(let x, let y, let durationMs):
                return ActionItemPayload(type: "pointerMove", duration: durationMs, x: Int(x.rounded()), y: Int(y.rounded()), button: nil)
            case .down:
                return ActionItemPayload(type: "pointerDown", duration: nil, x: nil, y: nil, button: 0)
            case .up:
                return ActionItemPayload(type: "pointerUp", duration: nil, x: nil, y: nil, button: 0)
            case .pause(let durationMs):
                return ActionItemPayload(type: "pause", duration: durationMs, x: nil, y: nil, button: nil)
            }
        }
        let request = ActionsRequest(actions: [
            PointerSourcePayload(id: "finger1", parameters: ["pointerType": pointerType], actions: items)
        ])
        let response = try await send(
            method: "POST",
            path: "/session/\(sessionID)/actions",
            body: try JSONEncoder().encode(request)
        )
        try validate(response)
    }

    private func createSession(capabilities: AppiumCapabilities) async throws -> String {
        let response = try await send(
            method: "POST",
            path: "/session",
            body: try JSONEncoder().encode(SessionRequest(capabilities: capabilities))
        )
        try validate(response)
        let envelope: SessionEnvelope
        do {
            envelope = try JSONDecoder().decode(SessionEnvelope.self, from: response.body)
        } catch {
            throw AppiumError.invalidResponse(error.localizedDescription)
        }
        guard let sessionID = envelope.sessionId ?? envelope.value?.sessionId,
              !sessionID.isEmpty
        else {
            throw AppiumError.invalidResponse("session response did not include a session id")
        }
        // The id is interpolated into every request path. Reject
        // URL-hostile characters here, deterministically — depending on
        // URL(string:) to fail is unreliable, since newer Foundation
        // percent-encodes invalid characters instead of returning nil.
        guard sessionID.range(of: "^[A-Za-z0-9._:-]+$", options: .regularExpression) != nil else {
            throw AppiumError.invalidResponse("session id contains unsupported characters: \(sessionID)")
        }
        return sessionID
    }

    private func deleteSession(_ sessionID: String) async throws {
        let response = try await send(method: "DELETE", path: "/session/\(sessionID)")
        try validate(response)
    }

    private func send(method: String, path: String, body: Data? = nil) async throws -> AppiumResponse {
        let suffix = path.hasPrefix("/") ? String(path.dropFirst()) : path
        // Defence in depth behind the createSession id validation: never
        // crash on a force-unwrap if an unvalidated value reaches a path.
        guard let url = URL(string: baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + suffix) else {
            throw AppiumError.invalidResponse("cannot build a request URL for path \(path)")
        }
        do {
            return try await transport.send(AppiumRequest(method: method, url: url, body: body))
        } catch let error as AppiumError {
            throw error
        } catch {
            throw AppiumError.connectionFailed(
                endpoint: baseURL.absoluteString,
                message: error.localizedDescription
            )
        }
    }

    private func validate(_ response: AppiumResponse) throws {
        let webdriverError = try? JSONDecoder().decode(WebDriverErrorEnvelope.self, from: response.body)
        if !(200..<300).contains(response.statusCode) || webdriverError?.value.error != nil {
            let message = webdriverError?.value.message ?? "unknown WebDriver error"
            throw AppiumError.webdriver(status: response.statusCode, message: message)
        }
    }

    private func decodeValue<Value: Decodable>(
        _ type: Value.Type,
        from response: AppiumResponse
    ) throws -> Value {
        try validate(response)
        do {
            return try JSONDecoder().decode(ValueEnvelope<Value>.self, from: response.body).value
        } catch {
            throw AppiumError.invalidResponse(error.localizedDescription)
        }
    }
}

/// One claimed Appium session. Exposes the generic WebDriver commands; the
/// backend composes them (and `execute`) into platform verbs.
public struct AppiumSession: Sendable {
    let id: String
    let client: AppiumClient

    public func source() async throws -> String {
        try await client.source(sessionID: id)
    }

    public func execute(script: String, args: [[String: String]] = []) async throws {
        try await client.execute(script: script, args: args, sessionID: id)
    }

    public func screenshot() async throws -> Data {
        try await client.screenshot(sessionID: id)
    }

    public func findElement(className: String) async throws -> String {
        try await client.findElement(className: className, sessionID: id)
    }

    /// The element that currently has keyboard focus (`GET /element/active`).
    /// The target `type` sends text to when no explicit element is given.
    public func activeElement() async throws -> String {
        try await client.activeElement(sessionID: id)
    }

    public func sendKeys(_ text: String, elementID: String) async throws {
        try await client.sendKeys(text, elementID: elementID, sessionID: id)
    }

    /// Clear an editable element through the W3C element endpoint.
    public func clear(elementID: String) async throws {
        try await client.clear(elementID: elementID, sessionID: id)
    }

    /// Dispatch a W3C pointer gesture (tap / swipe / hold) built from
    /// `PointerAction` steps. See `PointerAction.tap` / `.swipe`.
    public func performPointerActions(
        _ actions: [PointerAction],
        pointerType: String = "touch"
    ) async throws {
        try await client.performActions(pointerType: pointerType, actions: actions, sessionID: id)
    }
}

private struct SessionRequest: Encodable {
    struct Envelope: Encodable {
        let alwaysMatch: AppiumCapabilities
        let firstMatch: [[String: String]] = [[:]]
    }

    let capabilities: Envelope

    init(capabilities: AppiumCapabilities) {
        self.capabilities = Envelope(alwaysMatch: capabilities)
    }
}

private struct SessionEnvelope: Decodable {
    struct Value: Decodable {
        let sessionId: String?
    }

    let sessionId: String?
    let value: Value?
}

private struct ExecuteRequest: Encodable {
    let script: String
    let args: [[String: String]]
}

private struct FindElementRequest: Encodable {
    let using: String
    let value: String
}

private struct SendKeysRequest: Encodable {
    let text: String
}

/// W3C `POST /actions` request body: one pointer input source whose steps
/// are the pointerMove / pointerDown / pointerUp / pause items. Optional
/// fields use `encodeIfPresent` so a pointerDown never sends a null `x`.
private struct ActionsRequest: Encodable {
    let actions: [PointerSourcePayload]
}

private struct PointerSourcePayload: Encodable {
    let type = "pointer"
    let id: String
    let parameters: [String: String]
    let actions: [ActionItemPayload]
}

private struct ActionItemPayload: Encodable {
    let type: String
    let duration: Int?
    let x: Int?
    let y: Int?
    let button: Int?

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(duration, forKey: .duration)
        try container.encodeIfPresent(x, forKey: .x)
        try container.encodeIfPresent(y, forKey: .y)
        try container.encodeIfPresent(button, forKey: .button)
    }

    enum CodingKeys: String, CodingKey {
        case type, duration, x, y, button
    }
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
