// SPDX-License-Identifier: Apache-2.0
import CryptoKit
import Foundation
import SimUseCore

/// Per-physical-device WebDriverAgent build/signing cache.
///
/// A successful timestamp is diagnostic only. The fast path is selected
/// only when the complete build fingerprint still matches and the cached
/// runner app has a valid code signature, the expected Team/bundle id, and
/// a non-expired provisioning profile. Appium can then safely run
/// `test-without-building` via `usePrebuiltWDA`; a miss keeps the same
/// deterministic DerivedData directory so Xcode can still build
/// incrementally.
public struct WDADeviceCache: Sendable {
    public static let currentVersion = 1

    public struct HostMetadata: Codable, Equatable, Sendable {
        public let xcodeBuild: String
        public let wdaSourceSHA256: String

        public init(xcodeBuild: String, wdaSourceSHA256: String) {
            self.xcodeBuild = xcodeBuild
            self.wdaSourceSHA256 = wdaSourceSHA256
        }
    }

    public struct Fingerprint: Codable, Equatable, Sendable {
        public let deviceUDID: String
        public let platformName: String
        public let platformVersion: String
        public let xcodeBuild: String
        public let wdaSourceSHA256: String
        public let developmentTeam: String
        public let bundleIdentifier: String
        public let signingIdentity: String
        public let scheme: String

        public init(
            deviceUDID: String,
            platformName: String,
            platformVersion: String,
            xcodeBuild: String,
            wdaSourceSHA256: String,
            developmentTeam: String,
            bundleIdentifier: String,
            signingIdentity: String,
            scheme: String
        ) {
            self.deviceUDID = deviceUDID
            self.platformName = platformName
            self.platformVersion = platformVersion
            self.xcodeBuild = xcodeBuild
            self.wdaSourceSHA256 = wdaSourceSHA256
            self.developmentTeam = developmentTeam
            self.bundleIdentifier = bundleIdentifier
            self.signingIdentity = signingIdentity
            self.scheme = scheme
        }
    }

    public struct Artifact: Equatable, Sendable {
        public let bundleIdentifier: String
        public let teamIdentifier: String
        /// Modification time of the signed CodeResources/executable. This
        /// records when the cached artifact was signed; it never decides
        /// whether the artifact is trusted.
        public let signedAt: Date
        public let provisioningExpiresAt: Date?

        public init(
            bundleIdentifier: String,
            teamIdentifier: String,
            signedAt: Date,
            provisioningExpiresAt: Date?
        ) {
            self.bundleIdentifier = bundleIdentifier
            self.teamIdentifier = teamIdentifier
            self.signedAt = signedAt
            self.provisioningExpiresAt = provisioningExpiresAt
        }
    }

    public struct Record: Codable, Equatable, Sendable {
        public let version: Int
        public let fingerprint: Fingerprint
        public let signedAt: String
        public let provisioningExpiresAt: String?
        public let lastSuccessfulLaunchAt: String
        public let derivedDataPath: String
        public let runnerAppPath: String

        public init(
            version: Int = WDADeviceCache.currentVersion,
            fingerprint: Fingerprint,
            signedAt: String,
            provisioningExpiresAt: String?,
            lastSuccessfulLaunchAt: String,
            derivedDataPath: String,
            runnerAppPath: String
        ) {
            self.version = version
            self.fingerprint = fingerprint
            self.signedAt = signedAt
            self.provisioningExpiresAt = provisioningExpiresAt
            self.lastSuccessfulLaunchAt = lastSuccessfulLaunchAt
            self.derivedDataPath = derivedDataPath
            self.runnerAppPath = runnerAppPath
        }
    }

    public enum MissReason: String, Codable, Equatable, Sendable {
        case cacheDisabled
        case strategyNotCacheable
        case metadataUnavailable
        case recordMissing
        case recordUnreadable
        case fingerprintChanged
        case artifactMissing
        case artifactInvalid
        case artifactIdentityMismatch
        case artifactExpired
    }

    public struct Plan: Equatable, Sendable {
        public let fingerprint: Fingerprint?
        public let derivedDataPath: URL
        public let runnerAppPath: URL
        public let usePrebuiltWDA: Bool
        public let missReason: MissReason?

        public init(
            fingerprint: Fingerprint?,
            derivedDataPath: URL,
            runnerAppPath: URL,
            usePrebuiltWDA: Bool,
            missReason: MissReason?
        ) {
            self.fingerprint = fingerprint
            self.derivedDataPath = derivedDataPath
            self.runnerAppPath = runnerAppPath
            self.usePrebuiltWDA = usePrebuiltWDA
            self.missReason = missReason
        }
    }

