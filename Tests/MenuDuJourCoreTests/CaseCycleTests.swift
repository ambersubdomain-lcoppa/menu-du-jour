import XCTest
@testable import MenuDuJourCore

final class CaseCycleTests: XCTestCase {

    // MARK: - classify

    func testClassifyLower() {
        XCTAssertEqual(CaseCycle.classify("hello"), .lower)
    }

    func testClassifyTitle() {
        XCTAssertEqual(CaseCycle.classify("Hello"), .title)
    }

    func testClassifyUpper() {
        XCTAssertEqual(CaseCycle.classify("HELLO"), .upper)
    }

    func testClassifyMixedIsOther() {
        XCTAssertEqual(CaseCycle.classify("hELLo"), .other)
        XCTAssertEqual(CaseCycle.classify("iPhone"), .other)
    }

    // A single uppercase letter matches both the "title" and "upper" patterns;
    // upper wins so repeated presses toggle a ↔ A instead of sticking on A.
    func testClassifySingleUppercaseLetterIsUpper() {
        XCTAssertEqual(CaseCycle.classify("A"), .upper)
    }

    func testClassifyUncasedReturnsNil() {
        XCTAssertNil(CaseCycle.classify("123"))
        XCTAssertNil(CaseCycle.classify("🎉"))
        XCTAssertNil(CaseCycle.classify(""))
    }

    func testClassifyMultiWordTitle() {
        XCTAssertEqual(CaseCycle.classify("Some Words Here"), .title)
    }

    func testClassifyMultiWordMixedIsOther() {
        XCTAssertEqual(CaseCycle.classify("Some words"), .other)
    }

    // MARK: - next(after:)

    func testCycleOrder() {
        XCTAssertEqual(CaseCycle.next(after: .lower), .title)
        XCTAssertEqual(CaseCycle.next(after: .title), .upper)
        XCTAssertEqual(CaseCycle.next(after: .upper), .lower)
        XCTAssertEqual(CaseCycle.next(after: .other), .lower)
    }

    // MARK: - transform

    func testTransformToTitleSingleWord() {
        XCTAssertEqual(CaseCycle.transform("hello", to: .title), "Hello")
    }

    func testTransformToTitleMultiWord() {
        XCTAssertEqual(CaseCycle.transform("some words here", to: .title), "Some Words Here")
    }

    func testTransformTitleLowercasesTheRest() {
        XCTAssertEqual(CaseCycle.transform("hELLO wORLD", to: .title), "Hello World")
    }

    func testTransformToUpperKeepsAccents() {
        XCTAssertEqual(CaseCycle.transform("héllo", to: .upper), "HÉLLO")
    }

    func testTransformToLower() {
        XCTAssertEqual(CaseCycle.transform("HELLO", to: .lower), "hello")
    }

    // Apostrophe joins letters into ONE word: only the first letter is capitalized.
    func testTransformApostropheWordIsOneWord() {
        XCTAssertEqual(CaseCycle.transform("dell'acqua", to: .title), "Dell'acqua")
    }

    // ß uppercases to SS — the transform may change UTF-16 length.
    func testTransformSharpS() {
        XCTAssertEqual(CaseCycle.transform("straße", to: .upper), "STRASSE")
    }

    func testTransformPreservesUncasedCharacters() {
        XCTAssertEqual(CaseCycle.transform("foo-bar 123", to: .upper), "FOO-BAR 123")
    }

    // MARK: - transformPieces (REVIEW.md 2026-07-28 F3)

    /// One output string per SOURCE character, so styled text can be re-sliced
    /// along its original run boundaries even when a character changes length.
    func testTransformPiecesIsOnePiecePerSourceCharacter() {
        XCTAssertEqual(CaseCycle.transformPieces("straße", to: .upper),
                       ["S", "T", "R", "A", "SS", "E"])
        XCTAssertEqual(CaseCycle.transformPieces("ßabc", to: .title),
                       ["SS", "a", "b", "c"])
    }

