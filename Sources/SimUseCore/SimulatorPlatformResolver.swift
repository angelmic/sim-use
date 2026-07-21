// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Resolves an Apple Simulator UUID to its runtime family. iOS and tvOS
/// simulator identifiers have the same UUID shape, so string heuristics alone
/// cannot select the correct backend; the runtime key in `simctl list` is the
/// authoritative discriminator.
public enum SimulatorPlatformResolver {
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
    /// intentionally omitted instead of being mislabeled as iOS.
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
            let platform: Platform?
            if runtimeIdentifier.contains(".tvOS-") {
                platform = .tvOSSim
            } else if runtimeIdentifier.contains(".iOS-") {
                platform = .iOSSim
            } else {
                platform = nil
            }
            guard let platform else { continue }
            for device in devices {
                result[device.udid] = platform
            }
        }
        return result
    }

    /// Live lookup used by `PlatformRouter`. The catalog is immutable for the
    /// lifetime of a short-lived CLI/daemon process, which also avoids a
    /// `simctl` fork on every routed verb.
    public static func livePlatform(for udid: String) -> Platform? {
        liveCatalog[udid]
    }

    private static let liveCatalog: [String: Platform] = {
        (try? parse(runSimctl())) ?? [:]
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
