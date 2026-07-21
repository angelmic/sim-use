// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore

/// Converts Appium's tvOS XML source into the same compact outline contract
/// used by the iOS and Android backends. The tvOS focus state is preserved as
/// a first-class state tag because it is the platform's primary cursor.
public enum TVOSOutlineRenderer {
    public enum RendererError: Error, LocalizedError {
        case invalidXML(String)

        public var errorDescription: String? {
            switch self {
            case .invalidXML(let message):
                return "Could not parse tvOS WebDriver source: \(message)"
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
                depth: element.depth
            )
        }
        let appLabel = collector.appLabel ?? collector.bundleID ?? "tvOS App"
        return DescribeUIResult(
            platform: .tvos,
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

        var order: [RegionKey] = []
        var members: [RegionKey: [Outline.Entry]] = [:]
        for entry in entries {
            let key = RegionKey(kind: entry.region.kind, label: entry.region.label)
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

    private static func regionHeader(_ key: RegionKey, screenHeight: Int) -> String {
        switch key.kind {
        case "Top":
            return "[Top  y<120]"
        case "Content":
            return "[Content  y=120..\(max(120, screenHeight - 120))]"
        case "Bottom":
            return "[Bottom  y>=\(max(120, screenHeight - 120))]"
        default:
            return "[\(key.kind)]"
        }
    }

    private static func elementLine(_ entry: Outline.Entry) -> String {
        let collapsed = SelectorTextMatcher.collapseWhitespace(entry.label)
        let truncated = collapsed.count > 60
            ? String(collapsed.prefix(59)) + "…"
            : collapsed
        let label = truncated
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let frame = "(\(entry.frame.x),\(entry.frame.y) \(entry.frame.width)x\(entry.frame.height))"
        let states = entry.states.map { "  \($0)" }.joined()
        return "  @\(entry.aliases.at)  \(entry.role)  \"\(label)\"  \(frame)\(states)"
    }

    private struct RegionKey: Hashable {
        let kind: String
        let label: String?
    }
}

private extension TVOSOutlineRenderer {
    struct Element {
        let role: String
        let label: String
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
        private var indexByKey: [ElementKey: Int] = [:]

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

            let isFocused = attributeDict["focused"] == "true"
            guard attributeDict["visible"] != "false",
                  frame.width > 0,
                  frame.height > 0
            else { return }

            // Unlabeled chrome is normally dropped to keep the outline
            // small — but focus is the platform's cursor, so an element
            // that carries it must stay visible even without text;
            // otherwise `remote` reports "no focused element" while focus
            // exists. It renders with an empty label and its role.
            let text = nonEmpty(attributeDict["label"])
                ?? nonEmpty(attributeDict["name"])
                ?? nonEmpty(attributeDict["value"])
            guard let label = text ?? (isFocused ? "" : nil) else { return }

            var states: [String] = []
            if isFocused { states.append("focused") }
            if attributeDict["enabled"] == "false" { states.append("disabled") }
            if attributeDict["selected"] == "true" { states.append("selected") }
            let key = ElementKey(role: role, label: label, frame: frame)
            if let existingIndex = indexByKey[key] {
                // WebDriver source can emit the same element twice (e.g. a
                // focus overlay sharing the cell's role/label/frame). Keep
                // one row but union the states, so a `focused` duplicate is
                // not silently dropped — focus is the platform's cursor and
                // must survive dedup.
                let existing = elements[existingIndex]
                let mergedStates = existing.states + states.filter { !existing.states.contains($0) }
                elements[existingIndex] = Element(
                    role: existing.role,
                    label: existing.label,
                    frame: existing.frame,
                    states: mergedStates,
                    depth: existing.depth
                )
                return
            }
            indexByKey[key] = elements.count
            elements.append(Element(role: role, label: label, frame: frame, states: states, depth: max(0, depth - 1)))
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
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return value
        }
    }

    struct ElementKey: Hashable {
        let role: String
        let label: String
        let frame: Outline.Frame
    }
}
