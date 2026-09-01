// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@Suite("Physical-device runner shell contracts", .serialized)
struct PhysicalDeviceRunnerContractTests {
    private let configuration = PhysicalDeviceRunnerTestConfiguration.load()

    @Test("iOS --require-device turns an absent device into a failure")
    func iosRequiredDeviceCannotSkip() async throws {
        let fixture = try FakeToolchain(
            udid: configuration.iosUDID,
            coreDeviceState: "unavailable",
            usbConnected: false
        )
        defer { fixture.remove() }

        let result = try await run(
            "scripts/test-runner-ios-device.sh",
            arguments: ["--no-build", "--require-device"],
            fixture: fixture,
            extraEnvironment: ["SIM_USE_E2E_FORCE_NO_DEVICE": "1"]
        )

        #expect(result.exitCode != 0)
        #expect(result.output.contains("Required iOS physical device is not connected"))
        #expect(!result.output.contains("SKIP"))
    }

    @Test("iOS accepts a live CoreDevice tunnel without idevice_id")
    func iosPrefersCoreDevice() async throws {
        let fixture = try FakeToolchain(
            udid: configuration.iosUDID,
            coreDeviceState: "connected",
            usbConnected: false
        )
        defer { fixture.remove() }

        let result = try await run(
            "scripts/test-runner-ios-device.sh",
            arguments: ["--no-build", "--require-device"],
            fixture: fixture
        )

        #expect(result.output.contains("Target device online via CoreDevice: \(configuration.iosUDID)"))
        #expect(!result.output.contains("SKIP"))
    }

    @Test("explicit runtime environment overrides the local config")
    func environmentOverridesLocalConfig() async throws {
        let overrideUDID = configuration.iosUDID.lowercased()
        let fixture = try FakeToolchain(
            udid: overrideUDID,
            coreDeviceState: "connected",
            usbConnected: false
        )
        defer { fixture.remove() }

        let result = try await run(
            "scripts/test-runner-ios-device.sh",
            arguments: ["--no-build", "--require-device"],
            fixture: fixture,
            extraEnvironment: ["SIM_USE_DEVICE_UDID": overrideUDID]
        )

        #expect(result.output.contains("Target device online via CoreDevice: \(overrideUDID)"))
        #expect(!result.output.contains("Target device online via CoreDevice: \(configuration.iosUDID)"))
    }

    @Test("iOS falls back to a live USB attachment")
    func iosFallsBackToUSB() async throws {
        let fixture = try FakeToolchain(
            udid: configuration.iosUDID,
            coreDeviceState: "connecting",
            usbConnected: true
        )
        defer { fixture.remove() }

        let result = try await run(
            "scripts/test-runner-ios-device.sh",
            arguments: ["--no-build", "--require-device"],
            fixture: fixture
        )

        #expect(result.output.contains("Target device online via USB fallback: \(configuration.iosUDID)"))
        #expect(!result.output.contains("SKIP"))
    }

    @Test("iOS runner isolates its Mac-side WDA port")
    func iosUsesDedicatedWDALocalPort() async throws {
        let fixture = try FakeToolchain(
            udid: configuration.iosUDID,
            coreDeviceState: "connected",
            usbConnected: false
        )
        defer { fixture.remove() }

        let result = try await run(
            "scripts/test-runner-ios-device.sh",
            arguments: ["--no-build", "--require-device"],
            fixture: fixture
        )

        #expect(result.output.contains("WDA ports: Mac 8110 → device 8100"))
    }

    @Test("iOS runner requires signing values when no local config is present")
    func iosHasNoRepositorySpecificDefaults() async throws {
        let fixture = try FakeToolchain(
            udid: configuration.iosUDID,
            coreDeviceState: "connected",
            usbConnected: false
        )
        defer { fixture.remove() }

        var environment = baseEnvironment(fixture: fixture, platform: .ios)
        environment["SIM_USE_E2E_CONFIG_FILE"] = "/missing/sim-use-e2e.env"
        environment["SIM_USE_DEVICE_UDID"] = configuration.iosUDID
        environment["SIM_USE_PLAYGROUND_BUNDLE_ID"] = configuration.iosBundleID
        environment["SIM_USE_WDA_BUNDLE_ID"] = configuration.iosWDABundleID
        let result = try await CommandRunner.run(
            "scripts/test-runner-ios-device.sh --no-build --require-device",
            environment: environment,
            allowFailure: true
        )

        #expect(result.exitCode != 0)
        #expect(result.output.contains("SIM_USE_XCODE_ORG_ID is required"))
    }

