/// Pure decisions for typing replacement text into another app with synthetic
/// key events that carry a Unicode string (`CGEventKeyboardSetUnicodeString`).
///
/// Typing replaces the target app's selection the way the user typing would,
/// so it reaches editors that no AX write can (Outlook's compose body) without
/// borrowing the clipboard. Cotypist inserts text system-wide the same way.
public enum UnicodeTypingPlan {

    /// `CGEventKeyboardSetUnicodeString` carries at most 20 UTF-16 units per
    /// event; anything beyond is silently dropped.
    public static let maxUTF16PerEvent = 20

    /// The text split into per-event chunks, each at most `maxUTF16PerEvent`
    /// UTF-16 units, cut only between `Character`s — a surrogate pair split
    /// across two events types U+FFFD, and a combining mark at the start of a
    /// chunk can attach to the wrong base. nil when a single `Character` is
    /// itself over the limit: it cannot be typed faithfully, so the caller
    /// must use another path rather than type part of it.
    public static func chunks(for text: String) -> [String]? {
        var result: [String] = []
        var current = ""
        var currentUnits = 0
        for character in text {
            let units = String(character).utf16.count
            guard units <= maxUTF16PerEvent else { return nil }
            if currentUnits + units > maxUTF16PerEvent {
                result.append(current)
                current = ""
                currentUnits = 0
            }
            current.append(character)
            currentUnits += units
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// Whether synthetic key events will reach the app as literal text under
    /// the current keyboard input source, given its `kTISPropertyInputSourceType`.
    ///
    /// Only a plain keyboard layout qualifies. Under an input method's mode
    /// (Japanese, Pinyin, Korean…) the events go through the input method,
    /// which composes them into something else or holds them in a marked-text
    /// buffer — the edit would not be the one we planned, and would land after
    /// our read-back gave up.
    public static func isSafeInputSourceType(_ type: String?) -> Bool {
        type == "TISTypeKeyboardLayout"
    }
}
