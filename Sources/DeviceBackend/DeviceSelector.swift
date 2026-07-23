// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore

/// A CLI-agnostic accessibility selector, resolved against the entries a
/// `describe-ui` snapshot parsed from WebDriverAgent. The top-level `tap`
/// forwarder maps its `TapTargetingOptions` into this so the controller
/// stays free of ArgumentParser types and is unit-testable with plain
/// entries. Exactly one text predicate is expected (the CLI enforces
/// mutual exclusivity); `elementType` and `frame` are AND-narrowers.
public struct DeviceSelector: Sendable, Equatable {
    public var id: String?
    public var label: String?
    public var labelContains: String?
    public var labelRegex: String?
    public var value: String?
    public var elementType: String?
    public var frame: SelectorFrameFilter?

    public init(
        id: String? = nil,
        label: String? = nil,
        labelContains: String? = nil,
        labelRegex: String? = nil,
        value: String? = nil,
        elementType: String? = nil,
        frame: SelectorFrameFilter? = nil
    ) {
        self.id = id
        self.label = label
        self.labelContains = labelContains
        self.labelRegex = labelRegex
        self.value = value
        self.elementType = elementType
        self.frame = frame
    }
}

public enum DeviceSelectorError: Error, LocalizedError, HintProviding, Equatable {
    case noMatch(selector: String, candidates: [String])
    case multipleMatches(selector: String, candidates: [String])

    public var errorDescription: String? {
        switch self {
        case .noMatch(let selector, _):
            return "No element matched \(selector)."
        case .multipleMatches(let selector, let candidates):
            return "\(candidates.count) elements matched \(selector); refine with --element-type or --frame."
        }
    }

    public var hint: String? {
        switch self {
        case .noMatch(_, let candidates), .multipleMatches(_, let candidates):
            guard !candidates.isEmpty else { return nil }
            return "candidates: " + candidates.prefix(12).joined(separator: "; ")
        }
    }
}

/// Resolves a `DeviceSelector` to exactly one `Outline.Entry`. The same
/// exact-first / whitespace-collapsed matching policy the iOS Simulator and
/// Android resolvers use (`SelectorTextMatcher`) so a label copied from the
/// outline round-trips back into `--label`.
public enum DeviceSelectorResolver {
    public static func resolve(
        _ selector: DeviceSelector,
        in entries: [Outline.Entry],
        screen: Outline.Frame
    ) throws -> Outline.Entry {
        var matches = entries

        if let id = selector.id {
            matches = matches.filter { $0.uniqueId == id }
        }
        if let label = selector.label {
            matches = SelectorTextMatcher.filterEquals(matches, query: label) { $0.label }
        }
        if let value = selector.value {
            matches = SelectorTextMatcher.filterEquals(matches, query: value) { $0.value }
        }
        if let needle = selector.labelContains {
            matches = SelectorTextMatcher.filterContains(matches, needle: needle) { $0.label }
        }
        if let pattern = selector.labelRegex {
            let regex = try NSRegularExpression(pattern: pattern)
            matches = matches.filter { entry in
                let range = NSRange(entry.label.startIndex..., in: entry.label)
                return regex.firstMatch(in: entry.label, range: range) != nil
            }
        }
        if let type = selector.elementType {
            matches = matches.filter { $0.role.caseInsensitiveCompare(type) == .orderedSame }
        }
        if let frame = selector.frame, !frame.isEmpty {
            let resolved = frame.resolved(screen: screen)
            matches = matches.filter { resolved.contains($0.frame) }
        }

        switch matches.count {
        case 1:
            return matches[0]
        case 0:
            throw DeviceSelectorError.noMatch(selector: describe(selector), candidates: candidateLabels(entries))
        default:
            throw DeviceSelectorError.multipleMatches(selector: describe(selector), candidates: candidateLabels(matches))
        }
    }

    /// The tap point for an entry is its frame center — the same rule the
    /// alias cache pre-computes for `@N` / `#N`.
    public static func center(of entry: Outline.Entry) -> (x: Double, y: Double) {
        (
            x: Double(entry.frame.x) + Double(entry.frame.width) / 2,
            y: Double(entry.frame.y) + Double(entry.frame.height) / 2
        )
    }

    private static func describe(_ selector: DeviceSelector) -> String {
        if let id = selector.id { return "--id \"\(id)\"" }
        if let label = selector.label { return "--label \"\(label)\"" }
        if let value = selector.value { return "--value \"\(value)\"" }
        if let contains = selector.labelContains { return "--label-contains \"\(contains)\"" }
        if let regex = selector.labelRegex { return "--label-regex \"\(regex)\"" }
        return "the selector"
    }

    private static func candidateLabels(_ entries: [Outline.Entry]) -> [String] {
        entries
            .map { entry in
                let id = entry.uniqueId.map { " #\($0)" } ?? ""
                return "\(entry.role) \"\(entry.label)\"\(id)"
            }
    }
}
