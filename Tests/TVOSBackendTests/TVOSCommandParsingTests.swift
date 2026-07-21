// SPDX-License-Identifier: Apache-2.0
@testable import TVOSBackend
import ArgumentParser
import Testing

@Suite("tvOS command parsing")
struct TVOSCommandParsingTests {
    @Test("The tvOS namespace parses a focus remote button")
    func parsesRemoteButton() throws {
        let parsed = try TVOSCommand.parseAsRoot([
            "remote", "play-pause",
            "--device", tvosUDID,
            "--bundle-id", "com.example.TVApp",
        ])
        let command = try #require(parsed as? TVOSRemoteCommand)

        #expect(command.button == .playPause)
        #expect(command.device.device == tvosUDID)
        #expect(command.target.bundleId == "com.example.TVApp")
    }

    @Test("The tvOS UI alias routes to the describe-ui command")
    func parsesUIAlias() throws {
        let parsed = try TVOSCommand.parseAsRoot([
            "ui",
            "--device", tvosUDID,
            "--bundle-id", "com.example.TVApp",
            "--json",
        ])
        let command = try #require(parsed as? TVOSDescribeUICommand)

        #expect(command.device.device == tvosUDID)
        #expect(command.target.bundleId == "com.example.TVApp")
        #expect(command.jsonOutput)
    }

    @Test("Default tvOS screenshot filename identifies the target")
    func defaultScreenshotFilename() throws {
        let url = try TVOSScreenshotCommand.prepareOutputURL(
            output: nil,
            deviceID: tvosUDID
        )

        #expect(url.lastPathComponent.hasPrefix("tvOS Screenshot - \(tvosUDID) - "))
        #expect(url.pathExtension == "png")
    }

    @Test("The tvOS screenshot command accepts a cold-start target")
    func parsesScreenshotTarget() throws {
        let parsed = try TVOSCommand.parseAsRoot([
            "screenshot",
            "--device", tvosUDID,
            "--bundle-id", "com.example.TVApp",
            "--output", "/tmp/tvos.png",
        ])
        let command = try #require(parsed as? TVOSScreenshotCommand)

        #expect(command.target.bundleId == "com.example.TVApp")
        #expect(command.output == "/tmp/tvos.png")
    }

    private let tvosUDID = "8737CB71-6462-41EC-B13E-E7C5E8F033E9"
}
