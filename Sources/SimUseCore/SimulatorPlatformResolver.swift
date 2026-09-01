// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Resolves an Apple Simulator UUID to its runtime family. iOS and tvOS
/// simulator identifiers have the same UUID shape, so string heuristics alone
/// cannot select the correct backend; CoreSimulator's own metadata is the
/// authoritative discriminator.
///
/// Two sources, cheapest first:
///
/// 1. The device's own `device.plist` in the default CoreSimulator device
///    set — a single ~1 ms file read, fresh on every call.
/// 2. `simctl list devices -j` — a full process fork (hundreds of ms), kept
///    as a safety net for plists this code cannot read (layout drift,
///    permissions). Forked at most once per process.
///
/// Neither source sees devices in a custom device set (`simctl --set` —
/// flag-less `simctl list` only serves the default set too), and families
/// this resolver does not support (watchOS, visionOS) resolve to `nil`
/// either way; `PlatformRouter` then applies its historical iOS fallback,
/// so such UUIDs route exactly as they did before tvOS support existed.
public enum SimulatorPlatformResolver {
    private struct DevicePlist: Decodable {
        let runtime: String
        let isDeleted: Bool?
    }

    public enum ResolverError: Error, LocalizedError {
        case simctlFailed(String)
        case malformedJSON(String)

        public var errorDescription: String? {
            switch self {
            case .simctlFailed(let message):
                return "simctl failed while resolving the simulator platform: \(message)"
            case .malformedJSON(let message):
                return "Could not parse the simctl device catalog: \(message)"
            }
        }
    }

    /// Parse the `simctl list devices -j` envelope into the platform mapping
    /// needed by command routing. Unsupported Apple runtime families are
    /// intentionally omitted rather than guessed; the type comment explains
    /// what omission means to the router.
    public static func parse(_ data: Data) throws -> [String: Platform] {
        struct RawDevice: Decodable {
            let udid: String
        }
        struct Envelope: Decodable {
            let devices: [String: [RawDevice]]
        }

        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw ResolverError.malformedJSON(error.localizedDescription)
        }

        var result: [String: Platform] = [:]
        for (runtimeIdentifier, devices) in envelope.devices {
            guard let platform = platform(forRuntimeIdentifier: runtimeIdentifier) else { continue }
            for device in devices {
                result[device.udid] = platform
            }
        }
        return result
    }

    /// Classify a CoreSimulator runtime identifier such as
    /// `com.apple.CoreSimulator.SimRuntime.tvOS-18-2`.
    static func platform(forRuntimeIdentifier identifier: String) -> Platform? {
        if identifier.contains(".tvOS-") { return .tvOSSim }
        if identifier.contains(".iOS-") { return .iOSSim }
        return nil
    }

    /// Live lookup used by `PlatformRouter`. Prefers the per-device plist —
    /// cheap enough for hot verbs like `ui`, and always current, so a
    /// simulator created after a long-lived daemon spawned still resolves —
    /// and falls back to the process-cached `simctl` catalog when the plist
    /// is missing or unreadable.
    public static func livePlatform(for udid: String) -> Platform? {
        if let platform = devicePlistPlatform(for: udid) {
            return platform
        }
        return liveCatalog[udid]
    }

    /// Read the runtime family straight from CoreSimulator's per-device
    /// `device.plist`. Returns nil when the device directory is missing
    /// (unknown UUID, or a custom device set), the plist is unreadable, the
    /// device is marked deleted, or the runtime family is unsupported.
    static func devicePlistPlatform(
        for udid: String,
        deviceSetURL: URL = defaultDeviceSetURL
    ) -> Platform? {
        let plistURL = deviceSetURL
            .appendingPathComponent(udid.uppercased())
            .appendingPathComponent("device.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let entries = try? PropertyListDecoder().decode(DevicePlist.self, from: data)
        else { return nil }
        if entries.isDeleted == true { return nil }
        return platform(forRuntimeIdentifier: entries.runtime)
    }

    /// CoreSimulator's default device set. Devices in a custom set
    /// (`simctl --set`) are visible neither here nor to the flag-less
    /// `simctl list` fallback; they resolve to nil and keep the router's
    /// historical iOS fallback.
    static let defaultDeviceSetURL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Developer/CoreSimulator/Devices")

    private static let liveCatalog: [String: Platform] = {
        do {
            return try parse(runSimctl())
        } catch {
            // Swallowing this silently would route a tvOS Simulator to the
            // iOS backend (the router's fallback) with nothing to explain
            // why. The command still proceeds, so a warning is the right
            // volume.
            FileHandle.standardError.write(Data(
                "warning: could not resolve Apple Simulator runtime families (\(error.localizedDescription)); treating unrecognised simulator UUIDs as iOS.\n".utf8
            ))
            return [:]
        }
    }()

    private static func runSimctl() throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "list", "devices", "-j"]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let lock = NSLock()
        var output = Data()
        var errorOutput = Data()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            lock.lock(); output.append(chunk); lock.unlock()
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            lock.lock(); errorOutput.append(chunk); lock.unlock()
        }

        do {
            try process.run()
        } catch {
            throw ResolverError.simctlFailed("could not spawn xcrun: \(error.localizedDescription)")
        }
        process.waitUntilExit()

        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        lock.lock()
        output.append(stdout.fileHandleForReading.readDataToEndOfFile())
        errorOutput.append(stderr.fileHandleForReading.readDataToEndOfFile())
        lock.unlock()

        guard process.terminationStatus == 0 else {
            let message = String(data: errorOutput, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ResolverError.simctlFailed("exit \(process.terminationStatus): \(message)")
        }
        return output
    }
}
