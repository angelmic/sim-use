// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import SimUseCore

/// Immutable launch contract for the long-lived tvOS WebDriverAgent
/// supervisor. The local and remote ports are deliberately separate:
/// Appium attaches to `wdaURL`, while WDA itself receives `USE_PORT` from
/// `remotePort`.
public struct TVOSWDASupervisorPlan: Equatable, Sendable {
    public let udid: String
    public let targetBundleId: String
    public let runnerBundleId: String
    public let xctestBundleId: String
    public let localPort: Int
    public let remotePort: Int
    public let tunnelRegistryPort: Int?
    public let nodeExecutableURL: URL
    public let remoteXPCModuleURL: URL
    public let loaderURL: URL
    public let launcherURL: URL
    public let stateDirectory: URL
    public let startupTimeoutMs: Int
    public let keepAliveTimeoutMs: Int

    public init(
        udid: String,
        targetBundleId: String,
        wdaBundleId: String,
        xctestBundleId: String = "WebDriverAgentRunner_tvOS",
        localPort: Int,
        remotePort: Int,
        tunnelRegistryPort: Int? = nil,
        nodeExecutableURL: URL,
        remoteXPCModuleURL: URL,
        loaderURL: URL,
        launcherURL: URL,
        stateDirectory: URL,
        startupTimeoutMs: Int = 60_000,
        keepAliveTimeoutMs: Int = 604_800_000
    ) {
        self.udid = udid
        self.targetBundleId = targetBundleId
        self.runnerBundleId = wdaBundleId.hasSuffix(".xctrunner")
            ? wdaBundleId
            : "\(wdaBundleId).xctrunner"
        self.xctestBundleId = xctestBundleId
        self.localPort = localPort
        self.remotePort = remotePort
        self.tunnelRegistryPort = tunnelRegistryPort
        self.nodeExecutableURL = nodeExecutableURL
        self.remoteXPCModuleURL = remoteXPCModuleURL
        self.loaderURL = loaderURL
        self.launcherURL = launcherURL
        self.stateDirectory = stateDirectory
        self.startupTimeoutMs = startupTimeoutMs
        self.keepAliveTimeoutMs = keepAliveTimeoutMs
    }

    public var wdaURL: URL {
        // The initializer accepts only integer ports, and localhost is a
        // fixed valid host. Keep this non-optional for capability assembly.
        URL(string: "http://127.0.0.1:\(localPort)")!
    }

    public var launchEnvironment: [String: String] {
        [
            "USE_PORT": String(remotePort),
            "MJPEG_SERVER_PORT": String(remotePort + 1000),
            "WDA_PRODUCT_BUNDLE_IDENTIFIER": runnerBundleId,
        ]
    }

    public var processEnvironment: [String: String] {
        var result = [
            "SIM_USE_WDA_SUPERVISOR": "1",
            // The supervisor intentionally uses Node's scoped ESM loader.
            // Keep its experimental-loader warning out of the persistent
            // per-device log without changing the caller's Node settings.
            "NODE_NO_WARNINGS": "1",
        ]
        if let tunnelRegistryPort {
            result["APPIUM_TUNNEL_REGISTRY_PORT"] = String(tunnelRegistryPort)
        }
        return result
    }

    public var arguments: [String] {
        [
            "--experimental-loader", loaderURL.path,
            launcherURL.path,
            "--module", remoteXPCModuleURL.path,
            "--udid", udid,
            "--runner-bundle-id", runnerBundleId,
            "--target-bundle-id", targetBundleId,
            "--xctest-bundle-id", xctestBundleId,
            "--local-port", String(localPort),
            "--remote-port", String(remotePort),
            "--timeout-ms", String(keepAliveTimeoutMs),
        ]
    }

    public var stateFile: URL {
        stateDirectory.appendingPathComponent("tvos-wda-supervisor.json")
    }

    public var lockFile: URL {
        stateDirectory.appendingPathComponent("tvos-wda-supervisor.lock")
    }

    public var logFile: URL {
        stateDirectory.appendingPathComponent("tvos-wda-supervisor.log")
    }
}

/// Injectable endpoint source used by TVOSDeviceController. Tests can
/// provide a deterministic URL without starting a process; production uses
/// the per-device supervisor below.
public struct TVOSWDAEndpointProvider: @unchecked Sendable {
    public typealias Prepare = @Sendable (
        PhysicalDeviceInfo,
        String,
        DeviceCapabilityConfig
    ) async throws -> URL?

    private let prepare: Prepare

    public init(_ prepare: @escaping Prepare) {
        self.prepare = prepare
    }

