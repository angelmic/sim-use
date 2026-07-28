// SPDX-License-Identifier: Apache-2.0
import AppiumCore
import Foundation
import XCTest

/// Records requests and replays a scripted response queue. Shared by the
/// preflight and controller suites so both reason about one transport.
actor MockTransport: AppiumTransport {
    private var responses: [Result<AppiumResponse, Error>]
    private(set) var requests: [AppiumRequest] = []

    init(responses: [Result<AppiumResponse, Error>]) {
        self.responses = responses
    }

    func send(_ request: AppiumRequest) async throws -> AppiumResponse {
        requests.append(request)
        guard !responses.isEmpty else {
            throw AppiumError.invalidResponse("MockTransport ran out of scripted responses")
        }
        return try responses.removeFirst().get()
    }

    func recordedRequests() -> [AppiumRequest] { requests }
}

private struct ValueWrapper<Value: Encodable>: Encodable { let value: Value }

/// `{"value": <value>}` — the W3C success envelope.
func valueResponse<Value: Encodable>(_ value: Value) -> Result<AppiumResponse, Error> {
    let body = try! JSONEncoder().encode(ValueWrapper(value: value))
    return .success(AppiumResponse(statusCode: 200, body: body))
}

/// `{"value": {"sessionId": id}}` for the session-create POST.
func sessionResponse(id: String = "session-1") -> Result<AppiumResponse, Error> {
    valueResponse(["sessionId": id])
}

/// `{"value": {"element-...": id}}` for find/active-element GETs.
func elementResponse(id: String = "elem-1") -> Result<AppiumResponse, Error> {
    valueResponse(["element-6066-11e4-a52e-4f735466cecf": id])
}

/// `{"value": null}` for commands that return no payload (actions, sendKeys,
/// execute/sync, DELETE).
func emptyOK() -> Result<AppiumResponse, Error> {
    .success(AppiumResponse(statusCode: 200, body: Data(#"{"value":null}"#.utf8)))
}

/// `GET /status` health payload.
func statusOK() -> Result<AppiumResponse, Error> {
    .success(AppiumResponse(statusCode: 200, body: Data(#"{"value":{"ready":true}}"#.utf8)))
}

/// A W3C error envelope returned by Appium.
func webdriverError(_ message: String) -> Result<AppiumResponse, Error> {
    let escaped = message.replacingOccurrences(of: #"""#, with: #"\""#)
    return .success(AppiumResponse(
        statusCode: 500,
        body: Data(#"{"value":{"error":"unknown error","message":"\#(escaped)"}}"#.utf8)
    ))
}

/// A throwaway home directory so OutlineCache writes/reads stay off the real
/// `~/.sim-use`. Caller deletes it in tearDown.
func makeTempHome() -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("device-backend-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
