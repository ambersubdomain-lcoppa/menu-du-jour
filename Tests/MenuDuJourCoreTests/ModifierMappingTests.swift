import XCTest
import AppKit
import Carbon
import CoreGraphics
@testable import MenuDuJourCore

final class ModifierMappingTests: XCTestCase {

    // MARK: - CGEventFlags → Carbon (used by the event tap to match the hotkey)

    func testCGEventFlagsToCarbon_singleOption() {
        let carbon = KeyModifiers.carbonModifiers(fromCGEventFlags: .maskAlternate)
        XCTAssertEqual(carbon, UInt32(optionKey))
    }

    func testCGEventFlagsToCarbon_combined() {
        let carbon = KeyModifiers.carbonModifiers(fromCGEventFlags: [.maskCommand, .maskShift])
        XCTAssertEqual(carbon, UInt32(cmdKey) | UInt32(shiftKey))
    }

    func testCGEventFlagsToCarbon_none() {
        XCTAssertEqual(KeyModifiers.carbonModifiers(fromCGEventFlags: []), 0)
    }

    // MARK: - NSEvent.ModifierFlags → Carbon (used by the shortcut recorder)

    func testCocoaFlagsToCarbon_combined() {
        let carbon = KeyModifiers.carbonModifiers(fromCocoaFlags: [.control, .command])
        XCTAssertEqual(carbon, UInt32(controlKey) | UInt32(cmdKey))
    }

    // MARK: - Carbon → display symbols

    func testSymbols_singleOption() {
        XCTAssertEqual(KeyModifiers.symbols(fromCarbonModifiers: UInt32(optionKey)), "⌥")
    }

    /// Symbols must always render in a stable ⌃⌥⇧⌘ order regardless of input order.
    func testSymbols_orderingIsStable() {
        let all = UInt32(cmdKey) | UInt32(shiftKey) | UInt32(optionKey) | UInt32(controlKey)
        XCTAssertEqual(KeyModifiers.symbols(fromCarbonModifiers: all), "⌃⌥⇧⌘")
    }

    func testSymbols_none() {
        XCTAssertEqual(KeyModifiers.symbols(fromCarbonModifiers: 0), "")
    }
}
