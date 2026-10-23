import Foundation
import XCTest
@testable import MenuDuJourCore

final class AttributedCaseCycleTests: XCTestCase {

    private let boldKey = NSAttributedString.Key("test.bold")
    private let linkKey = NSAttributedString.Key("test.link")

    private func makeAttributed(_ runs: [(String, [NSAttributedString.Key: Any])]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (text, attributes) in runs {
            result.append(NSAttributedString(string: text, attributes: attributes))
        }
        return result
    }

    /// Returns the runs as (text, attribute keys) so tests can assert on the
    /// shape of the styling without depending on value equality.
    private func runs(of attributed: NSAttributedString) -> [(String, Set<NSAttributedString.Key>)] {
        var result: [(String, Set<NSAttributedString.Key>)] = []
        attributed.enumerateAttributes(
            in: NSRange(location: 0, length: attributed.length)
        ) { attributes, range, _ in
            let text = (attributed.string as NSString).substring(with: range)
            result.append((text, Set(attributes.keys)))
        }
        return result
    }

    func testUppercasingKeepsEveryRunBoundaryAndItsAttributes() {
        let input = makeAttributed([("hello ", [:]), ("world", [boldKey: true])])

        let output = AttributedCaseCycle.transform(input, to: .upper)

        XCTAssertEqual(output.string, "HELLO WORLD")
        let outputRuns = runs(of: output)
        XCTAssertEqual(outputRuns.count, 2)
        XCTAssertEqual(outputRuns[0].0, "HELLO ")
        XCTAssertTrue(outputRuns[0].1.isEmpty)
        XCTAssertEqual(outputRuns[1].0, "WORLD")
        XCTAssertEqual(outputRuns[1].1, [boldKey])
    }

    /// The reason this type exists: a run boundary in the middle of a word must
    /// not look like the start of a new word to the title-caser.
    func testTitleCasingIsDecidedOverTheWholeStringNotPerRun() {
        let input = makeAttributed([("he", [boldKey: true]), ("llo world", [:])])

        let output = AttributedCaseCycle.transform(input, to: .title)

        XCTAssertEqual(output.string, "Hello World")
        let outputRuns = runs(of: output)
        XCTAssertEqual(outputRuns.map(\.0), ["He", "llo World"])
        XCTAssertEqual(outputRuns[0].1, [boldKey])
    }

    func testLowercasingPreservesDistinctAttributeSets() {
        let input = makeAttributed([
            ("CLICK ", [:]),
            ("HERE", [linkKey: "https://example.com"]),
            ("!", [boldKey: true]),
        ])

        let output = AttributedCaseCycle.transform(input, to: .lower)

        XCTAssertEqual(output.string, "click here!")
        XCTAssertEqual(runs(of: output).map(\.0), ["click ", "here", "!"])
        XCTAssertEqual(runs(of: output)[1].1, [linkKey])
    }

    /// ß uppercases to SS, so offsets shift and run ranges cannot be reused.
    /// The text must still be correct, and every run must keep its attributes.
    func testLengthChangingTransformStillPreservesAttributesPerRun() {
        let input = makeAttributed([("stra", [:]), ("ße", [boldKey: true])])

        let output = AttributedCaseCycle.transform(input, to: .upper)

        XCTAssertEqual(output.string, "STRASSE")
        let outputRuns = runs(of: output)
        XCTAssertEqual(outputRuns.map(\.0), ["STRA", "SSE"])
        XCTAssertEqual(outputRuns[1].1, [boldKey])
    }

    /// REVIEW.md 2026-07-28 F3. A length-changing character used to abandon the
    /// whole-string result and re-case each run on its own, which made every
    /// style boundary look like a word boundary: "ßa" + "bc" title-cased to
    /// "SSa" + "Bc". The case decision must still be made once, over the whole
    /// string, however the offsets shift.
    func testTitleCasingStaysWholeStringWhenACharacterExpands() {
        let input = makeAttributed([("ßa", [boldKey: true]), ("bc", [:])])

        let output = AttributedCaseCycle.transform(input, to: .title)

        XCTAssertEqual(output.string, "SSabc")
        let outputRuns = runs(of: output)
        XCTAssertEqual(outputRuns.map(\.0), ["SSa", "bc"])
        XCTAssertEqual(outputRuns[0].1, [boldKey])
    }

