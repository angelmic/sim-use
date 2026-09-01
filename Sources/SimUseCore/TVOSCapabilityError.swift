// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Actionable rejection for coordinate/touch commands on tvOS. Treating a
/// tvOS UUID as iOS would send unsupported HID gestures and can report false
/// success, so routing fails before any side effect and points to the remote
/// control surface instead.
public struct TVOSCapabilityError: Error, LocalizedError, HintProviding, Equatable {
    public let command: String

    public init(command: String) {
        self.command = command
    }

    public var errorDescription: String? {
        "`\(command)` is not supported on tvOS because tvOS navigation is focus-driven."
    }

    public var hint: String? {
        "Use `sim-use tvos remote <up|down|left|right|select|menu|play-pause|home>` and re-run `sim-use ui` to verify focus. For text entry, focus a text field and use `sim-use tvos type <text>`."
    }
}
