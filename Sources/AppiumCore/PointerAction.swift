// SPDX-License-Identifier: Apache-2.0
import Foundation

/// One step in a W3C WebDriver pointer-input sequence — the generic
/// primitive iOS coordinate verbs (tap, swipe) compose. Kept platform-free
/// here in AppiumCore; the backend decides which steps make a tap vs a
/// swipe. Coordinates are points in the driver's coordinate space and are
/// emitted as integers on the wire (the W3C actions spec requires integer
/// x/y), so callers pass whatever they have and the client rounds.
public enum PointerAction: Sendable, Equatable {
    case moveTo(x: Double, y: Double, durationMs: Int)
    case down
    case up
    case pause(durationMs: Int)
}

extension PointerAction {
    /// Convenience: a single tap at a point, optionally held for `holdMs`
    /// between down and up (some gesture recognisers ignore a zero-duration
    /// HID-style tap — the same reason the iOS `tap --duration` flag exists).
    public static func tap(x: Double, y: Double, holdMs: Int = 0) -> [PointerAction] {
        var steps: [PointerAction] = [.moveTo(x: x, y: y, durationMs: 0), .down]
        if holdMs > 0 { steps.append(.pause(durationMs: holdMs)) }
        steps.append(.up)
        return steps
    }

    /// Convenience: a swipe from one point to another over `durationMs`.
    public static func swipe(
        fromX: Double, fromY: Double,
        toX: Double, toY: Double,
        durationMs: Int
    ) -> [PointerAction] {
        [
            .moveTo(x: fromX, y: fromY, durationMs: 0),
            .down,
            .moveTo(x: toX, y: toY, durationMs: durationMs),
            .up,
        ]
    }
}
