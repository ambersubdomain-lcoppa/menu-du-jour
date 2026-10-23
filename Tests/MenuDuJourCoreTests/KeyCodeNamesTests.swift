import XCTest
import Carbon
@testable import MenuDuJourCore

final class KeyCodeNamesTests: XCTestCase {

    func testKeyCodeToString_letter() {
        XCTAssertEqual(KeyCodeNames.string(forKeyCode: 0x2E), "M")
    }

    func testKeyCodeToString_functionKey() {
        XCTAssertEqual(KeyCodeNames.string(forKeyCode: 0x6D), "F10")
    }

    func testKeyCodeToString_unknownFallback() {
        // Unmapped codes render as "Key<n>" rather than crashing or returning empty.
        XCTAssertEqual(KeyCodeNames.string(forKeyCode: 0x99), "Key153")
    }

    // MARK: - Composed display string (symbols + key)

    func testDisplayString_optionM() {
        let s = KeyCodeNames.displayString(keyCode: 0x2E, carbonModifiers: UInt32(optionKey))
        XCTAssertEqual(s, "⌥M")
    }

    func testDisplayString_multipleModifiers() {
        let mods = UInt32(cmdKey) | UInt32(shiftKey)
        XCTAssertEqual(KeyCodeNames.displayString(keyCode: 0x31, carbonModifiers: mods), "⇧⌘Space")
    }
}