    /// A surrogate pair is one Character and must stay one piece.
    func testTransformPiecesKeepsSurrogatePairsWhole() {
        XCTAssertEqual(CaseCycle.transformPieces("a🎉b", to: .upper), ["A", "🎉", "B"])
    }

    /// The invariant the styled path depends on: joining the pieces reproduces
    /// `transform` exactly. Swift applies no context-sensitive case mapping
    /// (Greek final sigma lowercases to σ, not ς, either way), so a
    /// per-character mapping is equivalent — this test is what catches it if
    /// that ever stops being true.
    func testJoinedPiecesEqualTheWholeStringTransform() {
        let samples = ["straße", "ßabc", "ﬁle", "ΟΔΟΣ", "dell'acqua",
                       "hELLO wORLD", "foo-bar 123", "a🎉b", ""]
        for state in [CaseCycle.CaseState.lower, .upper, .title, .other] {
            for sample in samples {
                XCTAssertEqual(
                    CaseCycle.transformPieces(sample, to: state).joined(),
                    CaseCycle.transform(sample, to: state),
                    "\(sample) → \(state)")
            }
        }
    }

    // MARK: - wordRange

    func testWordRangeCaretInsideWord() {
        // "foo bar baz" — caret inside "bar" (UTF-16 offset 5)
        XCTAssertEqual(CaseCycle.wordRange(in: "foo bar baz", aroundUTF16Offset: 5),
                       CaseCycle.UTF16Range(location: 4, length: 3))
    }

    func testWordRangeCaretAtWordEndBinds() {
        XCTAssertEqual(CaseCycle.wordRange(in: "foo", aroundUTF16Offset: 3),
                       CaseCycle.UTF16Range(location: 0, length: 3))
    }

    func testWordRangeCaretAtWordStartBinds() {
        XCTAssertEqual(CaseCycle.wordRange(in: " foo", aroundUTF16Offset: 1),
                       CaseCycle.UTF16Range(location: 1, length: 3))
    }

    // Between two words, the word ENDING at the caret wins (matches typing flow).
    func testWordRangeBetweenWordsPrefersPreceding() {
        XCTAssertEqual(CaseCycle.wordRange(in: "foo,bar", aroundUTF16Offset: 3),
                       CaseCycle.UTF16Range(location: 0, length: 3))
        XCTAssertEqual(CaseCycle.wordRange(in: "foo,bar", aroundUTF16Offset: 4),
                       CaseCycle.UTF16Range(location: 4, length: 3))
    }

    func testWordRangeCaretInWhitespaceGapIsNil() {
        // "foo  bar" — caret between the two spaces (offset 4): no adjacent word
        XCTAssertNil(CaseCycle.wordRange(in: "foo  bar", aroundUTF16Offset: 4))
    }

    func testWordRangeApostropheWord() {
        XCTAssertEqual(CaseCycle.wordRange(in: "dell'acqua", aroundUTF16Offset: 7),
                       CaseCycle.UTF16Range(location: 0, length: 10))
    }

    func testWordRangeTrailingApostropheExcluded() {
        XCTAssertEqual(CaseCycle.wordRange(in: "boys'", aroundUTF16Offset: 2),
                       CaseCycle.UTF16Range(location: 0, length: 4))
    }

    func testWordRangeDigitsAreWordChars() {
        XCTAssertEqual(CaseCycle.wordRange(in: "abc123", aroundUTF16Offset: 4),
                       CaseCycle.UTF16Range(location: 0, length: 6))
    }

    // "a🎉b": 🎉 is a surrogate pair (UTF-16 offsets: a=0..<1, 🎉=1..<3, b=3..<4).
    // An offset in the middle of the pair belongs to no word.
    func testWordRangeInsideSurrogatePairIsNil() {
        XCTAssertNil(CaseCycle.wordRange(in: "a🎉b", aroundUTF16Offset: 2))
    }

    func testWordRangeOutOfBoundsIsNil() {
        XCTAssertNil(CaseCycle.wordRange(in: "foo", aroundUTF16Offset: 4))
        XCTAssertNil(CaseCycle.wordRange(in: "foo", aroundUTF16Offset: -1))
    }