    @Test("tvOS --require-device turns an absent device into a failure")
    func tvosRequiredDeviceCannotSkip() async throws {
        let fixture = try FakeToolchain(
            udid: configuration.tvosUDID,
            coreDeviceState: "unavailable",
            usbConnected: false
        )
        defer { fixture.remove() }

        let result = try await run(
            "scripts/test-runner-tvos-device.sh",
            arguments: ["--no-build", "--require-device"],
            fixture: fixture,
            platform: .tvos,
            extraEnvironment: ["SIM_USE_E2E_FORCE_NO_DEVICE": "1"]
        )

        #expect(result.exitCode != 0)
        #expect(result.output.contains("Required tvOS physical device is not connected"))
        #expect(!result.output.contains("SKIP"))
    }

    @Test("tvOS accepts a live CoreDevice tunnel without idevice_id")
    func tvosPrefersCoreDevice() async throws {
        let fixture = try FakeToolchain(
            udid: configuration.tvosUDID,
            coreDeviceState: "connected",
            usbConnected: false
        )
        defer { fixture.remove() }

        let result = try await run(
            "scripts/test-runner-tvos-device.sh",
            arguments: ["--no-build", "--require-device"],
            fixture: fixture,
            platform: .tvos
        )

        #expect(result.output.contains("Target device online via CoreDevice: \(configuration.tvosUDID)"))
        #expect(!result.output.contains("SKIP"))
    }

    @Test("tvOS falls back to a live USB attachment")
    func tvosFallsBackToUSB() async throws {
        let fixture = try FakeToolchain(
            udid: configuration.tvosUDID,
            coreDeviceState: "connecting",
            usbConnected: true
        )
        defer { fixture.remove() }

        let result = try await run(
            "scripts/test-runner-tvos-device.sh",
            arguments: ["--no-build", "--require-device"],
            fixture: fixture,
            platform: .tvos
        )

        #expect(result.output.contains("Target device online via USB fallback: \(configuration.tvosUDID)"))
        #expect(!result.output.contains("SKIP"))
    }

    @Test("tvOS runner isolates its Mac-side WDA port")
    func tvosUsesDedicatedWDALocalPort() async throws {
        let fixture = try FakeToolchain(
            udid: configuration.tvosUDID,
            coreDeviceState: "connected",
            usbConnected: false
        )
        defer { fixture.remove() }

        let result = try await run(
            "scripts/test-runner-tvos-device.sh",
            arguments: ["--no-build", "--require-device"],
            fixture: fixture,
            platform: .tvos
        )

        #expect(result.output.contains("WDA ports: Mac 8111 → device 8100"))
    }

    @Test("tvOS runner defaults to Appium-managed WDA without a tunnel registry")
    func tvosDefaultsToAppiumManagedWDA() async throws {
        let fixture = try FakeToolchain(
            udid: configuration.tvosUDID,
            coreDeviceState: "connected",
            usbConnected: false
        )
        defer { fixture.remove() }

        let result = try await run(
            "scripts/test-runner-tvos-device.sh",
            arguments: ["--no-build", "--require-device"],
            fixture: fixture,
            platform: .tvos
        )

        #expect(result.output.contains("No tunnel registry override; using Appium-managed WDA fallback"))
        #expect(!result.output.contains("RemoteXPC tunnel registry is not serving the target Apple TV"))
    }