    public enum ArtifactValidationError: Error, LocalizedError, Equatable, Sendable {
        case missing(String)
        case codesignInvalid(String)
        case metadataMissing(String)
        case commandFailed(String)

        public var errorDescription: String? {
            switch self {
            case .missing(let path):
                return "WDA runner artifact is missing at \(path)"
            case .codesignInvalid(let message):
                return "WDA runner code signature is invalid: \(message)"
            case .metadataMissing(let key):
                return "WDA runner signing metadata is missing \(key)"
            case .commandFailed(let message):
                return "Could not inspect WDA runner signing metadata: \(message)"
            }
        }
    }

    public enum RecordReadError: Error, LocalizedError, Equatable, Sendable {
        case missing(String)
        case corrupt(String)
        case versionMismatch(got: Int, expected: Int)
        case udidMismatch(got: String, expected: String)

        public var errorDescription: String? {
            switch self {
            case .missing(let path):
                return "No WDA signing cache exists at \(path)"
            case .corrupt(let path):
                return "WDA signing cache is unreadable at \(path)"
            case .versionMismatch(let got, let expected):
                return "WDA signing cache version mismatch (got \(got), expected \(expected))"
            case .udidMismatch(let got, let expected):
                return "WDA signing cache UDID mismatch (got \(got), expected \(expected))"
            }
        }
    }

    public typealias MetadataProvider = @Sendable () throws -> HostMetadata
    public typealias ArtifactInspector = @Sendable (URL) throws -> Artifact
    public typealias Clock = @Sendable () -> Date

