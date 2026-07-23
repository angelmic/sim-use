// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore

/// Normalises WebDriverAgent's iOS XML `source` into the shared
/// `DescribeUIResult` / outline contract, following the `TVOSOutlineRenderer`
/// precedent. The iOS-specific addition is the `#id` selector: WDA exposes
/// the accessibility identifier as the element's `name` attribute, so it is
/// carried as `Outline.Entry.uniqueId` and rendered as a `#<id>` token an
/// agent can pass straight back to `tap --id` / `tap '#<id>'`.
public enum DeviceOutlineRenderer {
    public enum RendererError: Error, LocalizedError {
        case invalidXML(String)

        public var errorDescription: String? {
            switch self {
            case .invalidXML(let message):
                return "Could not parse iOS WebDriver source: \(message)"
            }
        }
    }

    public static func render(source: String, includeRaw: Bool) throws -> DescribeUIResult {
        let collector = Collector()
        let parser = XMLParser(data: Data(source.utf8))
        parser.delegate = collector
        guard parser.parse() else {
            throw RendererError.invalidXML(parser.parserError?.localizedDescription ?? "unknown XML error")
        }

        let screen = collector.screen
        let entries = collector.elements.enumerated().map { index, element in
            Outline.Entry(
                aliases: .init(at: index + 1),
                role: element.role,
                label: element.label,
                frame: element.frame,
                region: region(for: element.frame, screen: screen),
                states: element.states,
                uniqueId: element.uniqueId,
                value: element.value,
                depth: element.depth
            )
        }
        let appLabel = collector.appLabel ?? collector.bundleID ?? "iOS App"
        return DescribeUIResult(
            platform: .ios,
            raw: includeRaw ? .string(source) : nil,
            outline: renderText(appLabel: appLabel, screen: screen, entries: entries),
            entries: entries,
            lists: [],
            screen: screen,
            appLabel: appLabel,
            appPackage: collector.bundleID ?? ""
        )
    }

    private static func region(for frame: Outline.Frame, screen: Outline.Frame) -> Outline.Region {
        let centerY = frame.y + frame.height / 2
        if centerY < 120 { return .init(kind: "Top") }
        if screen.height > 0, centerY >= max(120, screen.height - 120) {
            return .init(kind: "Bottom")
        }
        return .init(kind: "Content")
    }

    private static func renderText(
        appLabel: String,
        screen: Outline.Frame,
        entries: [Outline.Entry]
    ) -> String {
        var output = "App: \(appLabel)  \(screen.width)x\(screen.height)\n"
        guard !entries.isEmpty else { return output }

        var order: [String] = []
        var members: [String: [Outline.Entry]] = [:]
        for entry in entries {
            let key = entry.region.kind
            if members[key] == nil { order.append(key) }
            members[key, default: []].append(entry)
        }
        for key in order {
            output += "\n\(regionHeader(key, screenHeight: screen.height))\n"
            for entry in members[key] ?? [] {
                output += elementLine(entry) + "\n"
            }
        }
        return output
    }

    private static func regionHeader(_ kind: String, screenHeight: Int) -> String {
        switch kind {
        case "Top": return "[Top  y<120]"
        case "Content": return "[Content  y=120..\(max(120, screenHeight - 120))]"
        case "Bottom": return "[Bottom  y>=\(max(120, screenHeight - 120))]"
        default: return "[\(kind)]"
        }
    }

    private static func elementLine(_ entry: Outline.Entry) -> String {
        let label = escape(truncate(SelectorTextMatcher.collapseWhitespace(entry.label), limit: 60))
        let frame = "(\(entry.frame.x),\(entry.frame.y) \(entry.frame.width)x\(entry.frame.height))"
        // `#<id>` sits right after `@N` so an agent copies the selector it
        // will pass back to `tap` without hunting. Only rendered when the
        // element carries an accessibility identifier distinct enough to be
        // useful (non-empty `name`).
        let idToken = entry.uniqueId.map { " #\($0)" } ?? ""
        let valueToken = entry.value.map { "  =\"\(escape(truncate(SelectorTextMatcher.collapseWhitespace($0), limit: 30)))\"" } ?? ""
        let states = entry.states.map { "  \($0)" }.joined()
        return "  @\(entry.aliases.at)\(idToken)  \(entry.role)  \"\(label)\"\(valueToken)  \(frame)\(states)"
    }

    private static func truncate(_ text: String, limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

private extension DeviceOutlineRenderer {
    struct Element {
        let role: String
        let label: String
        let value: String?
        let uniqueId: String?
        let frame: Outline.Frame
        let states: [String]
        let depth: Int
    }

    final class Collector: NSObject, XMLParserDelegate {
        var appLabel: String?
        var bundleID: String?
        var screen = Outline.Frame(x: 0, y: 0, width: 0, height: 0)
        var elements: [Element] = []
        private var depth = 0

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            defer { depth += 1 }
            let rawType = attributeDict["type"] ?? elementName
            let role = rawType.replacingOccurrences(of: "XCUIElementType", with: "")
            let frame = Outline.Frame(
                x: Int(Double(attributeDict["x"] ?? "") ?? 0),
                y: Int(Double(attributeDict["y"] ?? "") ?? 0),
                width: Int(Double(attributeDict["width"] ?? "") ?? 0),
                height: Int(Double(attributeDict["height"] ?? "") ?? 0)
            )

            if role == "Application" {
                appLabel = nonEmpty(attributeDict["label"]) ?? nonEmpty(attributeDict["name"])
                bundleID = nonEmpty(attributeDict["bundleId"])
                screen = frame
                return
            }

            guard attributeDict["visible"] != "false",
                  frame.width > 0,
                  frame.height > 0
            else { return }

            let name = nonEmpty(attributeDict["name"])
            let label = nonEmpty(attributeDict["label"])
            let value = nonEmpty(attributeDict["value"])
            // The visible text: label first, then name (WDA falls the
            // identifier through to name), then value. Chrome with none of
            // the three is dropped to keep the outline small.
            guard let text = label ?? name ?? value else { return }
            // `#id` is the accessibility identifier. WDA reports it as
            // `name`; when `name` only mirrors the label it is not a useful
            // selector, so keep it only when it adds information.
            let uniqueId = (name != nil && name != label) ? name : nil

            var states: [String] = []
            if attributeDict["enabled"] == "false" { states.append("disabled") }
            if attributeDict["selected"] == "true" { states.append("selected") }
            if attributeDict["focused"] == "true" { states.append("focused") }

            elements.append(Element(
                role: role,
                label: text,
                value: value,
                uniqueId: uniqueId,
                frame: frame,
                states: states,
                depth: max(0, depth - 1)
            ))
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            depth = max(0, depth - 1)
        }

        private func nonEmpty(_ value: String?) -> String? {
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return value
        }
    }
}
