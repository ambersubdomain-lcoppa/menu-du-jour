import XCTest
@testable import MenuDuJourCore

final class MenuPollPolicyTests: XCTestCase {

    func testMenuOpenWithoutFocusedItemHighlightsFirstItem() {
        XCTAssertEqual(
            MenuPollPolicy.action(menuOpen: true, menuItemFocused: false, deadlineReached: false),
            .highlightFirstItem
        )
    }

    func testFocusedMenuItemStopsWithoutArrow() {
        XCTAssertEqual(
            MenuPollPolicy.action(menuOpen: true, menuItemFocused: true, deadlineReached: false),
            .stop
        )
    }

    func testFocusedMenuItemWinsEvenAtDeadline() {
        XCTAssertEqual(
            MenuPollPolicy.action(menuOpen: true, menuItemFocused: true, deadlineReached: true),
            .stop
        )
    }

    func testDeadlineWithoutMenuStops() {
        XCTAssertEqual(
            MenuPollPolicy.action(menuOpen: false, menuItemFocused: false, deadlineReached: true),
            .stop
        )
    }

    func testNoMenuBeforeDeadlineKeepsPolling() {
        XCTAssertEqual(
            MenuPollPolicy.action(menuOpen: false, menuItemFocused: false, deadlineReached: false),
            .keepPolling
        )
    }
}