    public func endpoint(
        for info: PhysicalDeviceInfo,
        targetBundleId: String,
        config: DeviceCapabilityConfig
    ) async throws -> URL? {
        try await prepare(info, targetBundleId, config)
    }

    public static func disabled() -> TVOSWDAEndpointProvider {
        TVOSWDAEndpointProvider { _, _, _ in nil }
    }

    public static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> TVOSWDAEndpointProvider {
        let supervisor = TVOSWDASupervisor(environment: environment, home: home)
        return TVOSWDAEndpointProvider { info, bundleId, config in
            try await supervisor.ensureEndpoint(
                for: info,
                targetBundleId: bundleId,
                config: config
            )
        }
    }
}

public enum TVOSWDASupervisorError: Error, LocalizedError, HintProviding, Equatable {
    case invalidConfiguration(String)
    case nodeMissing
    case remoteXPCModuleMissing([String])
    case resourceMissing(String)
    case portOccupied(port: Int, productBundleIdentifier: String?)
    case startupFailed(udid: String, logPath: String, detail: String, registryPort: Int?)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let detail):
            return "Invalid tvOS WDA supervisor configuration: \(detail)"
        case .nodeMissing:
            return "The tvOS WDA supervisor could not find a Node.js executable."
        case .remoteXPCModuleMissing:
            return "The installed XCUITest driver does not contain appium-ios-remotexpc."
        case .resourceMissing(let name):
            return "The sim-use installation is missing its tvOS WDA supervisor resource: \(name)."
        case .portOccupied(let port, let product):
            let owner = product.map { " by WDA \($0)" } ?? ""
            return "Local WDA port \(port) is already occupied\(owner), not by the requested runner."
        case .startupFailed(let udid, _, let detail, _):
            return "Could not start the installed tvOS WebDriverAgent on \(udid): \(detail)"
        }
    }

    public var hint: String? {
        switch self {
        case .invalidConfiguration:
            return "Use ports in 1...65535. Set SIM_USE_WDA_LOCAL_PORT for the Mac-side URL and SIM_USE_WDA_REMOTE_PORT for the device-side WDA listener."
        case .nodeMissing:
            return "Install Node.js or point SIM_USE_NODE_PATH at an executable Node binary."
        case .remoteXPCModuleMissing(let candidates):
            return "Install/update Appium's XCUITest driver, or set SIM_USE_REMOTEXPC_MODULE to its build/src/index.js. Checked: \(candidates.joined(separator: ", "))"
        case .resourceMissing:
            return "Rebuild/reinstall the fork with scripts/build.sh so SimUse_DeviceBackend.bundle is staged beside the sim-use binary."
        case .portOccupied(let port, _):
            return "Choose a free task-owned Mac port, e.g. `export SIM_USE_WDA_LOCAL_PORT=\(port + 1)`. Do not stop an unrelated WDA."
        case .startupFailed(let udid, let logPath, _, let registryPort):
            let portArgument = registryPort.map { " --tunnel-registry-port \($0)" } ?? ""
            return "Inspect \(logPath). Ensure the RemoteXPC tunnel owns this Apple TV, e.g. `sudo appium driver run xcuitest tunnel-creation --udid \(udid)\(portArgument)`, then retry. The installed runner must match SIM_USE_TVOS_WDA_BUNDLE_ID."
        }
    }
}

