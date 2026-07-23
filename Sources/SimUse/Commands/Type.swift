// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore
import AndroidBackend
import iOSSimBackend
import DeviceBackend

/// Top-level cross-platform `type` verb. Owns the flag surface and
/// resolves the target platform, then delegates to the per-backend
/// command (`IOSSimTypeCommand` for iOS Simulator UDIDs,
/// `AndroidTypeCommand.performType` for adb serials).
///
/// Android dispatch defaults to `clear: false` (append at caret) so
/// it matches iOS HID's natural append behaviour. Callers wanting
/// replace-mode on Android should use `sim-use android type --clear`
/// directly.
struct Type: SimUseExecutableCommand {
    typealias ExecutionResult = IOSSimTypeCommand.ExecutionResult

    static let configuration = CommandConfiguration(
        abstract: "Type text by entering a sequence of characters.",
        discussion: """
        Input Methods:
        1. Direct text: sim-use type "Hello World" --udid UDID
        2. From stdin: echo "Hello World!" | sim-use type --stdin --udid UDID
        3. From file: sim-use type --file text.txt --udid UDID

        Examples:
        • Simple text: sim-use type "Hello World" --udid UDID
        • With spaces: sim-use type "Hello, how are you?" --udid UDID
        • Special characters: sim-use type 'Hello!' --udid UDID

        Shell Escaping Tips:
        • Use double quotes for text with spaces: "Hello World"
        • Use single quotes for text with special characters: 'Hello!'
        • For complex text or automation, prefer --stdin or --file methods

        Character Support:
        • Only US keyboard characters are supported via HID keycodes
        • Supported: A-Z, a-z, 0-9, and symbols: !@#$%^&*()_+-={}[]|\\:";'<>?,./`~
        • Not supported: International characters (£€¥), accented letters (éñü), etc.
        • This is a limitation of the underlying HID keyboard protocol

        Note: iOS may apply smart punctuation spacing to some characters.
        """
    )

    @Argument(help: "The text to type. Use quotes for text with spaces or special characters.")
    var text: String?

    @Flag(name: .customLong("stdin"), help: "Read text from standard input.")
    var useStdin: Bool = false

    @Option(name: .customLong("file"), help: "Read text from the specified file.")
    var inputFile: String?

    @OptionGroup var device: DeviceOptions

    @Option(
        name: .customLong("bundle-id"),
        help: "Physical Apple device only: attach the WebDriverAgent session to this app and bring it to the foreground, so the text goes into that app's field instead of the home screen. Ignored on the iOS Simulator and Android."
    )
    var bundleId: String?

    @OptionGroup var json: JSONOutputOptions

    var jsonOutput: Bool { json.enabled }

    mutating func resolveDeferredArguments() throws {
        try device.resolve()
    }

    var simulatorUDIDForDaemon: String? { device.resolved }

    // The daemon runs with stdin=/dev/null. Bypass daemon when reading
    // from stdin so --stdin actually sees the caller's terminal input.
    // tvOS additionally bypasses so the TVOSCapabilityError rejection
    // happens in-process, not in a freshly spawned daemon.
    var daemonBypass: Bool {
        useStdin || PlatformRouter.bypassesSimulatorDaemon(udid: device.resolved)
    }

    func format(_ result: ExecutionResult) -> CommandOutput { .empty }

    func validate() throws {
        try IOSSimTypeCommand.validateOptions(text: text, useStdin: useStdin, inputFile: inputFile)
    }

    func execute() async throws -> ExecutionResult {
        switch PlatformRouter.resolve(udid: device.resolved) {
        case .android:
            return try executeAndroid()
        case .tvOSSim:
            throw TVOSCapabilityError(command: "type")
        case .appleDevice:
            return try await executeAppleDevice()
        case .iOSSim, .none:
            return try await executeIOSSim()
        }
    }

    /// Physical iOS device: send the text to the focused element over
    /// WebDriverAgent. tvOS is rejected by the controller with
    /// `TVOSCapabilityError` (use `sim-use tvos type`).
    private func executeAppleDevice() async throws -> ExecutionResult {
        try await AppleDeviceController.live().type(udid: device.resolved, text: try resolvedInputText(), bundleId: bundleId)
        return ExecutionResult()
    }

    /// The text to enter, from the positional arg, `--stdin`, or `--file`.
    /// Shared by the Android and physical-device paths so the three input
    /// forms resolve identically.
    private func resolvedInputText() throws -> String {
        switch (text, useStdin, inputFile) {
        case (let positional?, false, nil):
            return positional
        case (nil, true, nil):
            return IOSSimTypeCommand.readFromStdin()
        case (nil, false, let file?):
            return try IOSSimTypeCommand.readFromFile(file)
        case (nil, false, nil):
            throw ValidationError("No input provided. Provide text as argument, or use --stdin, or --file.")
        default:
            throw ValidationError("Invalid input configuration.")
        }
    }

    private func executeIOSSim() async throws -> ExecutionResult {
        let sub = makeIOSSubcommand()
        return try await sub.execute()
    }

    /// Construct the backend command and copy every parsed flag across.
    /// A missed field stays in ArgumentParser's wrapper-definition state
    /// and traps on first read (#42) — pinned by
    /// `ForwarderInitializationGuardTests`.
    func makeIOSSubcommand() -> IOSSimTypeCommand {
        var sub = IOSSimTypeCommand()
        sub.text = text
        sub.useStdin = useStdin
        sub.inputFile = inputFile
        sub.device = device
        sub.json = json
        return sub
    }

    private func executeAndroid() throws -> ExecutionResult {
        try AndroidTypeCommand.performType(udid: device.resolved, text: try resolvedInputText(), clear: false)
        return ExecutionResult()
    }
}