    /// The same defect with a ligature, and with the expansion in its own run:
    /// per-run casing restarted the word at "le" and produced "FILe".
    func testTitleCasingWithALigatureRunKeepsTheRestOfTheWordLowercase() {
        let input = makeAttributed([("ﬁ", [boldKey: true]), ("le", [:])])

        let output = AttributedCaseCycle.transform(input, to: .title)

        XCTAssertEqual(output.string, "FIle")
        XCTAssertEqual(runs(of: output).map(\.0), ["FI", "le"])
        XCTAssertEqual(runs(of: output)[0].1, [boldKey])
    }

    /// An expansion in the first run must not restart the word in *any* later
    /// run: per-run casing produced "SS" + "Ab" + "Cd".
    func testExpansionDoesNotRestartTitleCasingInLaterRuns() {
        let input = makeAttributed([
            ("ß", [boldKey: true]),
            ("ab", [:]),
            ("cd", [linkKey: "https://example.com"]),
        ])

        let output = AttributedCaseCycle.transform(input, to: .title)

        XCTAssertEqual(output.string, "SSabcd")
        let outputRuns = runs(of: output)
        XCTAssertEqual(outputRuns.map(\.0), ["SS", "ab", "cd"])
        XCTAssertEqual(outputRuns[0].1, [boldKey])
        XCTAssertEqual(outputRuns[2].1, [linkKey])
    }

    func testSurrogatePairsDoNotShiftRunBoundaries() {
        let input = makeAttributed([("hi 🎉 ", [:]), ("there", [boldKey: true])])

        let output = AttributedCaseCycle.transform(input, to: .upper)

        XCTAssertEqual(output.string, "HI 🎉 THERE")
        XCTAssertEqual(runs(of: output).map(\.0), ["HI 🎉 ", "THERE"])
        XCTAssertEqual(runs(of: output)[1].1, [boldKey])
    }

    /// An inline attachment is one uncased object-replacement character with an
    /// attribute on it. The transform must carry it through untouched — it is
    /// the payload REVIEW.md 2026-07-28 F2 is about, and the clipboard path
    /// re-encodes whatever comes out of here.
    func testAttachmentCharacterKeepsItsRunAndAttribute() {
        let attachmentKey = NSAttributedString.Key("test.attachment")
        let input = makeAttributed([
            ("see ", [:]),
            ("\u{FFFC}", [attachmentKey: "image.png"]),
            (" here", [:]),
        ])

        let output = AttributedCaseCycle.transform(input, to: .upper)

        XCTAssertEqual(output.string, "SEE \u{FFFC} HERE")
        let outputRuns = runs(of: output)
        XCTAssertEqual(outputRuns.map(\.0), ["SEE ", "\u{FFFC}", " HERE"])
        XCTAssertEqual(outputRuns[1].1, [attachmentKey])
    }

    func testEmptyStringIsReturnedUnchanged() {
        let input = NSAttributedString(string: "")
        XCTAssertEqual(AttributedCaseCycle.transform(input, to: .upper).string, "")
    }

    // MARK: - Cycle state

    func testNextStateMatchesThePlainCycle() {
        XCTAssertEqual(
            AttributedCaseCycle.nextState(for: NSAttributedString(string: "hello")), .title)
        XCTAssertEqual(
            AttributedCaseCycle.nextState(for: NSAttributedString(string: "Hello")), .upper)
        XCTAssertEqual(
            AttributedCaseCycle.nextState(for: NSAttributedString(string: "HELLO")), .lower)
    }

    func testNextStateIsNilWhenNothingIsCased() {
        XCTAssertNil(AttributedCaseCycle.nextState(for: NSAttributedString(string: "1234 …")))
    }

    /// The state must come from the text alone — styling must not change it.
    func testClassifyIgnoresAttributes() {
        let input = makeAttributed([("HEL", [boldKey: true]), ("LO", [:])])
        XCTAssertEqual(AttributedCaseCycle.classify(input), .upper)
    }
}
