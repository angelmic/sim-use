// SPDX-License-Identifier: Apache-2.0
@testable import TVOSBackend
import AppiumCore
import DeviceBackend
import Foundation
import SimUseCore
import XCTest

/// The physical Apple TV path: device preflight + xcodebuild-flow caps, no
/// HID / simctl shortcuts, and the tvOS ≤16 `ui` fail-fast.
final class TVOSDeviceControllerTests: XCTestCase {
    private let tvUDID = "c311e5afe90ee702b80e8b64e1e12796e04e63a0"

    private func device(major: Int, state: String = "connected") -> Device {
        Device(udid: tvUDID, name: "辦公桌tv理查", platform: .tvos, state: state, runtime: "tvOS \(major).5", target: .device)
    }

    private func makeController(
        _ responses: [Result<AppiumResponse, Error>],
        device: Device
    ) -> (TVOSDeviceController, MockTransport) {
        let transport = MockTransport(responses: responses)
        let base = URL(string: "http://127.0.0.1:4799")!
        let controller = TVOSDeviceController(
            client: AppiumClient(baseURL: base, transport: transport),
            preflight: DevicePreflight(
                baseURL: base,
                statusTransport: transport,
                infoResolver: DeviceInfoResolver(provider: { [device] })
            ),
            config: DeviceCapabilityConfig()
        )
        return (controller, transport)
    }

    func testModernDeviceDescribeUIUsesXcodebuildCaps() async throws {
        let (controller, transport) = makeController(
            [statusOK(), sessionResponse(), sourceResponse(focusedLabel: "TestFlight"), emptyOK()],
            device: device(major: 26)
        )
        let result = try await controller.describeUI(udid: tvUDID, includeRaw: false)
        XCTAssertEqual(result.platform, .tvos)
        XCTAssertEqual(result.entries.first(where: { $0.states.contains("focused") })?.label, "TestFlight")

        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map { $0.url.path }, [
            "/status", "/session", "/session/session-1/source", "/session/session-1",
        ])
        // The session must carry the xcodebuild-flow caps, not Simulator ones.
        let caps = try JSONDecoder().decode(CapsProbe.self, from: try XCTUnwrap(requests[1].body))
        XCTAssertEqual(caps.capabilities.alwaysMatch.platformName, "tvOS")
        XCTAssertEqual(caps.capabilities.alwaysMatch.xcodeOrgId, "MKK9DM2XD9")
        XCTAssertEqual(caps.capabilities.alwaysMatch.updatedWDABundleId, "com.catchplay.wda")
    }

    func testClassicDeviceUIFailsFastBeforeSession() async {
        let (controller, transport) = makeController(
            [statusOK()], // preflight passes; the ≤16 gate throws before any session
            device: device(major: 16)
        )
        do {
            _ = try await controller.describeUI(udid: tvUDID, includeRaw: false)
            XCTFail("expected TVOSDeviceUIUnsupportedError")
        } catch let error as TVOSDeviceUIUnsupportedError {
            XCTAssertEqual(error.osMajorVersion, 16)
            XCTAssertTrue((error.hint ?? "").contains("tvos remote"))
        } catch {
            XCTFail("expected TVOSDeviceUIUnsupportedError, got \(error)")
        }
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map(\.method), ["GET"], "no session may be opened for the ≤16 ui reject")
    }

    func testModernRemotePressUsesAppiumNotHID() async throws {
        // Even with the HID bridge wired (Simulator fast path), a physical
        // device must go through Appium — HID can't move a real TV's focus.
        TVOSHIDBridge.pressKey = { _, _ in XCTFail("device remote must not use HID") }
        defer { TVOSHIDBridge.pressKey = nil }

        let (controller, transport) = makeController(
            [statusOK(), sessionResponse(), emptyOK(), emptyOK()],
            device: device(major: 26)
        )
        let result = try await controller.pressRemote(.down, udid: tvUDID, settleDelay: 0)
        XCTAssertNil(result.before) // no reportFocus ⇒ no source round-trips
        XCTAssertNil(result.after)

        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map { $0.url.path }, [
            "/status", "/session", "/session/session-1/execute/sync", "/session/session-1",
        ])
        let body = try JSONDecoder().decode(ExecuteProbe.self, from: try XCTUnwrap(requests[2].body))
        XCTAssertEqual(body.script, "mobile: pressButton")
        XCTAssertEqual(body.args.first?["name"], "down")
    }

    func testModernScreenshotDecodesBase64() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let (controller, transport) = makeController(
            [statusOK(), sessionResponse(), valueResponse(png.base64EncodedString()), emptyOK()],
            device: device(major: 26)
        )
        let data = try await controller.screenshot(udid: tvUDID)
        XCTAssertEqual(data, png)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.last?.method, "DELETE")
    }

    // MARK: - Probes / helpers

    private struct CapsProbe: Decodable {
        struct Caps: Decodable {
            struct AlwaysMatch: Decodable {
                let platformName: String
                let xcodeOrgId: String?
                let updatedWDABundleId: String?
                enum CodingKeys: String, CodingKey {
                    case platformName
                    case xcodeOrgId = "appium:xcodeOrgId"
                    case updatedWDABundleId = "appium:updatedWDABundleId"
                }
            }
            let alwaysMatch: AlwaysMatch
        }
        let capabilities: Caps
    }

    private struct ExecuteProbe: Decodable {
        let script: String
        let args: [[String: String]]
    }

    private func sourceResponse(focusedLabel: String) -> Result<AppiumResponse, Error> {
        valueResponse("""
        <AppiumAUT>
          <XCUIElementTypeApplication type="XCUIElementTypeApplication" name="Head Board" label="Head Board" enabled="true" visible="true" x="0" y="0" width="1920" height="1080" bundleId="com.apple.HeadBoard">
            <XCUIElementTypeCell type="XCUIElementTypeCell" name="TestFlight" label="TestFlight" enabled="true" visible="true" focused="true" x="100" y="400" width="200" height="200" />
          </XCUIElementTypeApplication>
        </AppiumAUT>
        """)
    }
}

private actor MockTransport: AppiumTransport {
    private var responses: [Result<AppiumResponse, Error>]
    private var requests: [AppiumRequest] = []

    init(responses: [Result<AppiumResponse, Error>]) { self.responses = responses }

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

private func valueResponse<Value: Encodable>(_ value: Value) -> Result<AppiumResponse, Error> {
    .success(AppiumResponse(statusCode: 200, body: try! JSONEncoder().encode(ValueWrapper(value: value))))
}
private func sessionResponse(id: String = "session-1") -> Result<AppiumResponse, Error> {
    valueResponse(["sessionId": id])
}
private func emptyOK() -> Result<AppiumResponse, Error> {
    .success(AppiumResponse(statusCode: 200, body: Data(#"{"value":null}"#.utf8)))
}
private func statusOK() -> Result<AppiumResponse, Error> {
    .success(AppiumResponse(statusCode: 200, body: Data(#"{"value":{"ready":true}}"#.utf8)))
}
