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
            ".sim-use/c311e5afe90ee702b80e8b64e1e12796e04e63a0/wda-derived-data"
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
                bundleIdentifier: "com.catchplay.wda.xctrunner",
                teamIdentifier: "MKK9DM2XD9",
                signedAt: signedAt,
                provisioningExpiresAt: now.addingTimeInterval(-1)
            )
        })
        XCTAssertEqual(expired.plan(for: tvInfo(), config: tvConfig()).missReason, .artifactExpired)

        let missingExpiration = makeCache(home: home, artifactInspector: { [signedAt] _ in
            .init(
                bundleIdentifier: "com.catchplay.wda.xctrunner",
                teamIdentifier: "MKK9DM2XD9",
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
                bundleIdentifier: "com.catchplay.wda.xctrunner",
                teamIdentifier: "OTHERTEAM1",
                signedAt: signedAt,
                provisioningExpiresAt: now.addingTimeInterval(86_400)
            )
        })
        XCTAssertEqual(wrongTeam.plan(for: tvInfo(), config: tvConfig()).missReason, .artifactIdentityMismatch)

        let wrongBundle = makeCache(home: home, artifactInspector: { [signedAt, now] _ in
            .init(
                bundleIdentifier: "com.example.other.xctrunner",
                teamIdentifier: "MKK9DM2XD9",
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

    // MARK: - Fixtures

    private func tvInfo() -> PhysicalDeviceInfo {
        PhysicalDeviceInfo(
            udid: "c311e5afe90ee702b80e8b64e1e12796e04e63a0",
            family: .tvos,
            osMajorVersion: 26,
            tunnelState: "connected",
            osVersion: "26.5"
        )
    }

    private func tvConfig() -> DeviceCapabilityConfig {
        DeviceCapabilityConfig(
            tvosWDABundleId: "com.catchplay.wda",
            xcodeOrgId: "MKK9DM2XD9",
            xcodeSigningId: "Apple Development"
        )
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
                bundleIdentifier: "com.catchplay.wda.xctrunner",
                teamIdentifier: "MKK9DM2XD9",
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
