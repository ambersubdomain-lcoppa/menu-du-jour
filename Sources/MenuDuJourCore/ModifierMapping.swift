import AppKit
import Carbon
import CoreGraphics

/// Conversions between the three modifier representations this app juggles:
///   - `CGEventFlags`        (from the event tap)
///   - `NSEvent.ModifierFlags` (from the shortcut recorder)
///   - Carbon modifier bits  (`optionKey`, `cmdKey`, … — how shortcuts are stored)
/// plus the display symbols. Kept pure and framework-light so the matching
/// logic — the thing that decides whether the hotkey fires — is unit-testable.
public enum KeyModifiers {

    /// Convert `CGEventFlags` (event tap) to Carbon modifier bits.
    public static func carbonModifiers(fromCGEventFlags flags: CGEventFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.maskControl)   { carbon |= UInt32(controlKey) }
        if flags.contains(.maskAlternate) { carbon |= UInt32(optionKey) }
        if flags.contains(.maskShift)     { carbon |= UInt32(shiftKey) }
        if flags.contains(.maskCommand)   { carbon |= UInt32(cmdKey) }
        return carbon
    }

    /// Convert `NSEvent.ModifierFlags` (shortcut recorder) to Carbon modifier bits.
    public static func carbonModifiers(fromCocoaFlags flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option)  { carbon |= UInt32(optionKey) }
        if flags.contains(.shift)   { carbon |= UInt32(shiftKey) }
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        return carbon
    }

    /// Render Carbon modifier bits as display symbols in the canonical
    /// ⌃⌥⇧⌘ order (matches how macOS shows shortcuts).
    public static func symbols(fromCarbonModifiers modifiers: UInt32) -> String {
        var parts: [String] = []
        if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if modifiers & UInt32(optionKey) != 0  { parts.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0   { parts.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0     { parts.append("⌘") }
        return parts.joined()
    }
}
