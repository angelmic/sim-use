// SPDX-License-Identifier: Apache-2.0
import ArgumentParser

/// Public entry point for focus-driven tvOS Simulator commands.
///
/// `describe-ui` and `screenshot` are also available at the top level;
/// `remote` stays in this namespace because its buttons are specific to
/// tvOS and have no coordinate-based iOS or Android equivalent.
public struct TVOSCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "tvos",
        abstract: "tvOS Simulator-specific focus and remote-control subcommands.",
        subcommands: [
            TVOSDescribeUICommand.self,
            TVOSRemoteCommand.self,
            TVOSScreenshotCommand.self,
            TVOSTypeCommand.self,
        ]
    )

    public init() {}
}
