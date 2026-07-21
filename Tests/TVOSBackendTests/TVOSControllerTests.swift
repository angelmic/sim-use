// SPDX-License-Identifier: Apache-2.0
@testable import TVOSBackend
import Foundation
import SimUseCore
import XCTest

final class TVOSControllerTests: XCTestCase {
    func testDescribeUICreatesTVOSSessionAndRendersFocusedElement() async throws {
        let transport = MockTransport(responses: [
            response(value: SessionValue(sessionId: "session-1")),
            response(value: settingsSource(focusedLabel: "一般")),
            response(value: Optional<String>.none),
        ])
        let controller = makeController(transport: transport)

        let result = try await controller.describeUI(udid: tvosUDID, includeRaw: false)

        XCTAssertEqual(result.platform, .tvos)
        XCTAssertEqual(result.appPackage, "com.apple.TVSettings")
        XCTAssertNil(result.raw)
        XCTAssertEqual(result.entries.first(where: { $0.states.contains("focused") })?.label, "一般")
        XCTAssertTrue(result.outline.contains("[Top  y<120]"))
        XCTAssertTrue(result.outline.contains("[Content  y=120..960]"))
        XCTAssertTrue(result.outline.contains("[Bottom  y>=960]"))

        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map(\.method), ["POST", "GET", "DELETE"])
        XCTAssertEqual(requests.map { $0.url.path }, ["/session", "/session/session-1/source", "/session/session-1"])
        let capabilities = try JSONDecoder().decode(SessionRequest.self, from: try XCTUnwrap(requests.first?.body))
        XCTAssertEqual(capabilities.capabilities.alwaysMatch.platformName, "tvOS")
        XCTAssertEqual(capabilities.capabilities.alwaysMatch.automationName, "XCUITest")
        XCTAssertEqual(capabilities.capabilities.alwaysMatch.udid, tvosUDID)
        XCTAssertFalse(capabilities.capabilities.alwaysMatch.autoLaunch)
        XCTAssertNil(capabilities.capabilities.alwaysMatch.bundleId)
    }

    func testTargetBundleRelaunchesForegroundAppAfterColdWDAStart() async throws {
        let transport = MockTransport(responses: [
            response(value: SessionValue(sessionId: "session-target")),
            response(value: settingsSource(focusedLabel: "一般")),
            response(value: Optional<String>.none),
        ])
        let controller = makeController(transport: transport)

        _ = try await controller.describeUI(
            udid: tvosUDID,
            includeRaw: false,
            bundleId: "com.apple.TVSettings"
        )

        let requests = await transport.recordedRequests()
        let capabilities = try JSONDecoder().decode(
            SessionRequest.self,
            from: try XCTUnwrap(requests.first?.body)
        )
        XCTAssertEqual(capabilities.capabilities.alwaysMatch.bundleId, "com.apple.TVSettings")
        XCTAssertTrue(capabilities.capabilities.alwaysMatch.autoLaunch)
    }

    func testRemotePressMapsPlayPauseAndReportsFocusTransition() async throws {
        let transport = MockTransport(responses: [
            response(value: SessionValue(sessionId: "session-2")),
            response(value: settingsSource(focusedLabel: "一般")),
            response(value: Optional<String>.none),
            response(value: settingsSource(focusedLabel: "使用者和帳號")),
            response(value: Optional<String>.none),
        ])
        let controller = makeController(transport: transport)

        let result = try await controller.pressRemote(.playPause, udid: tvosUDID, settleDelay: 0)

        XCTAssertEqual(result.before?.label, "一般")
        XCTAssertEqual(result.after?.label, "使用者和帳號")
        let requests = await transport.recordedRequests()
        let execute = try XCTUnwrap(requests.first(where: { $0.url.path.hasSuffix("/execute/sync") }))
        let body = try JSONDecoder().decode(ExecuteRequest.self, from: try XCTUnwrap(execute.body))
        XCTAssertEqual(body.script, "mobile: pressButton")
        XCTAssertEqual(body.args, [.init(name: "playpause")])
        XCTAssertEqual(requests.last?.method, "DELETE")
    }

    func testDeleteFailureAfterSuccessfulOperationStillReturnsResult() async throws {
        let transport = MockTransport(responses: [
            response(value: SessionValue(sessionId: "session-5")),
            response(value: settingsSource(focusedLabel: "一般")),
            webdriverError(statusCode: 500, message: "delete blew up"),
        ])
        let controller = makeController(transport: transport)

        let result = try await controller.describeUI(udid: tvosUDID, includeRaw: false)

        XCTAssertEqual(result.appPackage, "com.apple.TVSettings")
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map(\.method), ["POST", "GET", "DELETE"])
    }

    func testScreenshotDecodesBase64AndClosesSession() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let transport = MockTransport(responses: [
            response(value: SessionValue(sessionId: "session-3")),
            response(value: png.base64EncodedString()),
            response(value: Optional<String>.none),
        ])
        let controller = makeController(transport: transport)

        let screenshot = try await controller.screenshot(udid: tvosUDID)
        let requests = await transport.recordedRequests()

        XCTAssertEqual(screenshot, png)
        XCTAssertEqual(requests.last?.method, "DELETE")
    }

    func testConnectionFailureIncludesAppiumSetupHint() async {
        let transport = MockTransport(responses: [.failure(URLError(.cannotConnectToHost))])
        let controller = makeController(transport: transport)

        do {
            _ = try await controller.describeUI(udid: tvosUDID, includeRaw: false)
            XCTFail("Expected Appium connection failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Cannot reach Appium"))
            XCTAssertTrue((error as? HintProviding)?.hint?.contains("appium --port 4723") == true)
        }
    }

    func testWebDriverFailureStillClosesSession() async {
        let transport = MockTransport(responses: [
            response(value: SessionValue(sessionId: "session-4")),
            webdriverError(statusCode: 500, message: "source unavailable"),
            response(value: Optional<String>.none),
        ])
        let controller = makeController(transport: transport)

        do {
            _ = try await controller.describeUI(udid: tvosUDID, includeRaw: false)
            XCTFail("Expected Appium WebDriver failure")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "Appium WebDriver request failed (HTTP 500): source unavailable"
            )
        }

        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map(\.method), ["POST", "GET", "DELETE"])
        XCTAssertEqual(requests.last?.url.path, "/session/session-4")
    }

    private let tvosUDID = "8737CB71-6462-41EC-B13E-E7C5E8F033E9"

    private func makeController(transport: MockTransport) -> TVOSController {
        TVOSController(client: TVOSAppiumClient(
            baseURL: URL(string: "http://127.0.0.1:4723")!,
            transport: transport
        ))
    }
}

