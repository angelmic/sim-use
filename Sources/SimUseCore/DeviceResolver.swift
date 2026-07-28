// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Resolves the device identifier (Apple Simulator UDID or Android adb
/// serial) a device-scoped command should run against when the user
/// does not pass `--device` (or its deprecated alias `--udid`)
/// explicitly. Resolution order:
///
///   1. Explicit `--device <X>` / `--udid <X>` (caller's responsibility,
///      not seen here).
///   2. `SIM_USE_DEVICE` or `SIM_USE_UDID` environment variable —
///      per-shell-session override. Setting both is a fast-fail.
///   3. Exactly one live sim-use daemon under `/tmp/sim-use-<uid>/` — the
///      "you've been working on this simulator already" steady-state path.
///      Cost: <1 ms (a directory scan + a few stat() calls).
///   4. Exactly one simulator with `state == "Booted"` per
///      `xcrun simctl list devices booted -j`. Cost: ~150 ms (one
///      forked subprocess).
///
/// 0 / >1 results at step 3 fall through to step 4. 0 / >1 booted at
/// step 4 surface a `ResolutionError` with the list of booted UDIDs so
/// the agent can self-correct without another `list-simulators` call.
public struct DeviceResolver {

    public enum ResolutionError: LocalizedError, HintProviding {
        case noSimulatorBooted
        case multipleSimulatorsBooted(udids: [String], names: [String: String])
        case simctlFailed(message: String)
        case conflictingEnvVars

        public var errorDescription: String? {
            switch self {
            case .noSimulatorBooted:
                return "No simulator is booted. Boot one in Simulator.app (or with `xcrun simctl boot <UDID>`) and retry, or pass `--device <UDID>` explicitly."
            case .multipleSimulatorsBooted(let udids, let names):
                // Inline the booted list directly into the error message so
                // the user sees actionable info without having to look at
                // --json hint. Format: "<name> (<udid>); <name> (<udid>)".
                let formatted = udids.map { udid -> String in
                    if let name = names[udid] { return "\(name) (\(udid))" }
                    return udid
                }.joined(separator: "; ")
                return "Multiple simulators are booted (\(udids.count)): \(formatted). Pass `--device <UDID>` or set the SIM_USE_DEVICE environment variable to disambiguate."
            case .simctlFailed(let message):
                return "Failed to list booted simulators via simctl: \(message). Pass `--device <UDID>` explicitly to skip auto-resolution."
            case .conflictingEnvVars:
                return "Both SIM_USE_DEVICE and SIM_USE_UDID are set. Unset one — they are aliases."
            }
        }

        public var hint: String? {
            switch self {
            case .noSimulatorBooted, .simctlFailed, .conflictingEnvVars:
                return nil
            case .multipleSimulatorsBooted(let udids, let names):
                let pairs = udids.map { udid -> String in
                    if let name = names[udid] { return "\(name) (\(udid))" }
                    return udid
                }
                return "booted simulators: \(pairs.joined(separator: "; "))"
            }
        }
    }

    /// Source of booted-simulator information. Prod uses `simctl`; tests
    /// inject a fixture closure so the resolver can be unit-tested without
    /// a real Xcode toolchain on the box.
    public typealias BootedListProvider = () throws -> [BootedSimulator]

    public struct BootedSimulator: Equatable {
        public let udid: String
        public let name: String

        public init(udid: String, name: String) {
            self.udid = udid
            self.name = name
        }
    }