/// Starts and reuses one long-lived XCTest-backed WDA process per physical
/// Apple TV. It never edits Appium's installed JavaScript. A scoped ESM
/// loader corrects the upstream 60-second XCTest idle reaper and permits an
/// explicit registry port only inside this child process.
public struct TVOSWDASupervisor: Sendable {
    private let environment: [String: String]
    private let home: URL

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.environment = environment
        self.home = home
    }

    public func ensureEndpoint(
        for info: PhysicalDeviceInfo,
        targetBundleId: String,
        config: DeviceCapabilityConfig
    ) async throws -> URL? {
        guard info.family == .tvos, info.isModern, isEnabled else {
            return nil
        }
        let plan = try makePlan(
            info: info,
            targetBundleId: targetBundleId,
            config: config
        )
        try validate(plan)
        try FileManager.default.createDirectory(
            at: plan.stateDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let lockDescriptor = try await acquireLaunchLock(plan)
        defer {
            Darwin.close(lockDescriptor)
            Darwin.unlink(plan.lockFile.path)
        }

        switch await probe(plan.wdaURL) {
        case .ready(let product) where product == plan.runnerBundleId:
            try recordSuccess(plan: plan, pid: readRecord(plan)?.pid, status: "reused")
            return plan.wdaURL
        case .ready(let product), .occupied(let product):
            throw TVOSWDASupervisorError.portOccupied(
                port: plan.localPort,
                productBundleIdentifier: product
            )
        case .unreachable:
            break
        }

        stopStaleOwnedProcess(plan)
        let process = try launch(plan)
        try writeRecord(
            Record(
                pid: process.processIdentifier,
                plan: plan,
                startedAt: Self.iso8601(Date()),
                lastSuccessfulLaunchAt: nil,
                status: "starting"
            ),
            plan: plan
        )

        let deadline = Date().addingTimeInterval(Double(plan.startupTimeoutMs) / 1000)
        while Date() < deadline {
            switch await probe(plan.wdaURL) {
            case .ready(let product) where product == plan.runnerBundleId:
                try recordSuccess(plan: plan, pid: process.processIdentifier, status: "ready")
                return plan.wdaURL
            case .ready(let product), .occupied(let product):
                terminate(process)
                throw TVOSWDASupervisorError.portOccupied(
                    port: plan.localPort,
                    productBundleIdentifier: product
                )
            case .unreachable:
                break
            }
            if !process.isRunning {
                throw startupFailure(plan, detail: "supervisor exited before WDA became ready")
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }

        terminate(process)
        throw startupFailure(
            plan,
            detail: "WDA /status did not become ready within \(plan.startupTimeoutMs) ms"
        )
    }

    // MARK: - Plan

    private var isEnabled: Bool {
        let disabled = ["0", "false", "no", "off"]
        return !disabled.contains(
            environment["SIM_USE_TVOS_WDA_SUPERVISOR"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? ""
        )
    }

    private func makePlan(
        info: PhysicalDeviceInfo,
        targetBundleId: String,
        config: DeviceCapabilityConfig
    ) throws -> TVOSWDASupervisorPlan {
        let node = try resolveNode()
        let module = try resolveRemoteXPCModule()
        // For a macOS `.bundle`, `resourceURL` already resolves to its
        // `Resources/` directory. Do not append another `Resources`.
        guard let resourceRoot = Bundle.module.resourceURL else {
            throw TVOSWDASupervisorError.resourceMissing("Resources")
        }
        let loader = resourceRoot.appendingPathComponent("tvos-wda-esm-loader.mjs")
        let launcher = resourceRoot.appendingPathComponent("tvos-wda-supervisor.mjs")
        for resource in [loader, launcher] where !FileManager.default.fileExists(atPath: resource.path) {
            throw TVOSWDASupervisorError.resourceMissing(resource.lastPathComponent)
        }

        let registryPort = try optionalPort(
            environment["SIM_USE_TUNNEL_REGISTRY_PORT"],
            name: "SIM_USE_TUNNEL_REGISTRY_PORT"
        )
        let xctestBundleId = environment["SIM_USE_TVOS_WDA_XCTEST_BUNDLE_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty ?? "WebDriverAgentRunner_tvOS"
        let startupTimeoutMs = try positiveInteger(
            environment["SIM_USE_WDA_STARTUP_TIMEOUT_MS"],
            defaultValue: 60_000,
            name: "SIM_USE_WDA_STARTUP_TIMEOUT_MS"
        )
        let keepAliveTimeoutMs = try positiveInteger(
            environment["SIM_USE_WDA_KEEPALIVE_TIMEOUT_MS"],
            defaultValue: 604_800_000,
            name: "SIM_USE_WDA_KEEPALIVE_TIMEOUT_MS"
        )

        return TVOSWDASupervisorPlan(
            udid: info.udid,
            targetBundleId: targetBundleId,
            wdaBundleId: config.tvosWDABundleId,
            xctestBundleId: xctestBundleId,
            localPort: config.wdaLocalPort,
            remotePort: config.wdaRemotePort ?? 8100,
            tunnelRegistryPort: registryPort,
            nodeExecutableURL: node,
            remoteXPCModuleURL: module,
            loaderURL: loader,
            launcherURL: launcher,
            stateDirectory: home
                .appendingPathComponent(".sim-use", isDirectory: true)
                .appendingPathComponent(info.udid, isDirectory: true),
            startupTimeoutMs: startupTimeoutMs,
            keepAliveTimeoutMs: keepAliveTimeoutMs
        )
    }

    private func validate(_ plan: TVOSWDASupervisorPlan) throws {
        for (name, port) in [
            ("SIM_USE_WDA_LOCAL_PORT", plan.localPort),
            ("SIM_USE_WDA_REMOTE_PORT", plan.remotePort),
        ] where !(1...65535).contains(port) {
            throw TVOSWDASupervisorError.invalidConfiguration("\(name)=\(port)")
        }
        guard plan.remotePort <= 64535 else {
            throw TVOSWDASupervisorError.invalidConfiguration(
                "SIM_USE_WDA_REMOTE_PORT must leave room for MJPEG_SERVER_PORT=remote+1000"
            )
        }
    }

    private func resolveNode() throws -> URL {
        if let explicit = environment["SIM_USE_NODE_PATH"]?.nonEmpty {
            let url = URL(fileURLWithPath: explicit)
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                throw TVOSWDASupervisorError.nodeMissing
            }
            return url
        }
        let searchPath = environment["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in searchPath.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory), isDirectory: true)
                .appendingPathComponent("node")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        throw TVOSWDASupervisorError.nodeMissing
    }

    private func resolveRemoteXPCModule() throws -> URL {
        var candidates: [URL] = []
        if let explicit = environment["SIM_USE_REMOTEXPC_MODULE"]?.nonEmpty {
            candidates.append(URL(fileURLWithPath: explicit))
        }
        let appiumHome = environment["APPIUM_HOME"]?.nonEmpty
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent(".appium", isDirectory: true)
        candidates.append(
            appiumHome.appendingPathComponent(
                "node_modules/appium-xcuitest-driver/node_modules/appium-ios-remotexpc/build/src/index.js"
            )
        )
        candidates.append(
            appiumHome.appendingPathComponent(
                "node_modules/appium-ios-remotexpc/build/src/index.js"
            )
        )
        if let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            return found
        }
        throw TVOSWDASupervisorError.remoteXPCModuleMissing(candidates.map(\.path))
    }

    private func optionalPort(_ raw: String?, name: String) throws -> Int? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        guard let value = Int(raw), (1...65535).contains(value) else {
            throw TVOSWDASupervisorError.invalidConfiguration("\(name)=\(raw)")
        }
        return value
    }

    private func positiveInteger(
        _ raw: String?,
        defaultValue: Int,
        name: String
    ) throws -> Int {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return defaultValue
        }
        guard let value = Int(raw), value > 0 else {
            throw TVOSWDASupervisorError.invalidConfiguration("\(name)=\(raw)")
        }
        return value
    }

    // MARK: - Process lifecycle

    /// `O_EXCL` is the cross-process lock. The file contains the owning
    /// sim-use PID so a crash cannot strand it forever; a contender removes
    /// it only after that exact PID is no longer alive.
    private func acquireLaunchLock(_ plan: TVOSWDASupervisorPlan) async throws -> Int32 {
        let deadline = Date().addingTimeInterval(Double(plan.startupTimeoutMs) / 1000 + 5)
        while Date() < deadline {
            let descriptor = Darwin.open(
                plan.lockFile.path,
                O_CREAT | O_EXCL | O_WRONLY,
                0o600
            )
            if descriptor >= 0 {
                let owner = Data("\(Darwin.getpid())\n".utf8)
                owner.withUnsafeBytes { bytes in
                    _ = Darwin.write(descriptor, bytes.baseAddress, bytes.count)
                }
                return descriptor
            }
            guard errno == EEXIST else {
                throw TVOSWDASupervisorError.startupFailed(
                    udid: plan.udid,
                    logPath: plan.logFile.path,
                    detail: "could not create per-device launch lock (errno \(errno))",
                    registryPort: plan.tunnelRegistryPort
                )
            }
            if let text = try? String(contentsOf: plan.lockFile, encoding: .utf8),
               let owner = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
               owner > 0,
               Darwin.kill(owner, 0) != 0,
               errno == ESRCH
            {
                _ = Darwin.unlink(plan.lockFile.path)
                continue
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw TVOSWDASupervisorError.startupFailed(
            udid: plan.udid,
            logPath: plan.logFile.path,
            detail: "timed out waiting for another sim-use WDA launch to finish",
            registryPort: plan.tunnelRegistryPort
        )
    }

    private func launch(_ plan: TVOSWDASupervisorPlan) throws -> Process {
        if !FileManager.default.fileExists(atPath: plan.logFile.path) {
            FileManager.default.createFile(
                atPath: plan.logFile.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
        }
        let logHandle = try FileHandle(forWritingTo: plan.logFile)
        try logHandle.seekToEnd()

        let process = Process()
        process.executableURL = plan.nodeExecutableURL
        process.arguments = plan.arguments
        var childEnvironment = environment
        for (key, value) in plan.processEnvironment {
            childEnvironment[key] = value
        }
        process.environment = childEnvironment
        process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = logHandle
        process.standardError = logHandle
        do {
            try process.run()
            try logHandle.close()
            return process
        } catch {
            try? logHandle.close()
            throw TVOSWDASupervisorError.startupFailed(
                udid: plan.udid,
                logPath: plan.logFile.path,
                detail: error.localizedDescription,
                registryPort: plan.tunnelRegistryPort
            )
        }
    }

    private func stopStaleOwnedProcess(_ plan: TVOSWDASupervisorPlan) {
        guard let record = readRecord(plan),
              record.pid > 0,
              Darwin.kill(record.pid, 0) == 0,
              record.udid == plan.udid,
              record.runnerBundleId == plan.runnerBundleId,
              record.localPort == plan.localPort,
              processCommand(pid: record.pid).contains(plan.launcherURL.path),
              processCommand(pid: record.pid).contains(plan.udid)
        else { return }
        _ = Darwin.kill(record.pid, SIGTERM)
    }

    private func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
    }

    private func processCommand(pid: Int32) -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "command="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return String(
                data: output.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
        } catch {
            return ""
        }
    }

    // MARK: - Health / records

    private enum Probe {
        case ready(productBundleIdentifier: String?)
        case occupied(productBundleIdentifier: String?)
        case unreachable
    }

    private func probe(_ baseURL: URL) async -> Probe {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1
        configuration.timeoutIntervalForResource = 1
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let statusURL = baseURL.appendingPathComponent("status")
        do {
            let (data, response) = try await session.data(from: statusURL)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let value = root["value"] as? [String: Any]
            else {
                return .occupied(productBundleIdentifier: nil)
            }
            let build = value["build"] as? [String: Any]
            let product = build?["productBundleIdentifier"] as? String
            if value["ready"] as? Bool == true || value["state"] as? String == "success" {
                return .ready(productBundleIdentifier: product)
            }
            return .occupied(productBundleIdentifier: product)
        } catch {
            return .unreachable
        }
    }

    private struct Record: Codable {
        let version: Int
        let pid: Int32
        let udid: String
        let targetBundleId: String
        let runnerBundleId: String
        let xctestBundleId: String
        let localPort: Int
        let remotePort: Int
        let tunnelRegistryPort: Int?
        let remoteXPCModulePath: String
        let startedAt: String
        let lastSuccessfulLaunchAt: String?
        let status: String

        init(
            pid: Int32?,
            plan: TVOSWDASupervisorPlan,
            startedAt: String,
            lastSuccessfulLaunchAt: String?,
            status: String
        ) {
            version = 1
            self.pid = pid ?? 0
            udid = plan.udid
            targetBundleId = plan.targetBundleId
            runnerBundleId = plan.runnerBundleId
            xctestBundleId = plan.xctestBundleId
            localPort = plan.localPort
            remotePort = plan.remotePort
            tunnelRegistryPort = plan.tunnelRegistryPort
            remoteXPCModulePath = plan.remoteXPCModuleURL.path
            self.startedAt = startedAt
            self.lastSuccessfulLaunchAt = lastSuccessfulLaunchAt
            self.status = status
        }
    }

    private func readRecord(_ plan: TVOSWDASupervisorPlan) -> Record? {
        guard let data = try? Data(contentsOf: plan.stateFile) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    private func recordSuccess(
        plan: TVOSWDASupervisorPlan,
        pid: Int32?,
        status: String
    ) throws {
        let previous = readRecord(plan)
        try writeRecord(
            Record(
                pid: pid,
                plan: plan,
                startedAt: previous?.startedAt ?? Self.iso8601(Date()),
                lastSuccessfulLaunchAt: Self.iso8601(Date()),
                status: status
            ),
            plan: plan
        )
    }

    private func writeRecord(_ record: Record, plan: TVOSWDASupervisorPlan) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(record)
        try data.write(to: plan.stateFile, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: plan.stateFile.path
        )
    }

    private func startupFailure(
        _ plan: TVOSWDASupervisorPlan,
        detail: String
    ) -> TVOSWDASupervisorError {
        let tail: String
        if let data = try? Data(contentsOf: plan.logFile) {
            tail = String(decoding: data.suffix(16_384), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            tail = ""
        }
        let combined = tail.isEmpty ? detail : "\(detail). Log tail: \(tail)"
        return .startupFailed(
            udid: plan.udid,
            logPath: plan.logFile.path,
            detail: combined,
            registryPort: plan.tunnelRegistryPort
        )
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

extension String {
    fileprivate var nonEmpty: String? { isEmpty ? nil : self }
}
