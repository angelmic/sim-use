// SPDX-License-Identifier: Apache-2.0
import AppiumCore
import Foundation
import SimUseCore
import XCTest

/// Protocol-level coverage for the generalized client: session URL
/// assembly, the W3C capabilities envelope, the generic `execute/sync`
/// primitive, and the endpoint/error handling that used to live in
/// TVOSBackend. Platform command semantics are the backends' job and are
/// not exercised here.
final class AppiumClientTests: XCTestCase {
    private let caps = AppiumCapabilities(
        platformName: "iOS",
        automationName: "XCUITest",
        udid: "00008140-00096D5C0CEA801C"
    )

    func testWithSessionCreatesRunsAndDeletesBuildingSessionURLs() async throws {
        let transport = MockTransport(responses: [
            sessionResponse(id: "session-1"),
            valueResponse("<AppiumAUT/>"),
            emptyOK(),
        ])
        let client = AppiumClient(baseURL: url("http://127.0.0.1:4723"), transport: transport)

        let source = try await client.withSession(capabilities: caps) { session in
            try await session.source()
        }

        XCTAssertEqual(source, "<AppiumAUT/>")
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map(\.method), ["POST", "GET", "DELETE"])
        XCTAssertEqual(requests.map { $0.url.path }, [
            "/session",
            "/session/session-1/source",
            "/session/session-1",
        ])
    }

    func testCreateSessionSendsCapabilitiesEnvelope() async throws {
        let transport = MockTransport(responses: [
            sessionResponse(id: "s"),
            valueResponse("<AppiumAUT/>"),
            emptyOK(),
        ])
        let client = AppiumClient(baseURL: url("http://127.0.0.1:4723"), transport: transport)

        _ = try await client.withSession(capabilities: caps) { try await $0.source() }

        let requests = await transport.recordedRequests()
        let body = try XCTUnwrap(requests.first?.body)
        let envelope = try JSONDecoder().decode(SessionEnvelopeProbe.self, from: body)
        XCTAssertEqual(envelope.capabilities.alwaysMatch.platformName, "iOS")
        XCTAssertEqual(envelope.capabilities.alwaysMatch.automationName, "XCUITest")
        XCTAssertEqual(envelope.capabilities.alwaysMatch.udid, "00008140-00096D5C0CEA801C")
        XCTAssertEqual(envelope.capabilities.firstMatch, [[:]])
    }

    func testGenericExecuteSendsScriptAndArgs() async throws {
        let transport = MockTransport(responses: [
            sessionResponse(id: "s"),
            emptyOK(), // execute/sync
            emptyOK(), // delete
        ])
        let client = AppiumClient(baseURL: url("http://127.0.0.1:4723"), transport: transport)

        try await client.withSession(capabilities: caps) { session in
            try await session.execute(script: "mobile: pressButton", args: [["name": "menu"]])
        }

        let requests = await transport.recordedRequests()
        let execute = try XCTUnwrap(requests.first { $0.url.path.hasSuffix("/execute/sync") })
        let body = try JSONDecoder().decode(ExecuteProbe.self, from: try XCTUnwrap(execute.body))
        XCTAssertEqual(body.script, "mobile: pressButton")
        XCTAssertEqual(body.args, [["name": "menu"]])
    }

    func testLegacyMobileTapScriptsAreRejectedBeforeTransport() async throws {
        for script in ["mobile: tap", "mobile: tapWithNumberOfTaps"] {
            let transport = MockTransport(responses: [
                sessionResponse(id: "s"),
                emptyOK(), // session cleanup after the expected rejection
                emptyOK(), // would be consumed only if execute/sync leaked
            ])
            let client = AppiumClient(baseURL: url("http://127.0.0.1:4723"), transport: transport)

            do {
                try await client.withSession(capabilities: caps) { session in
                    try await session.execute(script: script)
                }
                XCTFail("Expected \(script) to be rejected")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("W3C pointer actions"))
                XCTAssertTrue((error as? HintProviding)?.hint?.contains("/actions") == true)
            }

            let requests = await transport.recordedRequests()
            XCTAssertEqual(requests.map(\.method), ["POST", "DELETE"])
            XCTAssertEqual(requests.map { $0.url.path }, [
                "/session", "/session/s",
            ])
        }
    }

    func testTrailingSlashBaseURLStillBuildsCleanPaths() async throws {
        let transport = MockTransport(responses: [
            sessionResponse(id: "s7"),
            valueResponse("<AppiumAUT/>"),
            emptyOK(),
        ])
        let client = AppiumClient(baseURL: url("http://127.0.0.1:4723/"), transport: transport)

        _ = try await client.withSession(capabilities: caps) { try await $0.source() }

        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map { $0.url.absoluteString }, [
            "http://127.0.0.1:4723/session",
            "http://127.0.0.1:4723/session/s7/source",
            "http://127.0.0.1:4723/session/s7",
        ])
    }

    func testMalformedSessionIdRejectedBeforeAnyFurtherRequest() async throws {
        let transport = MockTransport(responses: [sessionResponse(id: "bad session id")])
        let client = AppiumClient(baseURL: url("http://127.0.0.1:4723"), transport: transport)

        do {
            _ = try await client.withSession(capabilities: caps) { try await $0.source() }
            XCTFail("Expected an invalid-response error")
        } catch let error as AppiumError {
            guard case .invalidResponse = error else {
                return XCTFail("Expected .invalidResponse, got \(error)")
            }
        }
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map(\.method), ["POST"])
    }

    func testConnectionFailureWrapsAsAppiumErrorWithHint() async {
        let transport = MockTransport(responses: [.failure(URLError(.cannotConnectToHost))])
        let client = AppiumClient(baseURL: url("http://127.0.0.1:4723"), transport: transport)

        do {
            _ = try await client.withSession(capabilities: caps) { try await $0.source() }
            XCTFail("Expected connection failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Cannot reach Appium"))
            XCTAssertTrue((error as? HintProviding)?.hint?.contains("appium --port 4723") == true)
        }
    }

    func testCreationFailureCanBeClassifiedWithoutWrappingOperationFailure() async {
        let createFailure = MockTransport(responses: [
            webdriverError("Unable to launch WebDriverAgent: test-without-building failed"),
        ])
        let firstClient = AppiumClient(baseURL: url("http://127.0.0.1:4723"), transport: createFailure)
        do {
            _ = try await firstClient.withSession(
                capabilities: caps,
                classifyCreationFailure: true
            ) { try await $0.source() }
            XCTFail("Expected classified session-creation failure")
        } catch let error as AppiumSessionCreationError {
            XCTAssertTrue(error.localizedDescription.contains("test-without-building failed"))
            XCTAssertTrue(error.underlying is AppiumError)
        } catch {
            XCTFail("Expected AppiumSessionCreationError, got \(error)")
        }

        let operationFailure = MockTransport(responses: [
            sessionResponse(id: "s"),
            webdriverError("source failed after session creation"),
            emptyOK(),
        ])
        let secondClient = AppiumClient(baseURL: url("http://127.0.0.1:4723"), transport: operationFailure)
        do {
            _ = try await secondClient.withSession(
                capabilities: caps,
                classifyCreationFailure: true
            ) { try await $0.source() }
            XCTFail("Expected operation failure")
        } catch is AppiumSessionCreationError {
            XCTFail("An operation failure must not be classified as session creation")
        } catch let error as AppiumError {
            guard case .webdriver = error else {
                return XCTFail("Expected .webdriver, got \(error)")
            }
        } catch {
            XCTFail("Expected AppiumError, got \(error)")
        }
    }

    func testLiveReadsEndpointFromEnvironment() throws {
        let client = try AppiumClient.live(environment: ["SIM_USE_APPIUM_URL": "http://10.0.0.2:4725"])
        XCTAssertEqual(client.baseURL.absoluteString, "http://10.0.0.2:4725")
    }

    func testLiveDefaultsToLocalhostWhenUnset() throws {
        let client = try AppiumClient.live(environment: [:])
        XCTAssertEqual(client.baseURL.absoluteString, "http://127.0.0.1:4723")
    }

    func testLiveRejectsInvalidEndpoint() {
        XCTAssertThrowsError(try AppiumClient.live(environment: ["SIM_USE_APPIUM_URL": "not a url"])) { error in
            guard case AppiumError.invalidEndpoint = error else {
                return XCTFail("Expected .invalidEndpoint, got \(error)")
            }
        }
    }

    private func url(_ string: String) -> URL { URL(string: string)! }
}