    public static func resolve(
        explicit: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        baseDirectory: URL? = nil,
        bootedListProvider: BootedListProvider = simctlBootedListProvider
    ) throws -> String {
        // 1. Explicit --device / --udid wins, after a trim so a stray
        // space doesn't accidentally bypass auto-resolution.
        if let explicit, !explicit.trimmingCharacters(in: .whitespaces).isEmpty {
            return explicit.trimmingCharacters(in: .whitespaces)
        }

        // 2. Per-shell override. SIM_USE_DEVICE is preferred; SIM_USE_UDID
        // remains accepted as a deprecated alias. Setting both is a
        // fast-fail so we never silently pick one over the other.
        let envDevice = environment["SIM_USE_DEVICE"]?
            .trimmingCharacters(in: .whitespaces)
            .nonEmptyOrNil
        let envUDID = environment["SIM_USE_UDID"]?
            .trimmingCharacters(in: .whitespaces)
            .nonEmptyOrNil
        if envDevice != nil && envUDID != nil {
            throw ResolutionError.conflictingEnvVars
        }
        if let env = envDevice ?? envUDID {
            return env
        }

        // 3. Single live daemon — steady-state fast path. After the first
        // command in an agent session this hits and avoids the simctl fork.
        // A base directory that fails validation throws here: resolution
        // must not be steered by forged pidfiles in a pre-planted tree.
        let daemons = try DaemonPaths.enumerateLiveDaemons(baseDirectory: baseDirectory)
        if daemons.count == 1 {
            return daemons[0].udid
        }

        // 4. Cold path: ask simctl. The provider is injectable so tests
        // do not need an Xcode toolchain on the box.
        let booted: [BootedSimulator]
        do {
            booted = try bootedListProvider()
        } catch let error as ResolutionError {
            throw error
        } catch {
            throw ResolutionError.simctlFailed(message: error.localizedDescription)
        }

        switch booted.count {
        case 1:
            return booted[0].udid
        case 0:
            throw ResolutionError.noSimulatorBooted
        default:
            let names = Dictionary(uniqueKeysWithValues: booted.map { ($0.udid, $0.name) })
            throw ResolutionError.multipleSimulatorsBooted(
                udids: booted.map(\.udid),
                names: names
            )
        }
    }

    /// Production booted-list provider. Spawns `xcrun simctl list devices
    /// booted -j` and parses the JSON. Errors map to `ResolutionError.simctlFailed`.
    public static let simctlBootedListProvider: BootedListProvider = {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "list", "devices", "booted", "-j"]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw ResolutionError.simctlFailed(message: "could not spawn simctl: \(error.localizedDescription)")
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ResolutionError.simctlFailed(
                message: "simctl exited \(process.terminationStatus): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
        }

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        return try parseSimctlBootedJSON(data)
    }

    /// Append `--device <value>` to `args` when neither `--device` nor
    /// `--udid` (with or without the `=value` form) is already present.
    /// Used by the client-side `run()` to forward the resolved device id
    /// across the daemon socket so the daemon-side parse sees an
    /// explicit value (the daemon process cannot rely on the same
    /// single-booted-simulator contract the client used to resolve in
    /// the first place). Idempotent.
    ///
    /// Forwards as `--device` (the new canonical name). Daemon binaries
    /// built before `--device` was accepted must be restarted
    /// (`sim-use daemon stop`) after the client upgrade so the daemon
    /// process picks up the new parser.
    public static func injectingDeviceIfNeeded(_ args: [String], device: String) -> [String] {
        if args.contains("--device") || args.contains("--udid") { return args }
        if args.contains(where: { $0.hasPrefix("--device=") || $0.hasPrefix("--udid=") }) {
            return args
        }
        return args + ["--device", device]
    }

    /// Parses the JSON shape emitted by `simctl list devices booted -j`:
    ///
    ///   { "devices": { "<runtime>": [ { "udid": "...", "name": "...", ... }, ... ], ... } }
    ///
    /// Only `state == "Booted"` devices show up under `booted`, so we
    /// flatten across runtimes and trust simctl's filter.
    public static func parseSimctlBootedJSON(_ data: Data) throws -> [BootedSimulator] {
        struct Device: Decodable {
            public let udid: String
            public let name: String
        }
        struct Envelope: Decodable {
            public let devices: [String: [Device]]
        }

        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw ResolutionError.simctlFailed(message: "could not parse simctl JSON: \(error.localizedDescription)")
        }

        return envelope.devices
            .values
            .flatMap { $0 }
            .map { BootedSimulator(udid: $0.udid, name: $0.name) }
            .sorted { $0.udid < $1.udid }
    }
}

extension String {
    fileprivate var nonEmptyOrNil: String? { isEmpty ? nil : self }
}

