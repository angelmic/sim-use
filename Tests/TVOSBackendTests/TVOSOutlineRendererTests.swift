// SPDX-License-Identifier: Apache-2.0
@testable import TVOSBackend
import Foundation
import SimUseCore
import Testing

@Suite("tvOS outline rendering")
struct TVOSOutlineRendererTests {
    @Test("Duplicate nodes collapse to one row with their states unioned")
    func duplicateNodesMergeStates() throws {
        let source = wrapped("""
        <XCUIElementTypeCell type="XCUIElementTypeCell" name="一般" label="一般" enabled="true" visible="true" focused="false" x="100" y="200" width="780" height="66" />
        <XCUIElementTypeCell type="XCUIElementTypeCell" name="一般" label="一般" enabled="true" visible="true" focused="true" x="100" y="200" width="780" height="66" />
        """)

        let result = try TVOSOutlineRenderer.render(source: source, includeRaw: false)

        let rows = result.entries.filter { $0.label == "一般" }
        #expect(rows.count == 1)
        #expect(rows.first?.states.contains("focused") == true)
    }

    @Test("Distinct states from both duplicates survive the merge")
    func mergeKeepsStatesFromBothCopies() throws {
        let source = wrapped("""
        <XCUIElementTypeCell type="XCUIElementTypeCell" name="一般" label="一般" enabled="true" visible="true" focused="false" selected="true" x="100" y="200" width="780" height="66" />
        <XCUIElementTypeCell type="XCUIElementTypeCell" name="一般" label="一般" enabled="true" visible="true" focused="true" x="100" y="200" width="780" height="66" />
        """)

        let result = try TVOSOutlineRenderer.render(source: source, includeRaw: false)

        let states = result.entries.first(where: { $0.label == "一般" })?.states ?? []
        #expect(states.contains("selected"))
        #expect(states.contains("focused"))
    }

    @Test("Nodes with different frames stay separate rows")
    func differentFramesAreNotMerged() throws {
        let source = wrapped("""
        <XCUIElementTypeCell type="XCUIElementTypeCell" name="一般" label="一般" enabled="true" visible="true" focused="false" x="100" y="200" width="780" height="66" />
        <XCUIElementTypeCell type="XCUIElementTypeCell" name="一般" label="一般" enabled="true" visible="true" focused="false" x="100" y="300" width="780" height="66" />
        """)

        let result = try TVOSOutlineRenderer.render(source: source, includeRaw: false)

        #expect(result.entries.filter { $0.label == "一般" }.count == 2)
    }

    @Test("A focused element with no label/name/value stays in the outline")
    func unlabeledFocusedElementIsKept() throws {
        let source = wrapped("""
        <XCUIElementTypeOther type="XCUIElementTypeOther" enabled="true" visible="true" focused="true" x="100" y="200" width="400" height="300" />
        """)

        let result = try TVOSOutlineRenderer.render(source: source, includeRaw: false)

        let focused = result.entries.first(where: { $0.states.contains("focused") })
        #expect(focused != nil)
        #expect(focused?.role == "Other")
        #expect(focused?.label == "")
    }

    @Test("Unlabeled, unfocused elements are still filtered out")
    func unlabeledUnfocusedElementIsDropped() throws {
        let source = wrapped("""
        <XCUIElementTypeOther type="XCUIElementTypeOther" enabled="true" visible="true" focused="false" x="100" y="200" width="400" height="300" />
        """)

        let result = try TVOSOutlineRenderer.render(source: source, includeRaw: false)

        #expect(result.entries.isEmpty)
    }

    private func wrapped(_ elements: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <AppiumAUT>
          <XCUIElementTypeApplication type="XCUIElementTypeApplication" name="設定" label="設定" enabled="true" visible="true" focused="false" x="0" y="0" width="1920" height="1080" bundleId="com.apple.TVSettings">
        \(elements)
          </XCUIElementTypeApplication>
        </AppiumAUT>
        """
    }
}
