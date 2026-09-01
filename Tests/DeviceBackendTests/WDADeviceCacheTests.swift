// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore
import XCTest
@testable import DeviceBackend

/// The cache is an optimization, never an authority: a timestamp alone must
/// not select Appium's `test-without-building` path. These tests pin the
/// fingerprint and signed-artifact gates that make the fast path safe.
final class WDADeviceCacheTests: XCTestCase {
    private var homesToClean: [URL] = []
    private let signedAt = Date(timeIntervalSince1970: 1_774_837_800) // 2026-03-30T02:30:00Z
    private let now = Date(timeIntervalSince1970: 1_774_924_200)      // 2026-03-31T02:30:00Z

    override func tearDown() {
        for home in homesToClean { try? FileManager.default.removeItem(at: home) }
        homesToClean = []
        super.tearDown()
    }

    func testFirstPlanMissesThenSuccessfulSignedArtifactBecomesFastPathHit() throws {
        let home = makeHome()
        let cache = makeCache(home: home)
        let first = cache.plan(for: tvInfo(), config: tvConfig())

        XCTAssertFalse(first.usePrebuiltWDA)
        XCTAssertEqual(first.missReason, .recordMissing)
        XCTAssertTrue(first.derivedDataPath.path.hasSuffix(
            ".sim-use/0123456789abcdef0123456789abcdef01234567/wda-derived-data"
        ))

        try FileManager.default.createDirectory(
            at: first.runnerAppPath,
            withIntermediateDirectories: true
        )
        let record = try XCTUnwrap(cache.recordSuccessfulLaunch(first))
        XCTAssertEqual(record.signedAt, "2026-03-30T02:30:00Z")
        XCTAssertEqual(record.lastSuccessfulLaunchAt, "2026-03-31T02:30:00Z")

        let second = cache.plan(for: tvInfo(), config: tvConfig())
        XCTAssertTrue(second.usePrebuiltWDA)
        XCTAssertNil(second.missReason)
        XCTAssertEqual(second.fingerprint, first.fingerprint)
    }

    func testModernIOSPlanUsesIOSFingerprintAndRunnerProduct() {
        let home = makeHome()
        let cache = makeCache(home: home)

        let plan = cache.plan(for: iosInfo(), config: iosConfig())

        XCTAssertEqual(plan.missReason, .recordMissing)
        XCTAssertEqual(plan.fingerprint?.platformName, "iOS")
        XCTAssertEqual(plan.fingerprint?.bundleIdentifier, "com.example.WebDriverAgentRunner")
        XCTAssertEqual(plan.fingerprint?.scheme, "WebDriverAgentRunner")
        XCTAssertTrue(plan.runnerAppPath.path.hasSuffix(
            "Debug-iphoneos/WebDriverAgentRunner-Runner.app"
        ))
    }

