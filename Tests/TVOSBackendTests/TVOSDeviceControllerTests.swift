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
    private let tvUDID = "0123456789abcdef0123456789abcdef01234567"
    private var homesToClean: [URL] = []

    override func tearDown() {
        for home in homesToClean { try? FileManager.default.removeItem(at: home) }
        homesToClean = []
        super.tearDown()
    }

    private func device(major: Int, state: String = "connected") -> Device {
        Device(udid: tvUDID, name: "Test Apple TV", platform: .tvos, kind: .physical, state: state, runtime: "tvOS \(major).5")
    }

    private func makeController(
        _ responses: [Result<AppiumResponse, Error>],
        device: Device,
        wdaCache: WDADeviceCache = .disabled(),
        wdaEndpointProvider: TVOSWDAEndpointProvider = .disabled()
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
            // Team id has no default (D7); supply one so the tvOS xcodebuild
            // caps assemble instead of failing fast.
            config: tvConfig(),
            wdaCache: wdaCache,
            wdaEndpointProvider: wdaEndpointProvider
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
        XCTAssertEqual(caps.capabilities.alwaysMatch.xcodeOrgId, "TEAMID1234")
        XCTAssertEqual(caps.capabilities.alwaysMatch.updatedWDABundleId, "com.facebook.WebDriverAgentRunner")
    }

    func testModernDeviceUsesSupervisorEndpointInsteadOfXcodebuildCaps() async throws {
        let provider = TVOSWDAEndpointProvider { info, bundleId, config in
            XCTAssertEqual(info.udid, self.tvUDID)
            XCTAssertEqual(bundleId, "com.example.AsiaPlay")
            XCTAssertEqual(config.wdaRemotePort, nil)
            return URL(string: "http://127.0.0.1:8105")!
        }
        let (controller, transport) = makeController(
            [statusOK(), sessionResponse(), emptyOK(), sourceResponse(focusedLabel: "登入"), emptyOK()],
            device: device(major: 26),
            wdaEndpointProvider: provider
        )

        _ = try await controller.describeUI(
            udid: tvUDID,
            includeRaw: false,
            bundleId: "com.example.AsiaPlay"
        )

        let requests = await transport.recordedRequests()
        let caps = try decodeCaps(requests[1])
        XCTAssertEqual(caps.capabilities.alwaysMatch.webDriverAgentUrl, "http://127.0.0.1:8105")
        XCTAssertNil(caps.capabilities.alwaysMatch.xcodeOrgId)
        XCTAssertNil(caps.capabilities.alwaysMatch.updatedWDABundleId)
        XCTAssertNil(caps.capabilities.alwaysMatch.usePrebuiltWDA)
        XCTAssertNil(caps.capabilities.alwaysMatch.derivedDataPath)
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

    func testModernDeviceTypeUsesPhysicalSessionAndSendsText() async throws {
        let (controller, transport) = makeController(
            [
                statusOK(),
                sessionResponse(),
                physicalTextFieldSource(),
                emptyOK(),
                valueResponse(["element-6066-11e4-a52e-4f735466cecf": "EL-1"]),
                emptyOK(),
                emptyOK(),
                emptyOK(),
            ],
            device: device(major: 26)
        )

        let result = try await controller.typeText("hi there", udid: tvUDID)

        XCTAssertEqual(result.text, "hi there")
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map { $0.url.path }, [
            "/status",
            "/session",
            "/session/session-1/source",
            "/session/session-1/execute/sync",
            "/session/session-1/element",
            "/session/session-1/element/EL-1/value",
            "/session/session-1/execute/sync",
            "/session/session-1",
        ])
        let caps = try decodeCaps(requests[1])
        XCTAssertEqual(caps.capabilities.alwaysMatch.xcodeOrgId, "TEAMID1234")
        let sendKeys = try XCTUnwrap(requests.first { $0.url.path.hasSuffix("/value") })
        let body = try JSONDecoder().decode([String: String].self, from: try XCTUnwrap(sendKeys.body))
        XCTAssertEqual(body["text"], "hi there")
    }

    func testClassicDeviceTypeFailsBeforeOpeningSession() async {
        let (controller, transport) = makeController(
            [statusOK()],
            device: device(major: 16)
        )

        do {
            _ = try await controller.typeText("hi", udid: tvUDID)
            XCTFail("expected TVOSDeviceTypeUnsupportedError")
        } catch let error as TVOSDeviceTypeUnsupportedError {
            XCTAssertEqual(error.osMajorVersion, 16)
            XCTAssertTrue((error.hint ?? "").contains("tvos remote"))
        } catch {
            XCTFail("expected TVOSDeviceTypeUnsupportedError, got \(error)")
        }
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map(\.method), ["GET"], "no session may open for the ≤16 type reject")
    }

    // MARK: - Per-device WDA signing/build cache

    func testValidSigningCacheSelectsPrebuiltWDAWithStablePerDeviceDerivedData() async throws {
        let (cache, expectedPath) = try warmCache()
        let (controller, transport) = makeController(
            [statusOK(), sessionResponse(), sourceResponse(focusedLabel: "TestFlight"), emptyOK()],
            device: device(major: 26),
            wdaCache: cache
        )

        _ = try await controller.describeUI(udid: tvUDID, includeRaw: false)

        let requests = await transport.recordedRequests()
        let caps = try decodeCaps(requests[1])
        XCTAssertEqual(caps.capabilities.alwaysMatch.platformVersion, "26.5")
        XCTAssertEqual(caps.capabilities.alwaysMatch.usePrebuiltWDA, true)
        XCTAssertEqual(caps.capabilities.alwaysMatch.derivedDataPath, expectedPath)
    }

    func testPrebuiltCreationFailureInvalidatesAndRepairsExactlyOnce() async throws {
        let (cache, expectedPath) = try warmCache()
        let (controller, transport) = makeController(
            [
                statusOK(),
                webdriverError("Unable to launch WebDriverAgent: test-without-building failed"),
                sessionResponse(id: "repair-session"),
                sourceResponse(focusedLabel: "TestFlight"),
                emptyOK(),
            ],
            device: device(major: 26),
            wdaCache: cache
        )

        _ = try await controller.describeUI(udid: tvUDID, includeRaw: false)

        let requests = await transport.recordedRequests()
        let sessionRequests = requests.filter { $0.method == "POST" && $0.url.path == "/session" }
        XCTAssertEqual(sessionRequests.count, 2, "one fast attempt + one repair build, never an unbounded retry")
        let fast = try decodeCaps(sessionRequests[0])
        let repair = try decodeCaps(sessionRequests[1])
        XCTAssertEqual(fast.capabilities.alwaysMatch.usePrebuiltWDA, true)
        XCTAssertNil(repair.capabilities.alwaysMatch.usePrebuiltWDA)
        XCTAssertEqual(fast.capabilities.alwaysMatch.derivedDataPath, expectedPath)
        XCTAssertEqual(repair.capabilities.alwaysMatch.derivedDataPath, expectedPath)
        XCTAssertNoThrow(try cache.readRecord(for: tvUDID), "successful repair must restore the trust record")
    }

    func testOperationFailureAfterSessionCreationNeverTriggersRebuild() async {
        do {
            let (cache, _) = try warmCache()
            let (controller, transport) = makeController(
                [
                    statusOK(),
                    sessionResponse(),
                    webdriverError("source failed after the WDA session was already created"),
                    emptyOK(),
                ],
                device: device(major: 26),
                wdaCache: cache
            )

            do {
                _ = try await controller.describeUI(udid: tvUDID, includeRaw: false)
                XCTFail("expected source failure")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("source failed"))
            }
            let requests = await transport.recordedRequests()
            XCTAssertEqual(
                requests.filter { $0.method == "POST" && $0.url.path == "/session" }.count,
                1,
                "only session-creation failures may consume the one repair attempt"
            )
        } catch {
            XCTFail("fixture setup failed: \(error)")
        }
    }

    // MARK: - Probes / helpers

    private struct CapsProbe: Decodable {
        struct Caps: Decodable {
            struct AlwaysMatch: Decodable {
                let platformName: String
                let platformVersion: String?
                let xcodeOrgId: String?
                let updatedWDABundleId: String?
                let usePrebuiltWDA: Bool?
                let derivedDataPath: String?
                let webDriverAgentUrl: String?
                enum CodingKeys: String, CodingKey {
                    case platformName
                    case platformVersion = "appium:platformVersion"
                    case xcodeOrgId = "appium:xcodeOrgId"
                    case updatedWDABundleId = "appium:updatedWDABundleId"
                    case usePrebuiltWDA = "appium:usePrebuiltWDA"
                    case derivedDataPath = "appium:derivedDataPath"
                    case webDriverAgentUrl = "appium:webDriverAgentUrl"
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

    private func decodeCaps(_ request: AppiumRequest) throws -> CapsProbe {
        try JSONDecoder().decode(CapsProbe.self, from: try XCTUnwrap(request.body))
    }

    private func tvConfig() -> DeviceCapabilityConfig {
        DeviceCapabilityConfig(xcodeOrgId: "TEAMID1234")
    }

    private func warmCache() throws -> (WDADeviceCache, String) {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tvos-device-cache-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        homesToClean.append(home)
        let signedAt = Date(timeIntervalSince1970: 1_774_837_800)
        let expiresAt = Date(timeIntervalSince1970: 1_806_373_800)
        let cache = WDADeviceCache(
            home: home,
            metadataProvider: {
                .init(xcodeBuild: "17C529", wdaSourceSHA256: "fixture-wda-source")
            },
            artifactInspector: { _ in
                .init(
                    bundleIdentifier: "com.facebook.WebDriverAgentRunner.xctrunner",
                    teamIdentifier: "TEAMID1234",
                    signedAt: signedAt,
                    provisioningExpiresAt: expiresAt
                )
            },
            now: { Date(timeIntervalSince1970: 1_774_924_200) }
        )
        let info = try XCTUnwrap(PhysicalDeviceInfo(device: device(major: 26)))
        let plan = cache.plan(for: info, config: tvConfig())
        try FileManager.default.createDirectory(at: plan.runnerAppPath, withIntermediateDirectories: true)
        _ = try XCTUnwrap(cache.recordSuccessfulLaunch(plan))
        return (cache, plan.derivedDataPath.path)
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

    private func physicalTextFieldSource() -> Result<AppiumResponse, Error> {
        valueResponse("""
        <AppiumAUT>
          <XCUIElementTypeApplication type="XCUIElementTypeApplication" name="SimUsePlaygroundTV" label="SimUsePlaygroundTV" enabled="true" visible="true" x="0" y="0" width="1920" height="1080" bundleId="com.example.SimUsePlaygroundTV">
            <XCUIElementTypeTextField type="XCUIElementTypeTextField" name="Search" label="Search" enabled="true" visible="true" focused="true" x="200" y="300" width="800" height="90" />
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

private func webdriverError(_ message: String) -> Result<AppiumResponse, Error> {
    let escaped = message.replacingOccurrences(of: #"""#, with: #"\""#)
    return .success(AppiumResponse(
        statusCode: 500,
        body: Data(#"{"value":{"error":"unknown error","message":"\#(escaped)"}}"#.utf8)
    ))
}
