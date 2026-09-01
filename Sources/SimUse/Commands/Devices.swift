// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore
import AndroidBackend
import iOSSimBackend

/// Cross-platform device listing. Successor to the legacy
/// `list-simulators` (iOS-only) and `android devices` verbs, which
/// remain available for now but redirect users here.
struct Devices: SimUseExecutableCommand {
    static let configuration = CommandConfiguration(
        commandName: "devices",
        abstract: "List connected devices across iOS/tvOS Simulators, Android devices and physical Apple devices.",
        discussion: """
        Aggregates `xcrun simctl list devices` (iOS/tvOS Simulators),
        `adb devices` (Android devices / emulators) and devicectl /
        idevice_id discovery (physical iPhones / iPads / Apple TVs) into
        a single unified table. `kind` distinguishes the carrier —
        simulator, emulator or physical — orthogonally to the platform.

        Default lists only devices sim-use can talk to right now
        (iOS `Booted`, Android `device`, physical `connected`). Pass
        `--all` to include shutdown sims and offline / unauthorised
        adb entries — useful when picking which simulator to boot.

        Examples:
          sim-use devices                          # currently usable devices, all targets
          sim-use devices --all                    # also include shutdown / offline
          sim-use devices --platform ios           # iOS only (simulators + physical)
          sim-use devices --platform tvos          # tvOS only (simulators + physical)
          sim-use devices --no-physical-ios        # skip physical-device discovery entirely
          sim-use devices --json                   # structured output (Viewer, scripts, agents)

        JSON envelope (--json):
          {
            "ok": true,
            "data": {
              "devices": [
                {"deviceId": "...",
                 "name": "...", "platform": "ios|tvos|android",
                 "kind": "simulator|emulator|physical",
                 "target": "sim|device",
                 "state": "Booted|Shutdown|device|offline|...", "runtime": "iOS 18.6|Android|..."},
                ...
              ]
            }
          }
        """
    )

    @Flag(name: .customLong("all"), help: "Include devices that aren't currently usable (iOS Shutdown sims, Android offline / unauthorised devices). Default is booted-only.")
    var includeAll: Bool = false

    @Flag(name: .customLong("no-physical-ios"), help: "Skip physical Apple-device discovery (devicectl / idevice_id). Saves the discovery cost on hosts with no device attached; simulators and Android are unaffected. Used by consumers that need capabilities physical devices don't carry, e.g. the Viewer (video streaming).")
    var noPhysicalIOS: Bool = false

    @Option(name: .customLong("platform"), help: "Restrict the list to one platform.")
    var platform: Device.Platform?

    @Flag(name: .customLong("json"), help: "Emit a JSON envelope `{ok, data: {devices: [...]}}` instead of the aligned text table.")
    var jsonOutput: Bool = false

    struct ExecutionResult: Codable {
        let devices: [Device]
    }

    func execute() async throws -> ExecutionResult {
        // The simctl and adb queries are cheap (~50–200ms each); physical
        // Apple discovery (devicectl / idevice_id, merged inside the Apple
        // side) is resilient and never throws. Fire both sides in parallel
        // so the combined latency is the slowest side rather than their
        // sum. Errors fall through per side so a missing adb (Android not
        // configured) doesn't kill iOS listing and vice versa.
        async let iosFuture = listIOS()
        async let androidFuture = listAndroid()
        let iosResult = await iosFuture
        let androidResult = await androidFuture

        var combined = Self.filterDevices(
            appleDevices: iosResult.devices,
            androidDevices: androidResult.devices,
            platform: platform,
            includeAll: includeAll
        )

        // Within a platform, virtual carriers (simulator / emulator)
        // sort before physical hardware — they never coexist on one
        // platform, so a plain "physical last" rank expresses it.
        func kindRank(_ device: Device) -> Int { device.kind == .physical ? 1 : 0 }
        combined.sort { lhs, rhs in
            if lhs.platform != rhs.platform     { return lhs.platform.rawValue < rhs.platform.rawValue }
            if kindRank(lhs) != kindRank(rhs)   { return kindRank(lhs) < kindRank(rhs) }
            if lhs.runtime != rhs.runtime       { return (lhs.runtime ?? "") < (rhs.runtime ?? "") }
            if lhs.name != rhs.name             { return lhs.name < rhs.name }
            return lhs.udid < rhs.udid
        }

        // Every side failed and the resolved scope covered both
        // platforms — the per-side warnings above aren't enough;
        // surface a single-line summary so a user running plain
        // `sim-use devices` on a host with no tooling sees something
        // more actionable than "No devices found".
        if combined.isEmpty, iosResult.failed, androidResult.failed, platform == nil {
            FileHandle.standardError.write(Data(
                "warning: both Apple Simulator (simctl) and Android (adb) listings failed; pass --platform ios|tvos|android to scope, or install the missing tooling.\n".utf8
            ))
        }
        return ExecutionResult(devices: combined)
    }

