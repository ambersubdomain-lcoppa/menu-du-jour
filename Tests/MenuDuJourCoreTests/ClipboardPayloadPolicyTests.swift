import XCTest
@testable import MenuDuJourCore

final class ClipboardPayloadPolicyTests: XCTestCase {

    // Flavour sets as the real apps actually put them on the pasteboard.
    private let textEditSelection = [
        "public.rtf", "public.utf8-plain-text", "NSStringPboardType",
    ]
    private let browserSelection = [
        "public.html", "public.rtf", "public.utf8-plain-text",
    ]
    private let terminalSelection = ["public.utf8-plain-text"]
    private let finderFileCopy = [
        "public.file-url", "NSFilenamesPboardType", "public.utf8-plain-text",
    ]
    private let screenshotCopy = ["public.png", "public.tiff"]
    private let copiedLink = ["public.url", "public.utf8-plain-text"]

    func testAcceptsOrdinaryTextSelections() {
        XCTAssertTrue(ClipboardPayloadPolicy.isTransformableText(types: textEditSelection))
        XCTAssertTrue(ClipboardPayloadPolicy.isTransformableText(types: browserSelection))
        XCTAssertTrue(ClipboardPayloadPolicy.isTransformableText(types: terminalSelection))
    }

    /// The finding this policy exists for: a Finder file copy carries a plain
    /// text flavour (the filename), so "there is text on the pasteboard" is not
    /// evidence that the user selected text.
    func testRejectsFileCopyEvenThoughItCarriesAPlainTextFlavour() {
        XCTAssertFalse(ClipboardPayloadPolicy.isTransformableText(types: finderFileCopy))
    }

    func testRejectsImagesAndOtherObjectPayloads() {
        XCTAssertFalse(ClipboardPayloadPolicy.isTransformableText(types: screenshotCopy))
        XCTAssertFalse(ClipboardPayloadPolicy.isTransformableText(types: copiedLink))
        XCTAssertFalse(ClipboardPayloadPolicy.isTransformableText(types: ["public.vcard"]))
    }

    func testRejectsAnEmptyOrTextlessPayload() {
        XCTAssertFalse(ClipboardPayloadPolicy.isTransformableText(types: []))
        XCTAssertFalse(ClipboardPayloadPolicy.isTransformableText(types: ["com.acme.customthing"]))
    }

    /// An unknown extra flavour alongside real text must not veto the edit —
    /// apps add private flavours to ordinary text selections all the time.
    func testUnknownExtraFlavoursDoNotVetoRealText() {
        XCTAssertTrue(ClipboardPayloadPolicy.isTransformableText(
            types: ["public.utf8-plain-text", "com.microsoft.ole", "com.acme.private"]))
    }

    func testRejectionIsCaseInsensitiveOnFlavourNames() {
        XCTAssertFalse(ClipboardPayloadPolicy.isTransformableText(
            types: ["PUBLIC.FILE-URL", "public.utf8-plain-text"]))
    }
}