/// Enumerates *physical* Apple devices (iOS/tvOS) for the `sim-use devices`
/// verb and, later, the device backend (T3). Complements `DeviceResolver`
/// (booted Simulators) and `SimctlDeviceLister` (all Simulators): those never
/// see a cabled iPhone or a paired Apple TV.
///
/// Two sources, merged and deduped by UDID:
///
///   • `xcrun devicectl list devices --json-output <tmp>` — modern
///     (Xcode 16+), rich metadata. devicectl writes the JSON to the
///     `--json-output` file (stdout gets a human table). The device UDID is
///     `hardwareProperties.udid`; the top-level `identifier` is the
///     CoreDevice UUID and must NOT be used as the UDID.
///   • `idevice_id -l` — libimobiledevice's classic USB path. One bare UDID
///     per line. A matching devicectl row keeps its rich metadata but is
///     promoted to the effective "connected" state because the USB probe is
///     live; a device only it reports becomes a minimal row. Skipped when
///     `idevice_id` isn't installed (the runner returns [] on the `env`
///     exit-127 "command not found").
public enum AppleDeviceLister {
    public enum ListerError: Error, LocalizedError {
        case parseFailed(String)

        public var errorDescription: String? {
            switch self {
            case .parseFailed(let m): return "could not parse devicectl JSON: \(m)"
            }
        }
    }

    // MARK: - devicectl JSON parsing

    /// Parse the payload written by `devicectl list devices --json-output`.
    public static func parseDevicectlJSON(_ data: Data) throws -> [Device] {
        struct Envelope: Decodable { let result: ResultBlock }
        struct ResultBlock: Decodable { let devices: [Dev] }
        struct Dev: Decodable {
            let deviceProperties: DeviceProps
            let hardwareProperties: HardwareProps
            let connectionProperties: ConnectionProps?
        }
        struct DeviceProps: Decodable { let name: String; let osVersionNumber: String? }
        struct HardwareProps: Decodable { let udid: String; let platform: String?; let deviceType: String? }
        struct ConnectionProps: Decodable { let tunnelState: String? }

        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw ListerError.parseFailed(error.localizedDescription)
        }

