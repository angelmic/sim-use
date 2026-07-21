// SPDX-License-Identifier: Apache-2.0
@testable import SimUseCore
import XCTest

final class TVOSCapabilityErrorTests: XCTestCase {
    func testTouchCommandExplainsFocusDrivenAlternative() {
        let error = TVOSCapabilityError(command: "tap")

        XCTAssertEqual(error.localizedDescription, "`tap` is not supported on tvOS because tvOS navigation is focus-driven.")
        XCTAssertEqual(
            error.hint,
            "Use `sim-use tvos remote <up|down|left|right|select|menu|play-pause|home>` and re-run `sim-use ui` to verify focus. For text entry, focus a text field and use `sim-use tvos type <text>`."
        )
    }
}