private actor MockTransport: TVOSAppiumTransport {
    private var responses: [Result<TVOSAppiumResponse, Error>]
    private var requests: [TVOSAppiumRequest] = []

    init(responses: [Result<TVOSAppiumResponse, Error>]) {
        self.responses = responses
    }

    func send(_ request: TVOSAppiumRequest) async throws -> TVOSAppiumResponse {
        requests.append(request)
        return try responses.removeFirst().get()
    }

    func recordedRequests() -> [TVOSAppiumRequest] {
        requests
    }
}

private struct ValueEnvelope<Value: Encodable>: Encodable {
    let value: Value
}

private struct SessionValue: Codable {
    let sessionId: String
}

private struct SessionRequest: Decodable {
    struct Capabilities: Decodable {
        struct AlwaysMatch: Decodable {
            let platformName: String
            let automationName: String
            let udid: String
            let autoLaunch: Bool
            let bundleId: String?

            enum CodingKeys: String, CodingKey {
                case platformName
                case automationName = "appium:automationName"
                case udid = "appium:udid"
                case autoLaunch = "appium:autoLaunch"
                case bundleId = "appium:bundleId"
            }
        }

        let alwaysMatch: AlwaysMatch
    }

    let capabilities: Capabilities
}

private struct ExecuteRequest: Decodable {
    struct Argument: Codable, Equatable {
        let name: String
    }

    let script: String
    let args: [Argument]
}

private func response<Value: Encodable>(value: Value) -> Result<TVOSAppiumResponse, Error> {
    let body = try! JSONEncoder().encode(ValueEnvelope(value: value))
    return .success(TVOSAppiumResponse(statusCode: 200, body: body))
}

private func webdriverError(
    statusCode: Int,
    message: String
) -> Result<TVOSAppiumResponse, Error> {
    let body = """
    {"value":{"error":"unknown error","message":"\(message)"}}
    """
    return .success(TVOSAppiumResponse(statusCode: statusCode, body: Data(body.utf8)))
}

private func settingsSource(focusedLabel: String) -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <AppiumAUT>
      <XCUIElementTypeApplication type="XCUIElementTypeApplication" name="設定" label="設定" enabled="true" visible="true" focused="false" x="0" y="0" width="1920" height="1080" bundleId="com.apple.TVSettings">
        <XCUIElementTypeStaticText type="XCUIElementTypeStaticText" name="設定" label="設定" enabled="true" visible="true" focused="false" x="80" y="20" width="400" height="80" />
        <XCUIElementTypeCell type="XCUIElementTypeCell" name="一般" label="一般" enabled="true" visible="true" focused="\(focusedLabel == "一般")" x="1060" y="191" width="780" height="66" />
        <XCUIElementTypeCell type="XCUIElementTypeCell" name="使用者和帳號" label="使用者和帳號" enabled="true" visible="true" focused="\(focusedLabel == "使用者和帳號")" x="1060" y="269" width="780" height="66" />
        <XCUIElementTypeButton type="XCUIElementTypeButton" name="完成" label="完成" enabled="true" visible="true" focused="false" x="1500" y="980" width="300" height="80" />
      </XCUIElementTypeApplication>
    </AppiumAUT>
    """
}