    private let home: URL
    private let isEnabled: Bool
    private let metadataProvider: MetadataProvider
    private let artifactInspector: ArtifactInspector
    private let now: Clock

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        enabled: Bool = true,
        metadataProvider: @escaping MetadataProvider,
        artifactInspector: @escaping ArtifactInspector,
        now: @escaping Clock = { Date() }
    ) {
        self.home = home
        self.isEnabled = enabled
        self.metadataProvider = metadataProvider
        self.artifactInspector = artifactInspector
        self.now = now
    }

    /// A no-op dependency for deterministic unit tests and callers that
    /// explicitly opt out. Production `live` controllers inject `.live`.
    public static func disabled(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> WDADeviceCache {
        return WDADeviceCache(
            home: home,
            enabled: false,
            metadataProvider: { throw ArtifactValidationError.metadataMissing("host metadata") },
            artifactInspector: { throw ArtifactValidationError.missing($0.path) }
        )
    }

    public static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> WDADeviceCache {
        let disabledValues = ["0", "false", "no", "off"]
        let isEnabled = !disabledValues.contains(
            environment["SIM_USE_WDA_CACHE"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? ""
        )
        return WDADeviceCache(
            home: home,
            enabled: isEnabled,
            metadataProvider: {
                try liveHostMetadata(environment: environment, home: home)
            },
            artifactInspector: {
                try inspectLiveArtifact($0, environment: environment)
            }
        )
    }

    // MARK: - Paths

    public func directory(for udid: String) -> URL {
        home
            .appendingPathComponent(".sim-use", isDirectory: true)
            .appendingPathComponent(udid, isDirectory: true)
    }

    public func recordFile(for udid: String) -> URL {
        directory(for: udid).appendingPathComponent("wda-signing-cache.json")
    }

    public func derivedDataPath(for udid: String) -> URL {
        directory(for: udid).appendingPathComponent("wda-derived-data", isDirectory: true)
    }

    // MARK: - Plan / record

    public func plan(
        for info: PhysicalDeviceInfo,
        config: DeviceCapabilityConfig
    ) -> Plan {
        let derivedDataPath = derivedDataPath(for: info.udid)
        let runnerAppPath = Self.runnerAppPath(in: derivedDataPath, family: info.family)

        guard isEnabled else {
            return miss(
                .cacheDisabled,
                fingerprint: nil,
                derivedDataPath: derivedDataPath,
                runnerAppPath: runnerAppPath
            )
        }
        // The current iOS ≥17 branch uses an already-installed WDA and
        // never invokes xcodebuild. The host build cache is therefore only
        // meaningful for modern physical tvOS sessions.
        guard info.family == .tvos, info.isModern else {
            return miss(
                .strategyNotCacheable,
                fingerprint: nil,
                derivedDataPath: derivedDataPath,
                runnerAppPath: runnerAppPath
            )
        }
        guard let team = config.xcodeOrgId else {
            return miss(
                .metadataUnavailable,
                fingerprint: nil,
                derivedDataPath: derivedDataPath,
                runnerAppPath: runnerAppPath
            )
        }

        let metadata: HostMetadata
        do {
            metadata = try metadataProvider()
        } catch {
            return miss(
                .metadataUnavailable,
                fingerprint: nil,
                derivedDataPath: derivedDataPath,
                runnerAppPath: runnerAppPath
            )
        }
        let fingerprint = Fingerprint(
            deviceUDID: info.udid,
            platformName: "tvOS",
            platformVersion: info.osVersion ?? info.osMajorVersion.map(String.init) ?? "unknown",
            xcodeBuild: metadata.xcodeBuild,
            wdaSourceSHA256: metadata.wdaSourceSHA256,
            developmentTeam: team,
            bundleIdentifier: config.tvosWDABundleId,
            signingIdentity: config.xcodeSigningId,
            scheme: "WebDriverAgentRunner_tvOS"
        )

        let record: Record
        do {
            record = try readRecord(for: info.udid)
        } catch let error as RecordReadError {
            let reason: MissReason
            if case .missing = error {
                reason = .recordMissing
            } else {
                reason = .recordUnreadable
            }
            return miss(
                reason,
                fingerprint: fingerprint,
                derivedDataPath: derivedDataPath,
                runnerAppPath: runnerAppPath
            )
        } catch {
            return miss(
                .recordUnreadable,
                fingerprint: fingerprint,
                derivedDataPath: derivedDataPath,
                runnerAppPath: runnerAppPath
            )
        }

        guard record.fingerprint == fingerprint,
              record.derivedDataPath == derivedDataPath.path,
              record.runnerAppPath == runnerAppPath.path
        else {
            return miss(
                .fingerprintChanged,
                fingerprint: fingerprint,
                derivedDataPath: derivedDataPath,
                runnerAppPath: runnerAppPath
            )
        }
        guard FileManager.default.fileExists(atPath: runnerAppPath.path) else {
            return miss(
                .artifactMissing,
                fingerprint: fingerprint,
                derivedDataPath: derivedDataPath,
                runnerAppPath: runnerAppPath
            )
        }

        let artifact: Artifact
        do {
            artifact = try artifactInspector(runnerAppPath)
        } catch {
            return miss(
                .artifactInvalid,
                fingerprint: fingerprint,
                derivedDataPath: derivedDataPath,
                runnerAppPath: runnerAppPath
            )
        }
        guard Self.artifactIdentityMatches(artifact, fingerprint: fingerprint) else {
            return miss(
                .artifactIdentityMismatch,
                fingerprint: fingerprint,
                derivedDataPath: derivedDataPath,
                runnerAppPath: runnerAppPath
            )
        }
        guard let expires = artifact.provisioningExpiresAt else {
            return miss(
                .artifactInvalid,
                fingerprint: fingerprint,
                derivedDataPath: derivedDataPath,
                runnerAppPath: runnerAppPath
            )
        }
        if expires <= now() {
            return miss(
                .artifactExpired,
                fingerprint: fingerprint,
                derivedDataPath: derivedDataPath,
                runnerAppPath: runnerAppPath
            )
        }
        return Plan(
            fingerprint: fingerprint,
            derivedDataPath: derivedDataPath,
            runnerAppPath: runnerAppPath,
            usePrebuiltWDA: true,
            missReason: nil
        )
    }

    /// Persist a record only after Appium opened a real session and the
    /// resulting local artifact passes the same signature checks used by a
    /// cache hit. Returns nil when caching is disabled/unavailable.
    @discardableResult
    public func recordSuccessfulLaunch(_ plan: Plan) throws -> Record? {
        guard isEnabled, let fingerprint = plan.fingerprint else { return nil }
        guard FileManager.default.fileExists(atPath: plan.runnerAppPath.path) else {
            throw ArtifactValidationError.missing(plan.runnerAppPath.path)
        }
        let artifact = try artifactInspector(plan.runnerAppPath)
        guard Self.artifactIdentityMatches(artifact, fingerprint: fingerprint) else {
            throw ArtifactValidationError.metadataMissing("expected Team/bundle identifier")
        }
        guard let expires = artifact.provisioningExpiresAt else {
            throw ArtifactValidationError.metadataMissing("provisioning profile ExpirationDate")
        }
        if expires <= now() {
            throw ArtifactValidationError.codesignInvalid("provisioning profile has expired")
        }

        let record = Record(
            fingerprint: fingerprint,
            signedAt: Self.iso8601(artifact.signedAt),
            provisioningExpiresAt: artifact.provisioningExpiresAt.map(Self.iso8601),
            lastSuccessfulLaunchAt: Self.iso8601(now()),
            derivedDataPath: plan.derivedDataPath.path,
            runnerAppPath: plan.runnerAppPath.path
        )
        try writeRecord(record)
        return record
    }

    public func readRecord(for udid: String) throws -> Record {
        let url = recordFile(for: udid)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw RecordReadError.missing(url.path)
        }
        let record: Record
        do {
            record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: url))
        } catch {
            throw RecordReadError.corrupt(url.path)
        }
        guard record.version == Self.currentVersion else {
            throw RecordReadError.versionMismatch(got: record.version, expected: Self.currentVersion)
        }
        guard record.fingerprint.deviceUDID == udid else {
            throw RecordReadError.udidMismatch(got: record.fingerprint.deviceUDID, expected: udid)
        }
        return record
    }

    /// Invalidate only the small trust record. Keep DerivedData so the
    /// one repair attempt can be incremental rather than a clean rebuild.
    public func invalidate(udid: String) throws {
        let url = recordFile(for: udid)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Private cache helpers

    private func miss(
        _ reason: MissReason,
        fingerprint: Fingerprint?,
        derivedDataPath: URL,
        runnerAppPath: URL
    ) -> Plan {
        Plan(
            fingerprint: fingerprint,
            derivedDataPath: derivedDataPath,
            runnerAppPath: runnerAppPath,
            usePrebuiltWDA: false,
            missReason: reason
        )
    }

    private func writeRecord(_ record: Record) throws {
        let directory = directory(for: record.fingerprint.deviceUDID)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(record)
        let target = recordFile(for: record.fingerprint.deviceUDID)
        let temporary = directory.appendingPathComponent(
            "wda-signing-cache.json.\(UUID().uuidString).tmp"
        )
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        if FileManager.default.fileExists(atPath: target.path) {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: target)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }

    private static func artifactIdentityMatches(
        _ artifact: Artifact,
        fingerprint: Fingerprint
    ) -> Bool {
        let expectedBundleIds = [
            fingerprint.bundleIdentifier,
            "\(fingerprint.bundleIdentifier).xctrunner",
        ]
        return artifact.teamIdentifier == fingerprint.developmentTeam
            && expectedBundleIds.contains(artifact.bundleIdentifier)
    }

    private static func runnerAppPath(
        in derivedDataPath: URL,
        family: Device.Platform
    ) -> URL {
        let product: String
        switch family {
        case .tvos:
            product = "Debug-appletvos/WebDriverAgentRunner_tvOS-Runner.app"
        case .ios, .android:
            product = "Debug-iphoneos/WebDriverAgentRunner-Runner.app"
        }
        return derivedDataPath
            .appendingPathComponent("Build/Products", isDirectory: true)
            .appendingPathComponent(product, isDirectory: true)
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    // MARK: - Live metadata / signature inspection

    private static func liveHostMetadata(
        environment: [String: String],
        home: URL
    ) throws -> HostMetadata {
        let xcode = try run(
            executable: "/usr/bin/xcodebuild",
            arguments: ["-version"],
            environment: environment
        )
        guard xcode.status == 0 else {
            throw ArtifactValidationError.commandFailed(
                nonBlank(xcode.stderr) ?? nonBlank(xcode.stdout) ?? "xcodebuild -version exited \(xcode.status)"
            )
        }
        let xcodeBuild = xcode.stdout
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .joined(separator: "; ")

        let appiumHome: URL
        if let raw = environment["APPIUM_HOME"], !raw.isEmpty {
            appiumHome = URL(fileURLWithPath: raw, isDirectory: true)
        } else {
            appiumHome = home.appendingPathComponent(".appium", isDirectory: true)
        }
        let sourceRoot: URL
        if let raw = environment["SIM_USE_WDA_SOURCE_ROOT"], !raw.isEmpty {
            sourceRoot = URL(fileURLWithPath: raw, isDirectory: true)
        } else {
            sourceRoot = appiumHome
                .appendingPathComponent("node_modules/appium-xcuitest-driver/node_modules/appium-webdriveragent")
        }
        return HostMetadata(
            xcodeBuild: xcodeBuild,
            wdaSourceSHA256: try sourceFingerprint(root: sourceRoot)
        )
    }

    private static func sourceFingerprint(root: URL) throws -> String {
        let fileManager = FileManager.default
        let roots = [
            root.appendingPathComponent("Configurations", isDirectory: true),
            root.appendingPathComponent("PrivateHeaders", isDirectory: true),
            root.appendingPathComponent("WebDriverAgentLib", isDirectory: true),
            root.appendingPathComponent("WebDriverAgentRunner", isDirectory: true),
            root.appendingPathComponent("WebDriverAgent.xcodeproj", isDirectory: true),
            root.appendingPathComponent("Scripts", isDirectory: true),
            root.appendingPathComponent("package.json"),
        ]
        var files: [URL] = []
        for candidate in roots {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory) else {
                continue
            }
            if !isDirectory.boolValue {
                files.append(candidate)
                continue
            }
            guard let enumerator = fileManager.enumerator(
                at: candidate,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let file as URL in enumerator {
                if (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                    files.append(file)
                }
            }
        }
        guard !files.isEmpty else {
            throw ArtifactValidationError.missing(root.path)
        }
        files.sort { $0.path < $1.path }

        var hasher = SHA256()
        for file in files {
            let relative = file.path.hasPrefix(root.path)
                ? String(file.path.dropFirst(root.path.count))
                : file.path
            hasher.update(data: Data(relative.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: try Data(contentsOf: file, options: [.mappedIfSafe]))
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func inspectLiveArtifact(
        _ app: URL,
        environment: [String: String]
    ) throws -> Artifact {
        guard FileManager.default.fileExists(atPath: app.path) else {
            throw ArtifactValidationError.missing(app.path)
        }
        let verification = try run(
            executable: "/usr/bin/codesign",
            arguments: ["--verify", "--deep", "--strict", app.path],
            environment: environment
        )
        guard verification.status == 0 else {
            throw ArtifactValidationError.codesignInvalid(
                nonBlank(verification.stderr)
                    ?? nonBlank(verification.stdout)
                    ?? "codesign exited \(verification.status)"
            )
        }

        let infoURL = app.appendingPathComponent("Info.plist")
        guard let info = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: infoURL),
            options: [],
            format: nil
        ) as? [String: Any],
              let bundleIdentifier = info["CFBundleIdentifier"] as? String
        else {
            throw ArtifactValidationError.metadataMissing("CFBundleIdentifier")
        }

        let profileURL = app.appendingPathComponent("embedded.mobileprovision")
        let profileResult = try run(
            executable: "/usr/bin/security",
            arguments: ["cms", "-D", "-i", profileURL.path],
            environment: environment
        )
        guard profileResult.status == 0,
              let profileData = profileResult.stdout.data(using: .utf8),
              let profile = try PropertyListSerialization.propertyList(
                from: profileData,
                options: [],
                format: nil
              ) as? [String: Any]
        else {
            throw ArtifactValidationError.commandFailed(
                nonBlank(profileResult.stderr)
                    ?? nonBlank(profileResult.stdout)
                    ?? "security cms exited \(profileResult.status)"
            )
        }
        guard let teamIdentifier = (profile["TeamIdentifier"] as? [String])?.first else {
            throw ArtifactValidationError.metadataMissing("TeamIdentifier")
        }
        let expiresAt = profile["ExpirationDate"] as? Date

        let codeResources = app.appendingPathComponent("_CodeSignature/CodeResources")
        let executableName = info["CFBundleExecutable"] as? String
        let executable = executableName.map { app.appendingPathComponent($0) }
        let timestampCandidate: URL
        if FileManager.default.fileExists(atPath: codeResources.path) {
            timestampCandidate = codeResources
        } else if let executable {
            timestampCandidate = executable
        } else {
            throw ArtifactValidationError.metadataMissing("CFBundleExecutable")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: timestampCandidate.path)
        guard let signedAt = attributes[.modificationDate] as? Date else {
            throw ArtifactValidationError.metadataMissing("signature modification date")
        }
        return Artifact(
            bundleIdentifier: bundleIdentifier,
            teamIdentifier: teamIdentifier,
            signedAt: signedAt,
            provisioningExpiresAt: expiresAt
        )
    }

    private struct ProcessResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private static func run(
        executable: String,
        arguments: [String],
        environment: [String: String]
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw ArtifactValidationError.commandFailed(error.localizedDescription)
        }
        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ProcessResult(
            status: process.terminationStatus,
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self)
        )
    }

    private static func nonBlank(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
