// SPDX-License-Identifier: Apache-2.0
import AppiumCore
import Foundation
import SimUseCore
import XCTest
@testable import DeviceBackend

/// Drives each iOS device verb through a scripted transport and asserts the
/// exact WebDriver request sequence and W3C payloads — the observable
/// contract the real WebDriverAgent sees.
final class AppleDeviceControllerTests: XCTestCase {
    private let iPhoneUDID = "00008140-00096D5C0CEA801C"
    private let tvUDID = "c311e5afe90ee702b80e8b64e1e12796e04e63a0"
    private var homesToClean: [URL] = []

    private let source = """
    <XCUIElementTypeApplication type="XCUIElementTypeApplication" name="CATCHPLAY+" label="CATCHPLAY+" bundleId="com.catchplay.app" x="0" y="0" width="393" height="852">
      <XCUIElementTypeSearchField type="XCUIElementTypeSearchField" name="searchField" label="Search" value="" enabled="true" visible="true" x="20" y="80" width="353" height="36"/>
    </XCUIElementTypeApplication>
    """

    override func tearDown() {
        for home in homesToClean { try? FileManager.default.removeItem(at: home) }
        homesToClean = []
        super.tearDown()
    }

    private func iPhone(state: String = "connected") -> Device {
        Device(udid: iPhoneUDID, name: "CP 16 Pro Max", platform: .ios, state: state, runtime: "iOS 18.7.8", target: .device)
    }

    private func makeController(
        _ responses: [Result<AppiumResponse, Error>],
        device: Device
    ) -> (AppleDeviceController, MockTransport) {
        let transport = MockTransport(responses: responses)
        let base = URL(string: "http://127.0.0.1:4788")!
        let home = makeTempHome()
        homesToClean.append(home)
        let controller = AppleDeviceController(
            client: AppiumClient(baseURL: base, transport: transport),
            preflight: DevicePreflight(
                baseURL: base,
                statusTransport: transport,
                infoResolver: DeviceInfoResolver(provider: { [device] })
            ),
            config: DeviceCapabilityConfig(),
            cacheHome: home
        )
        return (controller, transport)
    }

    // MARK: - tap

    func testTapPointSendsW3CActionsAndDeletesSession() async throws {
        let (controller, transport) = makeController(
            [statusOK(), sessionResponse(), emptyOK(), emptyOK()],
            device: iPhone()
        )
        let point = try await controller.tap(udid: iPhoneUDID, target: .point(x: 120, y: 340))
        XCTAssertEqual(point.x, 120)
        XCTAssertEqual(point.y, 340)

        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map(\.method), ["GET", "POST", "POST", "DELETE"])
        XCTAssertEqual(requests.map { $0.url.path }, [
            "/status", "/session", "/session/session-1/actions", "/session/session-1",
        ])

