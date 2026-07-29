// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import DeviceBackend

final class TVOSWDASupervisorTests: XCTestCase {
    func testMissingRegistryOverrideFallsBackToAppiumManagedWDA() async throws {
        let provider = TVOSWDAEndpointProvider.live(
            environment: ["SIM_USE_TVOS_WDA_SUPERVISOR": "1"],
            home: URL(
                fileURLWithPath: "/tmp/sim-use-supervisor-no-registry-\(UUID().uuidString)",
                isDirectory: true
            )
        )
        let info = PhysicalDeviceInfo(
            udid: "0123456789abcdef0123456789abcdef01234567",
            family: .tvos,
            osMajorVersion: 26,
            tunnelState: "connected",
            osVersion: "26.5"
        )

        let endpoint = try await provider.endpoint(
            for: info,
            targetBundleId: "com.example.AsiaPlay",
            config: DeviceCapabilityConfig(
                tvosWDABundleId: "com.example.wda",
                xcodeOrgId: "TEAMID1234"
            )
        )

        XCTAssertNil(endpoint)
    }

    func testPlanUsesRemotePortForRunnerAndLocalPortForAppiumURL() throws {
        let root = URL(fileURLWithPath: "/tmp/sim-use-supervisor-fixture", isDirectory: true)
        let plan = TVOSWDASupervisorPlan(
            udid: "0123456789abcdef0123456789abcdef01234567",
            targetBundleId: "com.example.AsiaPlay",
            wdaBundleId: "com.example.wda",
            xctestBundleId: "WebDriverAgentRunner_tvOS",
            localPort: 8105,
            remotePort: 8100,
            tunnelRegistryPort: 42315,
            nodeExecutableURL: URL(fileURLWithPath: "/opt/node/bin/node"),
            remoteXPCModuleURL: URL(fileURLWithPath: "/opt/appium-ios-remotexpc/build/src/index.js"),
            loaderURL: root.appendingPathComponent("tvos-wda-loader.mjs"),
            launcherURL: root.appendingPathComponent("tvos-wda-supervisor.mjs"),
            stateDirectory: root
        )

        XCTAssertEqual(plan.runnerBundleId, "com.example.wda.xctrunner")
        XCTAssertEqual(plan.wdaURL.absoluteString, "http://127.0.0.1:8105")
        XCTAssertEqual(plan.launchEnvironment["USE_PORT"], "8100")
        XCTAssertEqual(plan.launchEnvironment["MJPEG_SERVER_PORT"], "9100")
        XCTAssertEqual(plan.processEnvironment["APPIUM_TUNNEL_REGISTRY_PORT"], "42315")
        XCTAssertEqual(plan.processEnvironment["NODE_NO_WARNINGS"], "1")
        XCTAssertTrue(plan.arguments.contains("/opt/appium-ios-remotexpc/build/src/index.js"))
        XCTAssertTrue(plan.arguments.contains("com.example.AsiaPlay"))
        XCTAssertTrue(plan.arguments.contains("WebDriverAgentRunner_tvOS"))
    }

    func testRunnerSuffixIsNotDuplicated() {
        let root = URL(fileURLWithPath: "/tmp/sim-use-supervisor-fixture", isDirectory: true)
        let plan = TVOSWDASupervisorPlan(
            udid: "TV-UDID",
            targetBundleId: "com.example.app",
            wdaBundleId: "com.example.wda.xctrunner",
            localPort: 8100,
            remotePort: 8100,
            nodeExecutableURL: URL(fileURLWithPath: "/usr/bin/node"),
            remoteXPCModuleURL: root.appendingPathComponent("index.js"),
            loaderURL: root.appendingPathComponent("loader.mjs"),
            launcherURL: root.appendingPathComponent("launcher.mjs"),
            stateDirectory: root
        )

        XCTAssertEqual(plan.runnerBundleId, "com.example.wda.xctrunner")
    }
}