    /// Apply platform selection after `simctl` returns its mixed Apple
    /// runtime list. In particular, `--platform ios` must not leak tvOS
    /// rows, and `--platform tvos` must not trigger or include adb.
    static func filterDevices(
        appleDevices: [Device],
        androidDevices: [Device],
        platform: Device.Platform?,
        includeAll: Bool
    ) -> [Device] {
        var devices: [Device]
        switch platform {
        case .ios:
            devices = appleDevices.filter { $0.platform == .ios }
        case .tvos:
            devices = appleDevices.filter { $0.platform == .tvos }
        case .android:
            devices = androidDevices
        case .none:
            devices = appleDevices + androidDevices
        }
        return includeAll ? devices : devices.filter(\.isUsable)
    }

    /// Each side of the parallel listing reports `(devices, failed)`
    /// rather than a bare `[Device]`. The `failed` bit lets `execute`
    /// decide whether to surface the "both lookups blew up"
    /// summary; without it the caller can't tell "Android is
    /// genuinely empty" from "adb threw before listing started".
    private struct SideResult {
        let devices: [Device]
        let failed: Bool
    }

    private func listIOS() async -> SideResult {
        // If --platform=android, skip the Apple side entirely.
        if platform == .android { return SideResult(devices: [], failed: false) }
        // Physical Apple devices (cabled iPhone/iPad, paired Apple TV) come
        // from devicectl + idevice_id; Simulators from simctl. Merge both so
        // `devices` shows the full Apple surface (each row carries its
        // sim|device `target`). Physical enumeration is resilient — it never
        // throws — so it can't take down the Simulator listing.
        let physical = noPhysicalIOS ? [] : AppleDeviceLister.listPhysicalDevices()
        do {
            // We always fetch the full list (not `simctl ... booted`)
            // because the `--all` flag changes intent at runtime and
            // the cost of the wider query is small compared to the
            // process spawn itself.
            let sims = try SimctlDeviceLister.listDevices(bootedOnly: false)
            return SideResult(devices: sims + physical, failed: false)
        } catch {
            FileHandle.standardError.write(Data("warning: iOS Simulator listing failed: \(error.localizedDescription)\n".utf8))
            // simctl failed, but any physical devices we found are still
            // worth surfacing; only report failure if we have nothing.
            return SideResult(devices: physical, failed: physical.isEmpty)
        }
    }

    private func listAndroid() async -> SideResult {
        if platform != nil, platform != .android {
            return SideResult(devices: [], failed: false)
        }
        do {
            // adb may simply be unavailable on hosts that don't do
            // Android work; that's not an error worth derailing the
            // iOS listing for.
            let devices = try AndroidDeviceController().listUnifiedDevices()
            return SideResult(devices: devices, failed: false)
        } catch {
            FileHandle.standardError.write(Data("warning: Android device listing failed: \(error.localizedDescription)\n".utf8))
            return SideResult(devices: [], failed: true)
        }
    }

    func format(_ result: ExecutionResult) -> CommandOutput {
        guard !result.devices.isEmpty else {
            return .line("No devices found. Pass --all to include shutdown / offline entries.")
        }
        return .line(renderTable(result.devices))
    }

    /// Column-aligned text table. Computed widths so an emulator serial
    /// (~14 chars) doesn't waste space alongside an iOS UDID (36).
    private func renderTable(_ devices: [Device]) -> String {
        let headers = ["PLATFORM", "KIND", "STATE", "NAME", "UDID", "RUNTIME"]
        let rows: [[String]] = devices.map { d in
            [d.platform.rawValue, d.kind.rawValue, d.state, d.name, d.udid, d.runtime ?? "-"]
        }
        let widths: [Int] = (0..<headers.count).map { col in
            ([headers[col]] + rows.map { $0[col] }).map(\.count).max() ?? 0
        }
        func line(_ cells: [String]) -> String {
            cells.enumerated()
                .map { i, cell in cell.padding(toLength: widths[i], withPad: " ", startingAt: 0) }
                .joined(separator: "  ")
                .trimmingCharacters(in: .whitespaces)
        }
        var out = [line(headers)]
        out.append(contentsOf: rows.map(line))
        return out.joined(separator: "\n")
    }
}

extension Device.Platform: ExpressibleByArgument {
    public init?(argument: String) {
        self.init(rawValue: argument.lowercased())
    }
}