        let actions = try decodeActions(requests[2])
        let source = try XCTUnwrap(actions.actions.first)
        XCTAssertEqual(source.type, "pointer")
        XCTAssertEqual(source.parameters["pointerType"], "touch")
        XCTAssertEqual(source.actions.map(\.type), ["pointerMove", "pointerDown", "pointerUp"])
        XCTAssertEqual(source.actions[0].x, 120)
        XCTAssertEqual(source.actions[0].y, 340)
        XCTAssertEqual(source.actions[1].button, 0)
    }

    func testTapWithHoldInsertsPause() async throws {
        let (controller, transport) = makeController(
            [statusOK(), sessionResponse(), emptyOK(), emptyOK()],
            device: iPhone()
        )
        _ = try await controller.tap(udid: iPhoneUDID, target: .point(x: 10, y: 20), holdMs: 50)
        let requests = await transport.recordedRequests()
        let actions = try decodeActions(requests[2])
        let items = try XCTUnwrap(actions.actions.first?.actions)
        XCTAssertEqual(items.map(\.type), ["pointerMove", "pointerDown", "pause", "pointerUp"])
        XCTAssertEqual(items[2].duration, 50)
    }

    func testTapSelectorResolvesFreshSourceThenTapsCenter() async throws {
        let (controller, transport) = makeController(
            [statusOK(), sessionResponse(), valueResponse(source), emptyOK(), emptyOK()],
            device: iPhone()
        )
        let point = try await controller.tap(
            udid: iPhoneUDID,
            target: .selector(DeviceSelector(id: "searchField"))
        )
        // Center of (20,80 353x36) = (196.5, 98) → rounded on the wire.
        XCTAssertEqual(point.x, 196.5, accuracy: 0.001)
        XCTAssertEqual(point.y, 98, accuracy: 0.001)

        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map { $0.url.path }, [
            "/status", "/session", "/session/session-1/source", "/session/session-1/actions", "/session/session-1",
        ])
        let actions = try decodeActions(requests[3])
        XCTAssertEqual(actions.actions.first?.actions.first?.x, 197) // 196.5 rounds to 197
        XCTAssertEqual(actions.actions.first?.actions.first?.y, 98)
    }

    func testTapForwardsBundleIdToSessionCaps() async throws {
        let (controller, transport) = makeController(
            [statusOK(), sessionResponse(), emptyOK(), emptyOK()],
            device: iPhone()
        )
        _ = try await controller.tap(udid: iPhoneUDID, target: .point(x: 1, y: 2), bundleId: "com.example.app")
        let requests = await transport.recordedRequests()
        // Session POST is index 1 (index 0 is the preflight GET /status).
        let caps = try JSONDecoder().decode(SessionCapsProbe.self, from: try XCTUnwrap(requests[1].body))
        XCTAssertEqual(caps.capabilities.alwaysMatch.bundleId, "com.example.app")
        XCTAssertEqual(caps.capabilities.alwaysMatch.autoLaunch, true)
        XCTAssertEqual(caps.capabilities.alwaysMatch.noReset, true)
    }

    // MARK: - swipe

    func testSwipeSendsMoveDownMoveUp() async throws {
        let (controller, transport) = makeController(
            [statusOK(), sessionResponse(), emptyOK(), emptyOK()],
            device: iPhone()
        )
        try await controller.swipe(
            udid: iPhoneUDID,
            from: (x: 10, y: 20), to: (x: 30, y: 400), durationMs: 250
        )
        let requests = await transport.recordedRequests()
        let actions = try decodeActions(requests[2])
        let items = try XCTUnwrap(actions.actions.first?.actions)
        XCTAssertEqual(items.map(\.type), ["pointerMove", "pointerDown", "pointerMove", "pointerUp"])
        XCTAssertEqual(items[0].x, 10)
        XCTAssertEqual(items[2].x, 30)
        XCTAssertEqual(items[2].y, 400)
        XCTAssertEqual(items[2].duration, 250)
    }

    // MARK: - describe-ui

    func testDescribeUIRendersAndWritesAliasCache() async throws {
        let (controller, transport) = makeController(
            [statusOK(), sessionResponse(), valueResponse(source), emptyOK()],
            device: iPhone()
        )
        let result = try await controller.describeUI(udid: iPhoneUDID, includeRaw: false)
        XCTAssertEqual(result.platform, .ios)
        XCTAssertEqual(result.entries.count, 1)
        XCTAssertEqual(result.entries.first?.uniqueId, "searchField")

        // The cache write lets `tap @1` resolve later without a live tree.
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map { $0.url.path }, [
            "/status", "/session", "/session/session-1/source", "/session/session-1",
        ])
    }

    // MARK: - type / paste

    func testTypeSendsKeysToActiveElement() async throws {
        let (controller, transport) = makeController(
            [statusOK(), sessionResponse(), elementResponse(id: "field-9"), emptyOK(), emptyOK()],
            device: iPhone()
        )
        try await controller.type(udid: iPhoneUDID, text: "Inception")
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map { $0.url.path }, [
            "/status", "/session", "/session/session-1/element/active",
            "/session/session-1/element/field-9/value", "/session/session-1",
        ])
        let body = try JSONDecoder().decode(SendKeysProbe.self, from: try XCTUnwrap(requests[3].body))
        XCTAssertEqual(body.text, "Inception")
    }

    func testPasteSeedsPasteboardThenSendsKeys() async throws {
        let (controller, transport) = makeController(
            [statusOK(), sessionResponse(), emptyOK(), elementResponse(id: "field-9"), emptyOK(), emptyOK()],
            device: iPhone()
        )
        try await controller.paste(udid: iPhoneUDID, text: "hi")
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map { $0.url.path }, [
            "/status", "/session", "/session/session-1/execute/sync",
            "/session/session-1/element/active", "/session/session-1/element/field-9/value", "/session/session-1",
        ])
        let execute = try JSONDecoder().decode(ExecuteProbe.self, from: try XCTUnwrap(requests[2].body))
        XCTAssertEqual(execute.script, "mobile: setPasteboard")
        XCTAssertEqual(execute.args.first?["encoding"], "base64")
        XCTAssertEqual(execute.args.first?["content"], Data("hi".utf8).base64EncodedString())
    }

    // MARK: - screenshot

    func testScreenshotDecodesBase64PNG() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) // PNG magic
        let (controller, transport) = makeController(
            [statusOK(), sessionResponse(), valueResponse(png.base64EncodedString()), emptyOK()],
            device: iPhone()
        )
        let data = try await controller.screenshot(udid: iPhoneUDID)
        XCTAssertEqual(data, png)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map { $0.url.path }, [
            "/status", "/session", "/session/session-1/screenshot", "/session/session-1",
        ])
    }

    // MARK: - tvOS family guard

    func testCoordinateVerbsRejectTVOSDeviceBeforeSession() async {
        let tv = Device(udid: tvUDID, name: "TV", platform: .tvos, state: "connected", runtime: "tvOS 26.5", target: .device)
        let (controller, transport) = makeController([statusOK()], device: tv)
        do {
            _ = try await controller.tap(udid: tvUDID, target: .point(x: 1, y: 2))
            XCTFail("expected TVOSCapabilityError")
        } catch is TVOSCapabilityError {
            // The reject happens after preflight but before any session POST.
            let requests = await transport.recordedRequests()
            XCTAssertEqual(requests.map(\.method), ["GET"]) // /status only
        } catch {
            XCTFail("expected TVOSCapabilityError, got \(error)")
        }
    }

    // MARK: - Probes

    private func decodeActions(_ request: AppiumRequest) throws -> ActionsProbe {
        try JSONDecoder().decode(ActionsProbe.self, from: try XCTUnwrap(request.body))
    }

    private struct ActionsProbe: Decodable {
        struct Source: Decodable {
            let type: String
            let id: String
            let parameters: [String: String]
            let actions: [Item]
        }
        struct Item: Decodable {
            let type: String
            let duration: Int?
            let x: Int?
            let y: Int?
            let button: Int?
        }
        let actions: [Source]
    }

    private struct SessionCapsProbe: Decodable {
        struct Caps: Decodable {
            struct AlwaysMatch: Decodable {
                let bundleId: String?
                let autoLaunch: Bool?
                let noReset: Bool?
                enum CodingKeys: String, CodingKey {
                    case bundleId = "appium:bundleId"
                    case autoLaunch = "appium:autoLaunch"
                    case noReset = "appium:noReset"
                }
            }
            let alwaysMatch: AlwaysMatch
        }
        let capabilities: Caps
    }

    private struct SendKeysProbe: Decodable { let text: String }
    private struct ExecuteProbe: Decodable {
        let script: String
        let args: [[String: String]]
    }
}
