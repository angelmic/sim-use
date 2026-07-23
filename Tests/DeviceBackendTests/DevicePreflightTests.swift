// SPDX-License-Identifier: Apache-2.0
import AppiumCore
import Foundation
import SimUseCore
import XCTest
@testable import DeviceBackend

/// The fail-fast gate: a down server or an unreachable device must be
/// rejected in-process, with a hint, before any session is attempted.
final class DevicePreflightTests: XCTestCase {
    private let iPhoneUDID = "00008140-00096D5C0CEA801C"
    private let tvUDID = "c311e5afe90ee702b80e8b64e1e12796e04e63a0"

    private func iPhone(state: String = Device.State.deviceConnected) -> Device {
        Device(udid: iPhoneUDID, name: "CP 16 Pro Max", platform: .ios, state: state, runtime: "iOS 18.7.8", target: .device)
    }

    private func appleTV(state: String = Device.State.deviceConnected) -> Device {
        Device(udid: tvUDID, name: "辦公桌tv理查", platform: .tvos, state: state, runtime: "tvOS 26.5", target: .device)
    }

    private func preflight(
        statusResponses: [Result<AppiumResponse, Error>],
        devices: [Device]
    ) -> DevicePreflight {
        DevicePreflight(
            baseURL: URL(string: "http://127.0.0.1:4788")!,
            statusTransport: MockTransport(responses: statusResponses),
            infoResolver: DeviceInfoResolver(provider: { devices })
        )
    }

    func testPassesWhenServerReachableAndTunnelConnected() async throws {
        let info = try await preflight(
            statusResponses: [statusOK()],
            devices: [iPhone(), appleTV()]
        ).run(udid: iPhoneUDID)

        XCTAssertEqual(info.family, .ios)
        XCTAssertEqual(info.osMajorVersion, 18)
        XCTAssertTrue(info.isConnected)
        XCTAssertTrue(info.isModern)
    }

    func testServerUnreachableFailsFastWithStartupHint() async {
        let gate = preflight(
            statusResponses: [.failure(URLError(.cannotConnectToHost))],
            devices: [iPhone()]
        )
        await assertThrows(gate, udid: iPhoneUDID) { error in
            guard case .appiumUnreachable = error else {
                return XCTFail("expected .appiumUnreachable, got \(error)")
            }
            XCTAssertTrue(error.errorDescription?.contains("not reachable") == true)
            XCTAssertTrue(error.hint?.contains("SIM_USE_APPIUM_URL") == true)
        }
    }

    func testServerNon2xxFailsFast() async {
        let gate = preflight(
            statusResponses: [.success(AppiumResponse(statusCode: 500, body: Data()))],
            devices: [iPhone()]
        )
        await assertThrows(gate, udid: iPhoneUDID) { error in
            guard case .appiumUnreachable(_, let detail) = error else {
                return XCTFail("expected .appiumUnreachable, got \(error)")
            }
            XCTAssertTrue(detail.contains("500"))
        }
    }

    func testTunnelNotConnectedFailsFast() async {
        let gate = preflight(
            statusResponses: [statusOK()],
            devices: [iPhone(state: "disconnected")]
        )
        await assertThrows(gate, udid: iPhoneUDID) { error in
            guard case .tunnelNotConnected(_, let state) = error else {
                return XCTFail("expected .tunnelNotConnected, got \(error)")
            }
            XCTAssertEqual(state, "disconnected")
            XCTAssertTrue(error.hint?.contains("devicectl device info details") == true)
        }
    }

    func testUnknownDeviceFailsFast() async {
        let gate = preflight(statusResponses: [statusOK()], devices: [appleTV()])
        await assertThrows(gate, udid: iPhoneUDID) { error in
            guard case .deviceNotFound = error else {
                return XCTFail("expected .deviceNotFound, got \(error)")
            }
        }
    }

    /// The server probe runs first: a down server is reported even when the
    /// device would also fail, so the cheapest signal surfaces.
    func testServerCheckedBeforeDevice() async {
        let gate = preflight(
            statusResponses: [.failure(URLError(.timedOut))],
            devices: [] // device would also fail, but server check wins
        )
        await assertThrows(gate, udid: iPhoneUDID) { error in
            guard case .appiumUnreachable = error else {
                return XCTFail("expected server check to win, got \(error)")
            }
        }
    }

    private func assertThrows(
        _ gate: DevicePreflight,
        udid: String,
        _ inspect: (DevicePreflightError) -> Void
    ) async {
        do {
            _ = try await gate.run(udid: udid)
            XCTFail("expected preflight to throw")
        } catch let error as DevicePreflightError {
            inspect(error)
        } catch {
            XCTFail("expected DevicePreflightError, got \(error)")
        }
    }

    private func statusOK() -> Result<AppiumResponse, Error> {
        .success(AppiumResponse(statusCode: 200, body: Data(#"{"value":{"ready":true}}"#.utf8)))
    }
}

/// Records requests and replays a scripted response queue. Mirrors the
/// AppiumCoreTests transport so both suites share one mental model.
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