    func testWordRangeEmptyTextIsNil() {
        XCTAssertNil(CaseCycle.wordRange(in: "", aroundUTF16Offset: 0))
    }

    // MARK: - wordRange in large text (the scan is windowed around the caret)

    /// The scan must not depend on how much text surrounds the caret. This is
    /// the same assertion as `testWordRangeInsideWord`, buried in 200k
    /// characters of filler on both sides.
    func testWordRangeFindsTheWordFarInsideALargeDocument() {
        let filler = String(repeating: "lorem ipsum dolor ", count: 10_000)
        let text = filler + "needle " + filler
        let wordStart = filler.utf16.count

        XCTAssertEqual(
            CaseCycle.wordRange(in: text, aroundUTF16Offset: wordStart + 3),
            CaseCycle.UTF16Range(location: wordStart, length: 6)
        )
    }

    /// A word longer than the scan window must still be returned whole — the
    /// window has to grow outwards across word characters before it is cut.
    func testWordRangeReturnsAWordLongerThanTheScanWindow() {
        let filler = String(repeating: "x ", count: 5_000)
        let longWord = String(repeating: "a", count: 4_000)
        let text = filler + longWord + " tail"
        let wordStart = filler.utf16.count

        XCTAssertEqual(
            CaseCycle.wordRange(in: text, aroundUTF16Offset: wordStart + 2_000),
            CaseCycle.UTF16Range(location: wordStart, length: 4_000)
        )
    }

    /// Windowing must not resurrect a word from elsewhere: whitespace under the
    /// caret is still "nothing to transform", however large the document.
    func testWordRangeInWhitespaceOfALargeDocumentIsNil() {
        let filler = String(repeating: "lorem ipsum dolor ", count: 10_000)
        let text = filler + "a  b" + filler
        let gapOffset = filler.utf16.count + 2

        XCTAssertNil(CaseCycle.wordRange(in: text, aroundUTF16Offset: gapOffset))
    }

    /// Offsets at the very edges of a large document stay correct.
    func testWordRangeAtTheEdgesOfALargeDocument() {
        let filler = String(repeating: "lorem ipsum dolor ", count: 10_000)
        let text = "head " + filler + "tail"

        XCTAssertEqual(
            CaseCycle.wordRange(in: text, aroundUTF16Offset: 2),
            CaseCycle.UTF16Range(location: 0, length: 4)
        )
        XCTAssertEqual(
            CaseCycle.wordRange(in: text, aroundUTF16Offset: text.utf16.count),
            CaseCycle.UTF16Range(location: text.utf16.count - 4, length: 4)
        )
    }

    /// Emoji in the filler keep Character and UTF-16 offsets out of step; the
    /// window boundaries must still be reported in UTF-16 units.
    func testWordRangeIsCorrectWhenSurroundedBySurrogatePairs() {
        let filler = String(repeating: "🎉 ", count: 5_000)
        let text = filler + "needle" + filler
        let wordStart = filler.utf16.count

        XCTAssertEqual(
            CaseCycle.wordRange(in: text, aroundUTF16Offset: wordStart + 3),
            CaseCycle.UTF16Range(location: wordStart, length: 6)
        )
    }

    // MARK: - plan

    func testPlanCaretInLowercaseWord() {
        let edit = CaseCycle.plan(text: "hello world", selectionLocation: 2, selectionLength: 0)
        XCTAssertEqual(edit, CaseCycle.Edit(
            target: CaseCycle.UTF16Range(location: 0, length: 5),
            replacement: "Hello",
            restored: CaseCycle.UTF16Range(location: 2, length: 0)))
    }

    func testPlanSelectionCyclesToTitle() {
        let edit = CaseCycle.plan(text: "some words here", selectionLocation: 0, selectionLength: 15)
        XCTAssertEqual(edit?.replacement, "Some Words Here")
        XCTAssertEqual(edit?.restored, CaseCycle.UTF16Range(location: 0, length: 15))
    }

    func testPlanSelectionTitleCyclesToUpper() {
        let edit = CaseCycle.plan(text: "Some Words Here", selectionLocation: 0, selectionLength: 15)
        XCTAssertEqual(edit?.replacement, "SOME WORDS HERE")
    }