private actor MockTransport: AppiumTransport {
    private var responses: [Result<AppiumResponse, Error>]
    private var requests: [AppiumRequest] = []

    init(responses: [Result<AppiumResponse, Error>]) {
        self.responses = responses
    }

    func send(_ request: AppiumRequest) async throws -> AppiumResponse {
        requests.append(request)
        return try responses.removeFirst().get()
    }

    func recordedRequests() -> [AppiumRequest] { requests }
}

private struct ValueWrapper<Value: Encodable>: Encodable { let value: Value }

private func valueResponse<Value: Encodable>(_ value: Value) -> Result<AppiumResponse, Error> {
    let body = try! JSONEncoder().encode(ValueWrapper(value: value))
    return .success(AppiumResponse(statusCode: 200, body: body))
}

private func sessionResponse(id: String) -> Result<AppiumResponse, Error> {
    valueResponse(["sessionId": id])
}

private func emptyOK() -> Result<AppiumResponse, Error> {
    .success(AppiumResponse(statusCode: 200, body: Data(#"{"value":null}"#.utf8)))
}

private func webdriverError(_ message: String) -> Result<AppiumResponse, Error> {
    let escaped = message.replacingOccurrences(of: #"""#, with: #"\""#)
    return .success(AppiumResponse(
        statusCode: 500,
        body: Data(#"{"value":{"error":"unknown error","message":"\#(escaped)"}}"#.utf8)
    ))
}

private struct SessionEnvelopeProbe: Decodable {
    struct Caps: Decodable {
        struct AlwaysMatch: Decodable {
            let platformName: String
            let automationName: String
            let udid: String
            enum CodingKeys: String, CodingKey {
                case platformName
                case automationName = "appium:automationName"
                case udid = "appium:udid"
            }
        }
        let alwaysMatch: AlwaysMatch
        let firstMatch: [[String: String]]
    }
    let capabilities: Caps
}

private struct ExecuteProbe: Decodable {
    let script: String
    let args: [[String: String]]
}