    @Test("tvOS runner validates an explicitly configured tunnel registry")
    func tvosValidatesExplicitRemoteXPCTunnelRegistry() async throws {
        let fixture = try FakeToolchain(
            udid: configuration.tvosUDID,
            coreDeviceState: "connected",
            usbConnected: false
        )
        defer { fixture.remove() }

        let result = try await run(
            "scripts/test-runner-tvos-device.sh",
            arguments: ["--no-build", "--require-device"],
            fixture: fixture,
            platform: .tvos,
            extraEnvironment: ["SIM_USE_TUNNEL_REGISTRY_PORT": "42315"]
        )

        #expect(result.exitCode != 0)
        #expect(result.output.contains("RemoteXPC tunnel registry is not serving the target Apple TV on port 42315"))
        #expect(result.output.contains("appium driver run xcuitest tunnel-creation"))
    }

    @Test("tvOS runner requires signing values when no local config is present")
    func tvosHasNoRepositorySpecificDefaults() async throws {
        let fixture = try FakeToolchain(
            udid: configuration.tvosUDID,
            coreDeviceState: "connected",
            usbConnected: false
        )
        defer { fixture.remove() }

        var environment = baseEnvironment(fixture: fixture, platform: .tvos)
        environment["SIM_USE_E2E_CONFIG_FILE"] = "/missing/sim-use-e2e.env"
        environment["SIM_USE_TVOS_DEVICE_UDID"] = configuration.tvosUDID
        environment["SIM_USE_TVOS_BUNDLE_ID"] = configuration.tvosBundleID
        environment["SIM_USE_TVOS_WDA_BUNDLE_ID"] = configuration.tvosWDABundleID
        let result = try await CommandRunner.run(
            "scripts/test-runner-tvos-device.sh --no-build --require-device",
            environment: environment,
            allowFailure: true
        )

        #expect(result.exitCode != 0)
        #expect(result.output.contains("SIM_USE_XCODE_ORG_ID is required"))
    }

    @Test("physical runners cannot reuse a stale screenshot as evidence")
    func screenshotEvidenceIsFresh() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        for scriptName in [
            "test-runner-ios-device.sh",
            "test-runner-tvos-device.sh",
        ] {
            let scriptURL = repositoryRoot
                .appendingPathComponent("scripts", isDirectory: true)
                .appendingPathComponent(scriptName)
            let source = try String(contentsOf: scriptURL, encoding: .utf8)
            let removal = try #require(
                source.range(of: #"rm -f -- "$SCREENSHOT_PATH""#),
                "\(scriptName) must remove the exact prior screenshot"
            )
            let capture = try #require(
                source.range(of: #"--output "$SCREENSHOT_PATH""#),
                "\(scriptName) must capture into the freshly cleared path"
            )
            #expect(removal.upperBound <= capture.lowerBound)
        }
    }

    @Test("physical runners isolate WDA state from canonical xd")
    func wdaStateIsTaskOwned() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        for scriptName in [
            "test-runner-ios-device.sh",
            "test-runner-tvos-device.sh",
        ] {
            let scriptURL = repositoryRoot
                .appendingPathComponent("scripts", isDirectory: true)
                .appendingPathComponent(scriptName)
            let source = try String(contentsOf: scriptURL, encoding: .utf8)
            #expect(source.contains(
                #"WDA_STATE_HOME="${SIM_USE_WDA_STATE_HOME:-$EVIDENCE_DIR/wda-state-home}""#
            ))
            #expect(source.contains(
                #"export SIM_USE_WDA_STATE_HOME="$WDA_STATE_HOME""#
            ))
        }
    }

    @Test("iOS fail-fast timing cannot turn a measurement error into a pass")
    func iosFailFastTimingIsValidatedBeforeAssertion() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scriptURL = repositoryRoot
            .appendingPathComponent("scripts", isDirectory: true)
            .appendingPathComponent("test-runner-ios-device.sh")
        let source = try String(contentsOf: scriptURL, encoding: .utf8)

        #expect(!source.contains(#"assert_elapsed_under 5 "$(awk "#))
        #expect(source.components(separatedBy: "ELAPSED=$(awk").count - 1 == 3)
        #expect(source.components(separatedBy: #"assert_elapsed_under 5 "$ELAPSED""#).count - 1 == 3)
        #expect(source.contains(#"if [[ ! "$actual" =~ ^[0-9]+([.][0-9]+)?$ ]]; then"#))
    }

    @Test("tvOS physical runner exercises text entry through the device controller")
    func tvosRunnerCoversPhysicalType() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scriptURL = repositoryRoot
            .appendingPathComponent("scripts", isDirectory: true)
            .appendingPathComponent("test-runner-tvos-device.sh")
        let source = try String(contentsOf: scriptURL, encoding: .utf8)

        #expect(source.contains(#"--launch-arg screen=text"#))
        #expect(source.contains(#"tvos_type "$TYPE_TOKEN""#))
        #expect(source.contains(#"assert_contains "$EVIDENCE_DIR/ui-after-type.txt" "$TYPE_TOKEN""#))
    }

    private enum Platform {
        case ios
        case tvos
    }

    private func run(
        _ script: String,
        arguments: [String],
        fixture: FakeToolchain,
        platform: Platform = .ios,
        extraEnvironment: [String: String] = [:]
    ) async throws -> (output: String, exitCode: Int32) {
        let environment = baseEnvironment(fixture: fixture, platform: platform)
            .merging(extraEnvironment) { _, new in new }
        let command = ([script] + arguments).joined(separator: " ")
        return try await CommandRunner.run(
            command,
            environment: environment,
            allowFailure: true
        )
    }

    private func baseEnvironment(
        fixture: FakeToolchain,
        platform: Platform
    ) -> [String: String] {
        let environment: [String: String] = [
            "PATH": "\(fixture.binDirectory.path):/usr/bin:/bin",
            "SIM_USE_BIN": "/usr/bin/true",
            "SIM_USE_APPIUM_URL": "http://127.0.0.1:4998",
            "SIM_USE_APPIUM_BIN": "/missing/appium",
            "SIM_USE_E2E_CONFIG_FILE": configuration.fileURL.path,
        ]
        _ = platform
        return environment
    }
}