        return envelope.result.devices.map { dev in
            let isTV = deviceIsTV(
                platform: dev.hardwareProperties.platform,
                deviceType: dev.hardwareProperties.deviceType
            )
            let platform: Device.Platform = isTV ? .tvos : .ios
            // tunnelState is the reachability signal Device.isUsable keys off
            // ("connected" ⇒ usable). Absent ⇒ treat as not reachable.
            let state = dev.connectionProperties?.tunnelState ?? "unavailable"
            let family = isTV ? "tvOS" : "iOS"
            let runtime = dev.deviceProperties.osVersionNumber.map { "\(family) \($0)" }
            return Device(
                udid: dev.hardwareProperties.udid,
                name: dev.deviceProperties.name,
                platform: platform,
                state: state,
                runtime: runtime,
                target: .device
            )
        }
        .sorted { $0.udid < $1.udid }
    }

    /// iOS vs tvOS from devicectl's hardware fields. iPhone/iPad report
    /// platform `iOS`; Apple TV reports `tvOS` / deviceType `appleTV`. None
    /// of iPhone/iPad/iOS contains "tv", so the substring test is safe.
    static func deviceIsTV(platform: String?, deviceType: String?) -> Bool {
        let hay = "\(platform ?? "") \(deviceType ?? "")".lowercased()
        return hay.contains("tv")
    }

    // MARK: - idevice_id merge

    /// Fold bare `idevice_id -l` UDIDs into the devicectl rows: dedupe by
    /// UDID while keeping the richer devicectl metadata, promote a matching
    /// row to the effective "connected" state, and add a minimal `.device`
    /// row for any UDID only libimobiledevice knows about.
    ///
    /// The promotion matters when CoreDevice's cached/local-network row is
    /// stuck at "connecting" even though usbmux can currently reach the
    /// cabled device. `idevice_id -l` only emits live USB attachments, so it
    /// is a stronger reachability signal for that overlap without forcing us
    /// to discard devicectl's name/platform/runtime metadata.
    public static func mergeIdeviceIDUDIDs(into devices: [Device], udids: [String]) -> [Device] {
        let reachableUDIDs = Set(
            udids
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        let promoted = devices.map { device in
            guard reachableUDIDs.contains(device.udid),
                  device.target == .device,
                  device.state != Device.State.deviceConnected
            else { return device }
            return Device(
                udid: device.udid,
                name: device.name,
                platform: device.platform,
                state: Device.State.deviceConnected,
                runtime: device.runtime,
                target: device.target
            )
        }
        let known = Set(promoted.map(\.udid))
        let extras = reachableUDIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !known.contains($0) }
            .sorted()
            .map { udid in
                Device(
                    udid: udid,
                    name: udid,
                    platform: .ios,
                    state: Device.State.deviceConnected,
                    runtime: nil,
                    target: .device
                )
            }
        return promoted + extras
    }

    // MARK: - live enumeration

    /// The merged physical-device list. Resilient by design: a devicectl
    /// failure or a missing idevice_id degrades to fewer rows, never an
    /// error — the `devices` verb must still list Simulators.
    public static func listPhysicalDevices() -> [Device] {
        listPhysicalDevices(
            devicectlProvider: runDevicectl,
            ideviceIDProvider: runIdeviceID,
            devicectlDetailsProvider: runDevicectlDetails
        )
    }

    /// Injectable seam behind `listPhysicalDevices()`. Internal so tests can
    /// drive the merge without spawning `devicectl` / `idevice_id`; the
    /// runners stay implementation details (a public default argument can't
    /// reference them anyway).
    static func listPhysicalDevices(
        devicectlProvider: () -> Data?,
        ideviceIDProvider: () -> [String]
    ) -> [Device] {
        listPhysicalDevices(
            devicectlProvider: devicectlProvider,
            ideviceIDProvider: ideviceIDProvider,
            devicectlDetailsProvider: { _ in nil }
        )
    }

    /// `devicectl list devices` can retain a stale `disconnected` cache row
    /// for a paired Wi-Fi Apple TV even while `device info details` can open
    /// a live CoreDevice tunnel. Probe only those tvOS rows: unavailable TVs
    /// and iOS devices remain untouched, so normal listing stays cheap.
    static func listPhysicalDevices(
        devicectlProvider: () -> Data?,
        ideviceIDProvider: () -> [String],
        devicectlDetailsProvider: (String) -> String?
    ) -> [Device] {
        var devices: [Device] = []
        if let data = devicectlProvider() {
            devices = (try? parseDevicectlJSON(data)) ?? []
        }
        devices = promoteLiveDisconnectedAppleTVs(
            in: devices,
            devicectlDetailsProvider: devicectlDetailsProvider
        )
        return mergeIdeviceIDUDIDs(into: devices, udids: ideviceIDProvider())
    }

    static func promoteLiveDisconnectedAppleTVs(
        in devices: [Device],
        devicectlDetailsProvider: (String) -> String?
    ) -> [Device] {
        devices.map { device in
            guard device.platform == .tvos,
                  device.target == .device,
                  device.state.lowercased() == "disconnected",
                  devicectlDetailsProvider(device.udid)?.lowercased() == Device.State.deviceConnected
            else { return device }
            return Device(
                udid: device.udid,
                name: device.name,
                platform: device.platform,
                state: Device.State.deviceConnected,
                runtime: device.runtime,
                target: device.target
            )
        }
    }

    // MARK: - subprocess runners

    /// `xcrun devicectl list devices --json-output <tmp>`, returning the
    /// file's contents. `nil` on any spawn / non-zero / read failure.
    static func runDevicectl() -> Data? {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sim-use-devicectl-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["devicectl", "list", "devices", "--json-output", tmp.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        return try? Data(contentsOf: tmp)
    }

    /// Actively resolve a paired Apple TV. Unlike the cached list verb,
    /// `device info details` opens the CoreDevice tunnel and reports its live
    /// state. Returns nil on any tool or parse failure.
    static func runDevicectlDetails(udid: String) -> String? {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sim-use-devicectl-details-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "devicectl", "device", "info", "details",
            "--device", udid,
            "--timeout", "10",
            "--json-output", tmp.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0,
              let data = try? Data(contentsOf: tmp)
        else { return nil }

        struct Envelope: Decodable { let result: ResultBlock }
        struct ResultBlock: Decodable { let connectionProperties: ConnectionProps? }
        struct ConnectionProps: Decodable { let tunnelState: String? }
        return try? JSONDecoder().decode(Envelope.self, from: data)
            .result.connectionProperties?.tunnelState
    }

    /// `idevice_id -l` via `env` so PATH lookup handles the Homebrew install
    /// location. Exit 127 (command not found) and any spawn failure map to
    /// `[]`, which is the "libimobiledevice not installed, skip" path.
    static func runIdeviceID() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["idevice_id", "-l"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }
        guard process.terminationStatus == 0 else { return [] }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        return text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
