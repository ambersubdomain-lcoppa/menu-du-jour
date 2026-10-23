import XCTest
@testable import MenuDuJourCore

final class UnicodeTypingPlanTests: XCTestCase {

    // MARK: - Chunking

    func testEmptyStringHasNoChunks() {
        XCTAssertEqual(UnicodeTypingPlan.chunks(for: ""), [])
    }

    func testShortWordIsOneChunk() {
        XCTAssertEqual(UnicodeTypingPlan.chunks(for: "National"), ["National"])
    }

    func testExactlyTheLimitIsOneChunk() {
        let twenty = String(repeating: "a", count: 20)
        XCTAssertEqual(UnicodeTypingPlan.chunks(for: twenty), [twenty])
    }

    func testOverTheLimitSplitsWithoutExceedingIt() {
        let text = String(repeating: "b", count: 45)
        let chunks = UnicodeTypingPlan.chunks(for: text)
        XCTAssertEqual(chunks?.joined(), text)
        XCTAssertEqual(chunks?.map { $0.utf16.count }, [20, 20, 5])
    }

    /// A surrogate pair straddling the 20-unit boundary must move whole into
    /// the next chunk: half a pair posted on its own types U+FFFD.
    func testSurrogatePairIsNeverSplit() {
        let text = String(repeating: "c", count: 19) + "𝐀" + "d"   // 𝐀 is 2 UTF-16 units
        let chunks = UnicodeTypingPlan.chunks(for: text)
        XCTAssertEqual(chunks, [String(repeating: "c", count: 19), "𝐀d"])
    }

    /// A base letter and its combining mark stay together, so the app never
    /// sees a dangling combining mark at the start of a chunk.
    func testCombiningSequenceStaysWhole() {
        let text = String(repeating: "e", count: 19) + "e\u{0301}"   // é decomposed
        let chunks = UnicodeTypingPlan.chunks(for: text)
        XCTAssertEqual(chunks, [String(repeating: "e", count: 19), "e\u{0301}"])
    }

    func testSingleCharacterOverTheLimitMakesThePlanFail() {
        // One grapheme of 21 UTF-16 units: a base plus 20 combining marks.
        let oversize = "a" + String(repeating: "\u{0301}", count: 20)
        XCTAssertEqual(oversize.count, 1)
        XCTAssertNil(UnicodeTypingPlan.chunks(for: "ok" + oversize))
    }

    // MARK: - Input source

    func testPlainKeyboardLayoutIsSafe() {
        XCTAssertTrue(UnicodeTypingPlan.isSafeInputSourceType("TISTypeKeyboardLayout"))
    }

    /// An input method's mode (Japanese Romaji, Pinyin…) would capture the
    /// synthetic key events and compose them, so typing must decline.
    func testInputMethodModesAreNotSafe() {
        XCTAssertFalse(UnicodeTypingPlan.isSafeInputSourceType("TISTypeKeyboardInputMode"))
        XCTAssertFalse(UnicodeTypingPlan.isSafeInputSourceType("TISTypeKeyboardInputMethodWithoutModes"))
        XCTAssertFalse(UnicodeTypingPlan.isSafeInputSourceType("TISTypeKeyboardInputMethodModeEnabled"))
    }

    func testUnknownOrMissingTypeIsNotSafe() {
        XCTAssertFalse(UnicodeTypingPlan.isSafeInputSourceType(nil))
        XCTAssertFalse(UnicodeTypingPlan.isSafeInputSourceType(""))
    }
}