private struct PhysicalDeviceRunnerTestConfiguration {
    let fileURL: URL
    let iosUDID: String
    let tvosUDID: String
    let iosBundleID: String
    let tvosBundleID: String
    let iosWDABundleID: String
    let tvosWDABundleID: String

    static func load() -> Self {
        guard let fileURL = Bundle.module.url(
            forResource: "physical-device-e2e",
            withExtension: "env",
            subdirectory: "Fixtures"
        ) else {
            preconditionFailure("Missing Tests/Fixtures/physical-device-e2e.env")
        }
        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
            preconditionFailure("Could not read \(fileURL.path)")
        }

        var values: [String: String] = [:]
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else {
                preconditionFailure("Malformed test configuration line: \(line)")
            }
            values[String(pair[0])] = String(pair[1])
        }

        func required(_ key: String) -> String {
            guard let value = values[key], !value.isEmpty else {
                preconditionFailure("Missing \(key) in \(fileURL.path)")
            }
            return value
        }

        return Self(
            fileURL: fileURL,
            iosUDID: required("SIM_USE_DEVICE_UDID"),
            tvosUDID: required("SIM_USE_TVOS_DEVICE_UDID"),
            iosBundleID: required("SIM_USE_PLAYGROUND_BUNDLE_ID"),
            tvosBundleID: required("SIM_USE_TVOS_BUNDLE_ID"),
            iosWDABundleID: required("SIM_USE_WDA_BUNDLE_ID"),
            tvosWDABundleID: required("SIM_USE_TVOS_WDA_BUNDLE_ID")
        )
    }
}

private struct FakeToolchain {
    let root: URL
    let binDirectory: URL

    init(udid: String, coreDeviceState: String, usbConnected: Bool) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sim-use-runner-contract-\(UUID().uuidString)", isDirectory: true)
        binDirectory = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)

        try writeExecutable(
            named: "xcrun",
            body: """
            if [[ "$*" == *"devicectl device info details"* ]]; then
              echo "tunnelState: \(coreDeviceState)"
              exit 0
            fi
            exit 1
            """
        )
        try writeExecutable(
            named: "idevice_id",
            body: usbConnected ? "echo '\(udid)'" : "exit 0"
        )
        try writeExecutable(named: "curl", body: "exit 1")
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeExecutable(named name: String, body: String) throws {
        let url = binDirectory.appendingPathComponent(name)
        let script = """
        #!/bin/bash
        \(body)
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }
}
