// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore
import XCTest
@testable import DeviceBackend

final class DeviceOutlineRendererTests: XCTestCase {
    private let source = """
    <XCUIElementTypeApplication type="XCUIElementTypeApplication" name="CATCHPLAY+" label="CATCHPLAY+" bundleId="com.catchplay.app" x="0" y="0" width="393" height="852">
      <XCUIElementTypeButton type="XCUIElementTypeButton" name="searchTab" label="Search" enabled="true" visible="true" x="100" y="800" width="60" height="40"/>
      <XCUIElementTypeSearchField type="XCUIElementTypeSearchField" name="searchField" label="Search movies" value="Inception" enabled="true" visible="true" x="20" y="80" width="353" height="36"/>
      <XCUIElementTypeStaticText type="XCUIElementTypeStaticText" name="Home" label="Home" enabled="true" visible="true" x="20" y="810" width="50" height="20"/>
      <XCUIElementTypeOther type="XCUIElementTypeOther" enabled="true" visible="false" x="0" y="0" width="10" height="10"/>
    </XCUIElementTypeApplication>
    """

    func testParsesScreenAndAppMetadata() throws {
        let result = try DeviceOutlineRenderer.render(source: source, includeRaw: false)
        XCTAssertEqual(result.platform, .ios)
        XCTAssertEqual(result.screen, Outline.Frame(x: 0, y: 0, width: 393, height: 852))
        XCTAssertEqual(result.appLabel, "CATCHPLAY+")
        XCTAssertEqual(result.appPackage, "com.catchplay.app")
    }

    func testDropsInvisibleElements() throws {
        let result = try DeviceOutlineRenderer.render(source: source, includeRaw: false)
        // The invisible XCUIElementTypeOther is dropped; three visible rows remain.
        XCTAssertEqual(result.entries.count, 3)
    }

    func testCarriesAccessibilityIdentifierAsUniqueId() throws {
        let result = try DeviceOutlineRenderer.render(source: source, includeRaw: false)
        let tab = try XCTUnwrap(result.entries.first { $0.role == "Button" })
        XCTAssertEqual(tab.uniqueId, "searchTab")
        XCTAssertEqual(tab.label, "Search")

        let field = try XCTUnwrap(result.entries.first { $0.role == "SearchField" })
        XCTAssertEqual(field.uniqueId, "searchField")
        XCTAssertEqual(field.value, "Inception")

        // name == label ⇒ not a distinct identifier ⇒ no #id.
        let home = try XCTUnwrap(result.entries.first { $0.label == "Home" })
        XCTAssertNil(home.uniqueId)
    }

    func testOutlineTextRendersIdTokens() throws {
        let result = try DeviceOutlineRenderer.render(source: source, includeRaw: false)
        XCTAssertTrue(result.outline.contains("#searchTab"), result.outline)
        XCTAssertTrue(result.outline.contains("#searchField"), result.outline)
        XCTAssertFalse(result.outline.contains("#Home"), result.outline)
        XCTAssertTrue(result.outline.contains("@1"), result.outline)
    }

    func testIncludeRawCarriesSource() throws {
        let withRaw = try DeviceOutlineRenderer.render(source: source, includeRaw: true)
        XCTAssertNotNil(withRaw.raw)
        let without = try DeviceOutlineRenderer.render(source: source, includeRaw: false)
        XCTAssertNil(without.raw)
    }

    func testInvalidXMLThrows() {
        XCTAssertThrowsError(try DeviceOutlineRenderer.render(source: "<broken", includeRaw: false))
    }
}
