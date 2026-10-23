import Carbon
import CoreGraphics
import MenuDuJourCore

/// Types text into one app with synthetic key events that carry the text as a
/// Unicode string — the event's key code is irrelevant to apps that honour the
/// string, which is every text system that accepts typing (AppKit, WebKit,
/// Chromium, Electron). Decisions live in `UnicodeTypingPlan`; this only reads
/// the input source and posts.
enum UnicodeTyper {

    /// `kTISPropertyInputSourceType` of the current keyboard input source,
    /// e.g. "TISTypeKeyboardLayout" or "TISTypeKeyboardInputMode".
    static func currentInputSourceType() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceType)
        else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    /// Posts each chunk as a key-down/key-up pair to `pid` only (as
    /// `ContextMenuKey` does), so no other app or event tap sees the text.
    ///
    /// Flags are set to exactly none: the change-case hotkey's ⇧ is usually
    /// still physically held, and a private event source keeps that physical
    /// state out of the synthetic events as well.
    static func type(_ chunks: [String], toPid pid: pid_t) {
        let source = CGEventSource(stateID: .privateState)
        for chunk in chunks {
            let units = Array(chunk.utf16)
            for keyDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown)
                else { continue }
                event.flags = []
                units.withUnsafeBufferPointer { buffer in
                    event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                }
                event.postToPid(pid)
            }
        }
    }
}