    func testPlanMixedCaseGoesToLower() {
        let edit = CaseCycle.plan(text: "hELLo", selectionLocation: 2, selectionLength: 0)
        XCTAssertEqual(edit?.replacement, "hello")
        XCTAssertEqual(edit?.restored, CaseCycle.UTF16Range(location: 2, length: 0))
    }

    // ß → SS changes UTF-16 length: caret at word end lands after the longer word.
    func testPlanSharpSLengthChangeShiftsCaret() {
        let edit = CaseCycle.plan(text: "Straße", selectionLocation: 6, selectionLength: 0)
        XCTAssertEqual(edit, CaseCycle.Edit(
            target: CaseCycle.UTF16Range(location: 0, length: 6),
            replacement: "STRASSE",
            restored: CaseCycle.UTF16Range(location: 7, length: 0)))
    }

    func testPlanSelectionLengthTracksReplacement() {
        let edit = CaseCycle.plan(text: "straße fine", selectionLocation: 0, selectionLength: 6)
        // "straße" is lower → next is Title: "Straße" (same length here)
        XCTAssertEqual(edit?.restored, CaseCycle.UTF16Range(location: 0, length: 6))
    }

    func testPlanNoCasedCharactersIsNil() {
        XCTAssertNil(CaseCycle.plan(text: "123 456", selectionLocation: 1, selectionLength: 0))
        XCTAssertNil(CaseCycle.plan(text: "foo 123", selectionLocation: 4, selectionLength: 3))
    }

    func testPlanCaretInWhitespaceIsNil() {
        XCTAssertNil(CaseCycle.plan(text: "foo  bar", selectionLocation: 4, selectionLength: 0))
    }

    func testPlanEmptyTextIsNil() {
        XCTAssertNil(CaseCycle.plan(text: "", selectionLocation: 0, selectionLength: 0))
    }

    func testPlanOutOfBoundsSelectionIsNil() {
        XCTAssertNil(CaseCycle.plan(text: "foo", selectionLocation: 2, selectionLength: 5))
        XCTAssertNil(CaseCycle.plan(text: "foo", selectionLocation: -1, selectionLength: 0))
    }

    // Selection that splits a surrogate pair cannot be extracted safely → nil.
    func testPlanSelectionSplittingSurrogateIsNil() {
        XCTAssertNil(CaseCycle.plan(text: "a🎉b", selectionLocation: 0, selectionLength: 2))
    }

    // MARK: - apply

    func testApplyProducesExpectedFullText() {
        let edit = CaseCycle.plan(text: "hello world", selectionLocation: 2, selectionLength: 0)!
        XCTAssertEqual(CaseCycle.apply(edit, to: "hello world"), "Hello world")
    }

    func testApplyWithUTF16LengthChange() {
        let edit = CaseCycle.plan(text: "Straße fine", selectionLocation: 3, selectionLength: 0)!
        XCTAssertEqual(CaseCycle.apply(edit, to: "Straße fine"), "STRASSE fine")
    }

    func testApplyAtTextEnd() {
        let edit = CaseCycle.plan(text: "say hello", selectionLocation: 9, selectionLength: 0)!
        XCTAssertEqual(CaseCycle.apply(edit, to: "say hello"), "say Hello")
    }

    func testApplyOutOfRangeIsNil() {
        let edit = CaseCycle.Edit(
            target: CaseCycle.UTF16Range(location: 20, length: 5),
            replacement: "X",
            restored: CaseCycle.UTF16Range(location: 0, length: 0))
        XCTAssertNil(CaseCycle.apply(edit, to: "short"))
    }

    // MARK: - substring

    func testSubstringExtractsUTF16Range() {
        XCTAssertEqual(CaseCycle.substring(of: "hello world", range: CaseCycle.UTF16Range(location: 6, length: 5)), "world")
    }

    func testSubstringMidSurrogateIsNil() {
        XCTAssertNil(CaseCycle.substring(of: "a🎉b", range: CaseCycle.UTF16Range(location: 0, length: 2)))
    }
}
