import XCTest
import CoreGraphics
@testable import MenuDuJourCore

final class CaretRangeTests: XCTestCase {

    // A caret sitting after some text: query the char *before* the caret and use
    // its trailing edge, falling back to the very first char if that fails.
    func testCaretWithTextBefore() {
        let plans = CaretRange.queryPlans(location: 5, length: 0)
        XCTAssertEqual(plans, [
            CaretQuery(location: 4, length: 1, edge: .trailing),
            CaretQuery(location: 0, length: 1, edge: .leading),
        ])
    }

    // A non-empty selection: use the last selected char's CENTER — a click on the
    // trailing edge lands on the selection boundary and, depending on rounding,
    // just outside it, which makes Word-family apps drop the selection and
    // reselect the word under the cursor. Then the whole range, then the
    // first-char fallback. (Querying the whole multi-line range first would
    // return a bounding box far from the caret — hence last-char.)
    func testSelectionClicksInsideLastSelectedChar() {
        let plans = CaretRange.queryPlans(location: 2, length: 3)
        XCTAssertEqual(plans, [
            CaretQuery(location: 4, length: 1, edge: .center),
            CaretQuery(location: 2, length: 3, edge: .trailing),
            CaretQuery(location: 0, length: 1, edge: .leading),
        ])
    }

    func testPointForCenterEdge() {
        let rect = CGRect(x: 10, y: 20, width: 8, height: 16)
        XCTAssertEqual(CaretRange.point(forEdge: .center, in: rect), CGPoint(x: 14, y: 28))
    }

    // Caret at the very start: only the first-char leading edge is meaningful.
    func testCaretAtStart() {
        let plans = CaretRange.queryPlans(location: 0, length: 0)
        XCTAssertEqual(plans, [
            CaretQuery(location: 0, length: 1, edge: .leading),
        ])
    }

    // Edge derivation from a resolved rect.
    func testPointForTrailingEdge() {
        let rect = CGRect(x: 10, y: 20, width: 8, height: 16)
        XCTAssertEqual(CaretRange.point(forEdge: .trailing, in: rect), CGPoint(x: 18, y: 28))
    }

    func testPointForLeadingEdge() {
        let rect = CGRect(x: 10, y: 20, width: 8, height: 16)
        XCTAssertEqual(CaretRange.point(forEdge: .leading, in: rect), CGPoint(x: 10, y: 28))
    }

    func testTextMarkerSelectionTargetsCharactersInsideSelection() {
        XCTAssertEqual(CaretRange.textMarkerQueryPlans(hasSelection: true), [
            TextMarkerQuery(range: .previousCharacter, edge: .center),
            TextMarkerQuery(range: .nextCharacter, edge: .center),
            TextMarkerQuery(range: .selected, edge: .center),
        ])
    }

    func testCollapsedTextMarkerPrefersCaretThenAdjacentCharacters() {
        XCTAssertEqual(CaretRange.textMarkerQueryPlans(hasSelection: false), [
            TextMarkerQuery(range: .selected, edge: .leading),
            TextMarkerQuery(range: .previousCharacter, edge: .trailing),
            TextMarkerQuery(range: .nextCharacter, edge: .leading),
        ])
    }

    func testTextMarkerBoundariesPreserveLogicalDirection() {
        let start = CGPoint(x: 20, y: 10)
        let end = CGPoint(x: 10, y: 10)

        XCTAssertEqual(
            CaretRange.point(forEdge: .leading, startBoundary: start, endBoundary: end),
            start
        )
        XCTAssertEqual(
            CaretRange.point(forEdge: .trailing, startBoundary: start, endBoundary: end),
            end
        )
        XCTAssertEqual(
            CaretRange.point(forEdge: .center, startBoundary: start, endBoundary: end),
            CGPoint(x: 15, y: 10)
        )
    }
}