    func testSuccessfulIOSLaunchPersistsSigningInputsForEnvironmentlessRerun() throws {
        let home = makeHome()
        let cache = makeIOSCache(home: home)
        let plan = cache.plan(for: iosInfo(), config: iosConfig())
        try FileManager.default.createDirectory(
            at: plan.runnerAppPath,
            withIntermediateDirectories: true
        )

        _ = try XCTUnwrap(cache.recordSuccessfulLaunch(plan))
        _ = try XCTUnwrap(cache.recordSigningConfiguration(
            for: iosInfo(),
            config: iosConfig()
        ))
        let resolved = cache.resolvedConfig(for: iosInfo(), environment: [:])

        XCTAssertEqual(resolved.iosWDABundleId, "com.example.WebDriverAgentRunner")
        XCTAssertEqual(resolved.xcodeOrgId, "ZYXWV98765")
        XCTAssertEqual(resolved.xcodeSigningId, "Apple Development")
        let configFile = cache.signingConfigFile(for: iosInfo().udid)
        XCTAssertTrue(FileManager.default.fileExists(atPath: configFile.path))
        let permissions = try FileManager.default.attributesOfItem(atPath: configFile.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testEnvironmentOverridesPersistedSigningInputs() throws {
        let home = makeHome()
        let cache = makeIOSCache(home: home)
        let plan = cache.plan(for: iosInfo(), config: iosConfig())
        try FileManager.default.createDirectory(
            at: plan.runnerAppPath,
            withIntermediateDirectories: true
        )
        _ = try XCTUnwrap(cache.recordSuccessfulLaunch(plan))
        _ = try XCTUnwrap(cache.recordSigningConfiguration(
            for: iosInfo(),
            config: iosConfig()
        ))

        let resolved = cache.resolvedConfig(
            for: iosInfo(),
            environment: [
                "SIM_USE_WDA_BUNDLE_ID": "com.example.OverrideRunner",
                "SIM_USE_XCODE_ORG_ID": "OVERRIDE123",
                "SIM_USE_XCODE_SIGNING_ID": "Override Identity",
                "SIM_USE_WDA_LOCAL_PORT": "8112",
            ]
        )

        XCTAssertEqual(resolved.iosWDABundleId, "com.example.OverrideRunner")
        XCTAssertEqual(resolved.xcodeOrgId, "OVERRIDE123")
        XCTAssertEqual(resolved.xcodeSigningId, "Override Identity")
        XCTAssertEqual(resolved.wdaLocalPort, 8112)
    }

    func testInvalidatingTrustRecordPreservesPersistedSigningInputs() throws {
        let home = makeHome()
        let cache = makeIOSCache(home: home)
        let plan = cache.plan(for: iosInfo(), config: iosConfig())
        try FileManager.default.createDirectory(
            at: plan.runnerAppPath,
            withIntermediateDirectories: true
        )
        _ = try XCTUnwrap(cache.recordSuccessfulLaunch(plan))
        _ = try XCTUnwrap(cache.recordSigningConfiguration(
            for: iosInfo(),
            config: iosConfig()
        ))

        try cache.invalidate(udid: iosInfo().udid)
        let resolved = cache.resolvedConfig(for: iosInfo(), environment: [:])

        XCTAssertEqual(resolved.iosWDABundleId, "com.example.WebDriverAgentRunner")
        XCTAssertEqual(resolved.xcodeOrgId, "ZYXWV98765")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: cache.signingConfigFile(for: iosInfo().udid).path
        ))
    }

