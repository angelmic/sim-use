// SPDX-License-Identifier: Apache-2.0
@testable import TVOSBackend
import ArgumentParser
import Foundation
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

    @Test("The tvOS type command parses its text and target")
    func parsesTypeCommand() throws {
        let parsed = try TVOSCommand.parseAsRoot([
            "type", "hi there",
            "--device", tvosUDID,
            "--bundle-id", "com.example.TVApp",
        ])
        let command = try #require(parsed as? TVOSTypeCommand)

        #expect(command.text == "hi there")
        #expect(command.target.bundleId == "com.example.TVApp")
    }

    @Test("Physical tvOS type routes through the device controller")
    func physicalTypeUsesDeviceController() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Sources/TVOSBackend/Verbs/TVOSTypeCommand.swift"),
            encoding: .utf8
        )

        #expect(source.contains("TVOSDeviceController.live().typeText"))
    }

    @Test("remote applies a default focus settle delay and accepts an override")
    func settleDelayDefaultsAndParses() throws {
        let defaulted = try TVOSCommand.parseAsRoot([
            "remote", "down", "--device", tvosUDID,
        ]) as? TVOSRemoteCommand
        #expect(defaulted?.settleDelay == 0.35)

        let overridden = try TVOSCommand.parseAsRoot([
            "remote", "down", "--device", tvosUDID, "--settle-delay", "0",
        ]) as? TVOSRemoteCommand
        #expect(overridden?.settleDelay == 0)
    }

    @Test("remote parses --report-focus and defaults it off")
    func reportFocusFlagParses() throws {
        let fast = try TVOSCommand.parseAsRoot([
            "remote", "down", "--device", tvosUDID,
        ]) as? TVOSRemoteCommand
        #expect(fast?.reportFocus == false)

        let observing = try TVOSCommand.parseAsRoot([
            "remote", "down", "--device", tvosUDID, "--report-focus",
        ]) as? TVOSRemoteCommand
        #expect(observing?.reportFocus == true)
    }

    @Test("remote rejects a negative settle delay")
    func negativeSettleDelayRejected() {
        #expect(throws: (any Error).self) {
            _ = try TVOSCommand.parseAsRoot([
                "remote", "down", "--device", tvosUDID, "--settle-delay", "-1",
            ])
        }
    }

    private let tvosUDID = "8737CB71-6462-41EC-B13E-E7C5E8F033E9"
}