    func testInvalidatingLegacyTrustRecordMaterializesSigningConfig() throws {
        let home = makeHome()
        let cache = makeIOSCache(home: home)
        let plan = cache.plan(for: iosInfo(), config: iosConfig())
        try FileManager.default.createDirectory(
            at: plan.runnerAppPath,
            withIntermediateDirectories: true
        )
        _ = try XCTUnwrap(cache.recordSuccessfulLaunch(plan))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: cache.signingConfigFile(for: iosInfo().udid).path
        ))
        try JSONEncoder().encode(WDADeviceCache.SigningConfiguration(
            deviceUDID: iosInfo().udid,
            platformName: "iOS",
            wdaBundleIdentifier: "",
            developmentTeam: "",
            signingIdentity: "",
            savedAt: "2026-07-29T00:00:00Z"
        )).write(to: cache.signingConfigFile(for: iosInfo().udid))

        try cache.invalidate(udid: iosInfo().udid)
        let resolved = cache.resolvedConfig(for: iosInfo(), environment: [:])

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: cache.recordFile(for: iosInfo().udid).path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: cache.signingConfigFile(for: iosInfo().udid).path
        ))
        XCTAssertEqual(resolved.iosWDABundleId, "com.example.WebDriverAgentRunner")
        XCTAssertEqual(resolved.xcodeOrgId, "ZYXWV98765")
        XCTAssertEqual(resolved.xcodeSigningId, "Apple Development")
    }

    func testLegacySigningCacheHydratesConfigWhenDedicatedFileIsMissing() throws {
        let home = makeHome()
        let cache = makeIOSCache(home: home)
        let plan = cache.plan(for: iosInfo(), config: iosConfig())
        try FileManager.default.createDirectory(
            at: plan.runnerAppPath,
            withIntermediateDirectories: true
        )
        _ = try XCTUnwrap(cache.recordSuccessfulLaunch(plan))

        let resolved = cache.resolvedConfig(for: iosInfo(), environment: [:])

        XCTAssertEqual(resolved.iosWDABundleId, "com.example.WebDriverAgentRunner")
        XCTAssertEqual(resolved.xcodeOrgId, "ZYXWV98765")
        XCTAssertEqual(resolved.xcodeSigningId, "Apple Development")
    }

    func testCorruptDedicatedConfigFallsBackToLegacySigningCache() throws {
        let home = makeHome()
        let cache = makeIOSCache(home: home)
        let plan = cache.plan(for: iosInfo(), config: iosConfig())
        try FileManager.default.createDirectory(
            at: plan.runnerAppPath,
            withIntermediateDirectories: true
        )
        _ = try XCTUnwrap(cache.recordSuccessfulLaunch(plan))
        try Data("not-json".utf8).write(
            to: cache.signingConfigFile(for: iosInfo().udid)
        )

        let resolved = cache.resolvedConfig(for: iosInfo(), environment: [:])

        XCTAssertEqual(resolved.iosWDABundleId, "com.example.WebDriverAgentRunner")
        XCTAssertEqual(resolved.xcodeOrgId, "ZYXWV98765")
    }

    func testSigningConfigRejectsWrongUDIDAndPlatform() throws {
        let home = makeHome()
        let cache = makeIOSCache(home: home)
        let target = cache.signingConfigFile(for: iosInfo().udid)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let wrongUDID = WDADeviceCache.SigningConfiguration(
            deviceUDID: "00000000-0000000000000000",
            platformName: "iOS",
            wdaBundleIdentifier: "com.example.Wrong",
            developmentTeam: "WRONGTEAM1",
            signingIdentity: "Wrong Identity",
            savedAt: "2026-07-29T00:00:00Z"
        )
        try JSONEncoder().encode(wrongUDID).write(to: target)
        var resolved = cache.resolvedConfig(for: iosInfo(), environment: [:])
        XCTAssertEqual(resolved.iosWDABundleId, "com.facebook.WebDriverAgentRunner")
        XCTAssertNil(resolved.xcodeOrgId)

        let wrongPlatform = WDADeviceCache.SigningConfiguration(
            deviceUDID: iosInfo().udid,
            platformName: "tvOS",
            wdaBundleIdentifier: "com.example.Wrong",
            developmentTeam: "WRONGTEAM1",
            signingIdentity: "Wrong Identity",
            savedAt: "2026-07-29T00:00:00Z"
        )
        try JSONEncoder().encode(wrongPlatform).write(to: target)
        resolved = cache.resolvedConfig(for: iosInfo(), environment: [:])
        XCTAssertEqual(resolved.iosWDABundleId, "com.facebook.WebDriverAgentRunner")
        XCTAssertNil(resolved.xcodeOrgId)
    }

    func testDisabledCacheIgnoresPersistedSigningConfig() throws {
        let home = makeHome()
        let enabled = makeIOSCache(home: home)
        _ = try XCTUnwrap(enabled.recordSigningConfiguration(
            for: iosInfo(),
            config: iosConfig()
        ))
        let disabled = WDADeviceCache(
            home: home,
            enabled: false,
            metadataProvider: {
                .init(xcodeBuild: "unused", wdaSourceSHA256: "unused")
            },
            artifactInspector: {
                throw WDADeviceCache.ArtifactValidationError.missing($0.path)
            }
        )

        let resolved = disabled.resolvedConfig(for: iosInfo(), environment: [:])

        XCTAssertEqual(resolved.iosWDABundleId, "com.facebook.WebDriverAgentRunner")
        XCTAssertNil(resolved.xcodeOrgId)
    }

    func testFreshTimestampCannotHideFingerprintChange() throws {
        let home = makeHome()
        let original = makeCache(home: home)
        let first = original.plan(for: tvInfo(), config: tvConfig())
        try FileManager.default.createDirectory(at: first.runnerAppPath, withIntermediateDirectories: true)
        _ = try XCTUnwrap(original.recordSuccessfulLaunch(first))

        let changedXcode = makeCache(
            home: home,
            metadata: .init(xcodeBuild: "17D999", wdaSourceSHA256: "wda-source-a")
        )
        let next = changedXcode.plan(for: tvInfo(), config: tvConfig())

        XCTAssertFalse(next.usePrebuiltWDA)
        XCTAssertEqual(next.missReason, .fingerprintChanged)
    }

    func testInvalidOrExpiredSignatureRejectsExistingArtifact() throws {
        let home = makeHome()
        let original = makeCache(home: home)
        let first = original.plan(for: tvInfo(), config: tvConfig())
        try FileManager.default.createDirectory(at: first.runnerAppPath, withIntermediateDirectories: true)
        _ = try XCTUnwrap(original.recordSuccessfulLaunch(first))

        let invalid = makeCache(home: home, artifactInspector: { _ in
            throw WDADeviceCache.ArtifactValidationError.codesignInvalid("CSSMERR_TP_NOT_TRUSTED")
        })
        XCTAssertEqual(invalid.plan(for: tvInfo(), config: tvConfig()).missReason, .artifactInvalid)

        let expired = makeCache(home: home, artifactInspector: { [signedAt, now] _ in
            .init(
                bundleIdentifier: "com.example.wda.xctrunner",
                teamIdentifier: "ZYXWV98765",
                signedAt: signedAt,
                provisioningExpiresAt: now.addingTimeInterval(-1)
            )
        })
        XCTAssertEqual(expired.plan(for: tvInfo(), config: tvConfig()).missReason, .artifactExpired)

        let missingExpiration = makeCache(home: home, artifactInspector: { [signedAt] _ in
            .init(
                bundleIdentifier: "com.example.wda.xctrunner",
                teamIdentifier: "ZYXWV98765",
                signedAt: signedAt,
                provisioningExpiresAt: nil
            )
        })
        XCTAssertEqual(
            missingExpiration.plan(for: tvInfo(), config: tvConfig()).missReason,
            .artifactInvalid,
            "a physical-device runner without verifiable profile expiry is not a safe cache hit"
        )
    }

    func testTeamOrBundleMismatchRejectsCacheHit() throws {
        let home = makeHome()
        let original = makeCache(home: home)
        let first = original.plan(for: tvInfo(), config: tvConfig())
        try FileManager.default.createDirectory(at: first.runnerAppPath, withIntermediateDirectories: true)
        _ = try XCTUnwrap(original.recordSuccessfulLaunch(first))

        let wrongTeam = makeCache(home: home, artifactInspector: { [signedAt, now] _ in
            .init(
                bundleIdentifier: "com.example.wda.xctrunner",
                teamIdentifier: "OTHERTEAM1",
                signedAt: signedAt,
                provisioningExpiresAt: now.addingTimeInterval(86_400)
            )
        })
        XCTAssertEqual(wrongTeam.plan(for: tvInfo(), config: tvConfig()).missReason, .artifactIdentityMismatch)

        let wrongBundle = makeCache(home: home, artifactInspector: { [signedAt, now] _ in
            .init(
                bundleIdentifier: "com.example.other.xctrunner",
                teamIdentifier: "ZYXWV98765",
                signedAt: signedAt,
                provisioningExpiresAt: now.addingTimeInterval(86_400)
            )
        })
        XCTAssertEqual(wrongBundle.plan(for: tvInfo(), config: tvConfig()).missReason, .artifactIdentityMismatch)
    }

    func testInvalidateRemovesOnlyRequestedDeviceRecord() throws {
        let home = makeHome()
        let cache = makeCache(home: home)
        let plan = cache.plan(for: tvInfo(), config: tvConfig())
        try FileManager.default.createDirectory(at: plan.runnerAppPath, withIntermediateDirectories: true)
        _ = try XCTUnwrap(cache.recordSuccessfulLaunch(plan))
        XCTAssertNoThrow(try cache.readRecord(for: tvInfo().udid))

        try cache.invalidate(udid: tvInfo().udid)

        XCTAssertThrowsError(try cache.readRecord(for: tvInfo().udid))
        XCTAssertTrue(FileManager.default.fileExists(atPath: plan.derivedDataPath.path))
    }

    func testRepairLockSerializesWithAnotherProcessForTheSameDevice() async throws {
        let home = makeHome()
        let cache = makeCache(home: home)
        let lockFile = cache.repairLockFile(for: iosInfo().udid)
        let readyFile = home.appendingPathComponent("child-holds-lock")
        try FileManager.default.createDirectory(
            at: lockFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            "-c",
            """
            import fcntl, pathlib, sys, time
            lock_path, ready_path = sys.argv[1], sys.argv[2]
            with open(lock_path, "a+") as handle:
                fcntl.flock(handle, fcntl.LOCK_EX)
                pathlib.Path(ready_path).write_text("locked")
                time.sleep(1.0)
            """,
            lockFile.path,
            readyFile.path,
        ]
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }

        let waitDeadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: readyFile.path), Date() < waitDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: readyFile.path),
            "the child process must acquire the fixture lock"
        )

        let startedAt = Date()
        try await cache.withExclusiveRepairLock(for: iosInfo().udid) {}
        XCTAssertGreaterThanOrEqual(
            Date().timeIntervalSince(startedAt),
            0.5,
            "a second process must wait instead of entering the same DerivedData repair"
        )
    }

    func testArtifactInspectionProcessDrainsStdoutAndStderrConcurrently() throws {
        let result = try WDADeviceCache.runProcess(
            executable: "/usr/bin/python3",
            arguments: [
                "-c",
                """
                import sys
                sys.stderr.write("e" * 1_000_000)
                sys.stderr.flush()
                sys.stdout.write("ok")
                """,
            ],
            environment: ProcessInfo.processInfo.environment
        )

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, "ok")
        XCTAssertEqual(result.stderr.utf8.count, 1_000_000)
    }

    func testLiveMetadataFingerprintsConfiguredWDASourceInsteadOfFallingBackUnavailable() throws {
        let home = makeHome()
        let source = home.appendingPathComponent("fixture-wda", isDirectory: true)
        let files: [(String, String)] = [
            ("Configurations/TVOSSettings.xcconfig", "TVOS_DEPLOYMENT_TARGET = 17.0"),
            ("WebDriverAgentLib/FBApplication.m", "@implementation FBApplication @end"),
            ("WebDriverAgentRunner/Info.plist", "<plist><dict/></plist>"),
            ("WebDriverAgent.xcodeproj/project.pbxproj", "// fixture project"),
            (
                "WebDriverAgent.xcodeproj/xcshareddata/xcschemes/WebDriverAgentRunner_tvOS.xcscheme",
                "<Scheme version=\"1.7\"/>"
            ),
            ("Scripts/embed-runner-icon.sh", "#!/bin/sh\nexit 0"),
            ("package.json", #"{"version":"99.0.0"}"#),
        ]
        for (relativePath, contents) in files {
            let file = source.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: file)
        }
        var environment = ProcessInfo.processInfo.environment
        environment["SIM_USE_WDA_SOURCE_ROOT"] = source.path
        let cache = WDADeviceCache.live(environment: environment, home: home)

        let plan = cache.plan(for: tvInfo(), config: tvConfig())

        XCTAssertEqual(plan.missReason, .recordMissing)
        XCTAssertEqual(plan.fingerprint?.xcodeBuild.contains("Build version"), true)
        XCTAssertEqual(plan.fingerprint?.wdaSourceSHA256.count, 64)

        let originalSHA = plan.fingerprint?.wdaSourceSHA256
        let scheme = source.appendingPathComponent(
            "WebDriverAgent.xcodeproj/xcshareddata/xcschemes/WebDriverAgentRunner_tvOS.xcscheme"
        )
        try Data("<Scheme version=\"1.8\"/>".utf8).write(to: scheme)
        let changedPlan = WDADeviceCache.live(environment: environment, home: home)
            .plan(for: tvInfo(), config: tvConfig())
        XCTAssertNotEqual(
            changedPlan.fingerprint?.wdaSourceSHA256,
            originalSHA,
            "scheme/build-script changes must invalidate a prebuilt runner"
        )
    }

    func testLiveCacheCanBeExplicitlyDisabled() {
        let home = makeHome()
        let cache = WDADeviceCache.live(
            environment: ["SIM_USE_WDA_CACHE": "false"],
            home: home
        )

        let plan = cache.plan(for: tvInfo(), config: tvConfig())

        XCTAssertEqual(plan.missReason, .cacheDisabled)
        XCTAssertFalse(plan.usePrebuiltWDA)
    }

    func testLiveCacheUsesRuntimeStateHome() {
        let stateHome = makeHome()
            .appendingPathComponent("task-owned-state", isDirectory: true)
        let cache = WDADeviceCache.live(
            environment: ["SIM_USE_WDA_STATE_HOME": stateHome.path]
        )

        XCTAssertEqual(
            cache.directory(for: iosInfo().udid),
            stateHome
                .appendingPathComponent(".sim-use", isDirectory: true)
                .appendingPathComponent(iosInfo().udid, isDirectory: true)
        )
    }

    // MARK: - Fixtures

    private func tvInfo() -> PhysicalDeviceInfo {
        PhysicalDeviceInfo(
            udid: "0123456789abcdef0123456789abcdef01234567",
            family: .tvos,
            osMajorVersion: 26,
            tunnelState: "connected",
            osVersion: "26.5"
        )
    }

    private func iosInfo() -> PhysicalDeviceInfo {
        PhysicalDeviceInfo(
            udid: "00008110-001234567890001E",
            family: .ios,
            osMajorVersion: 18,
            tunnelState: "connected",
            osVersion: "18.7.8"
        )
    }

    private func tvConfig() -> DeviceCapabilityConfig {
        DeviceCapabilityConfig(
            tvosWDABundleId: "com.example.wda",
            xcodeOrgId: "ZYXWV98765",
            xcodeSigningId: "Apple Development"
        )
    }

    private func iosConfig() -> DeviceCapabilityConfig {
        DeviceCapabilityConfig(
            iosWDABundleId: "com.example.WebDriverAgentRunner",
            xcodeOrgId: "ZYXWV98765",
            xcodeSigningId: "Apple Development"
        )
    }

    private func makeIOSCache(home: URL) -> WDADeviceCache {
        makeCache(home: home, artifactInspector: { [signedAt, now] _ in
            WDADeviceCache.Artifact(
                bundleIdentifier: "com.example.WebDriverAgentRunner.xctrunner",
                teamIdentifier: "ZYXWV98765",
                signedAt: signedAt,
                provisioningExpiresAt: now.addingTimeInterval(86_400)
            )
        })
    }

    private func makeCache(
        home: URL,
        metadata: WDADeviceCache.HostMetadata = .init(
            xcodeBuild: "17C529",
            wdaSourceSHA256: "wda-source-a"
        ),
        artifactInspector: (@Sendable (URL) throws -> WDADeviceCache.Artifact)? = nil
    ) -> WDADeviceCache {
        let inspector = artifactInspector ?? { [signedAt, now] _ in
            WDADeviceCache.Artifact(
                bundleIdentifier: "com.example.wda.xctrunner",
                teamIdentifier: "ZYXWV98765",
                signedAt: signedAt,
                provisioningExpiresAt: now.addingTimeInterval(86_400)
            )
        }
        return WDADeviceCache(
            home: home,
            metadataProvider: { metadata },
            artifactInspector: inspector,
            now: { [now] in now }
        )
    }

    private func makeHome() -> URL {
        let home = makeTempHome()
        homesToClean.append(home)
        return home
    }
}
