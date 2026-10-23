import Cocoa
import Carbon.HIToolbox
import ApplicationServices
import MenuDuJourCore

/// Last-resort change-case path: copy the selection, transform it, paste it
/// back, put the clipboard back the way it was.
///
/// ## Why this is opt-in
///
/// Every other path in `CaseToggler` is observation-only until it has proved
/// the edit will land. This one cannot be: it drives the target app with
/// synthetic ⌘C and ⌘V, and it borrows the user's clipboard for a moment. That
/// is precisely the thing this project refuses to do by default (CLAUDE.md:
/// never post synthetic events blindly), so it stays behind:
///
///     defaults write com.luca.menudujour enableClipboardCaseFallback -bool YES
///
/// What it buys is the set of apps no AX path can serve — Outlook's compose
/// editor (whose AX writes report success and do nothing), terminals, and rich
/// editors where a whole-value write would flatten formatting.
///
/// ## The four preconditions
///
/// Being opt-in is not a licence to be careless; each of these closes a way
/// this path could act on something that is not a text edit:
///
///  1. **A text-editing context.** The focused element must look like text —
///     a text role, or an element that advertises a text selection. Without
///     this, ⇧F3 in a Finder file list reaches the ⌘C below.
///  2. **A text payload.** `changeCount` advancing proves Copy produced
///     *something*, not that text was selected; a copied file carries a
///     plain-text flavour (its filename). `ClipboardPayloadPolicy` decides.
///  3. **The same app throughout.** The operation spans ~0.9s of waiting, so
///     the originating PID is rechecked immediately before ⌘C and again
///     immediately before ⌘V — a focus switch must never send Paste elsewhere.
///  4. **One at a time.** Two overlapping runs would let the second capture
///     the first's temporary clipboard and restore *that* as the user's.
///
/// The clipboard is restored only if it still holds what we put there — on
/// *every* exit, not just the one that pastes — so a genuine user Copy during
/// the window is left alone. Same for the selection: if no paste happens, the
/// range this path moved to make the copy goes back where it was.
enum ClipboardCaseFallback {

    static let defaultsKey = "enableClipboardCaseFallback"

    /// Toggleable from the menu-bar dropdown or with `defaults write`. Writing
    /// it posts `UserDefaults.didChangeNotification`, which `ShortcutManager`
    /// observes to re-publish the flag into the tap snapshot (so the Outlook
    /// pass-through gate updates without a restart).
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: defaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    enum Result {
        case applied(String)
        /// No selection to work on, or nothing cased in it. Silent, not an error.
        case nothingToDo
        case unavailable(String)
    }

    /// Guards precondition 4. Main-thread only — `attempt` is always called
    /// from the hotkey handler, and the deferred restore is scheduled on main.
    private static var isRunning = false

    /// - Parameters:
    ///   - element: the focused AX element, when there is one.
    ///   - edit: the edit `CaseCycle` planned from the field's AX text, when
    ///     that text was readable. Its target range must end up exactly equal to
    ///     the selection, or we abort rather than transform the wrong text; its
    ///     replacement is what the typing path types.
    ///   - originPID: the process the hotkey was delivered to.
    static func attempt(
        element: AXUIElement?,
        edit: CaseCycle.Edit?,
        originPID: pid_t
    ) -> Result {
        let target = edit?.target
        guard isEnabled else {
            return .unavailable("clipboard fallback is off (\(defaultsKey))")
        }
        guard !isRunning else {
            // A second press while the first is still holding the user's
            // clipboard would capture our temporary value as its "original".
            return .unavailable("clipboard path is already running")
        }

        // Precondition 1: this must be text, not a file list or a canvas.
        guard let element = element, isTextEditingContext(element) else {
            return .unavailable("focused element is not a text-editing context")
        }

        // Everything below borrows something of the user's — their selection,
        // then their clipboard — and every early return has to hand it back.
        // Both used to be undone only on the paths that got as far as pasting
        // (REVIEW.md 2026-07-28 F1 and F5), so a payload we declined, or a
        // focus switch, left the word selected and the clipboard reverted over
        // whatever the user had copied in the meantime. They are obligations
        // now, discharged on the way out, because a fix that has to be
        // remembered at each of eight returns is the bug again.
        let originalSelection = selectedRange(of: element)
        var pasted = false
        var selectionMoved = false
        defer {
            if selectionMoved, !pasted, let original = originalSelection {
                _ = setSelectedRange(element, location: original.location, length: original.length)
            }
        }

        if let target = target {
            // Set before the attempt: a failed `ensureSelection` can still have
            // moved the selection part-way.
            selectionMoved = (originalSelection != target)
            guard ensureSelection(element, equals: target) else {
                return .unavailable("could not select the target range for the clipboard path")
            }
        }

        // Typing first: it edits the selection the way the user typing would,
        // without borrowing the clipboard. It needs the planned edit (so, AX
        // text) and a selection confirmed to be the target — the latter is what
        // keeps it out of terminals, where typing would insert, not replace.
        if let edit = edit {
            switch attemptTyping(element: element, edit: edit, originPID: originPID) {
            case .posted(let result):
                // Events are out and cannot be recalled: the text is (or may
                // yet be) changed, so the selection obligation stands down and
                // the clipboard path must not run on this press — a late
                // delivery plus a paste would be two edits (Ledger L3).
                pasted = true
                return result
            case .declined(let reason):
                log("typing path declined: \(reason) — using the clipboard path")
            }
        }

        isRunning = true
        var restoreScheduled = false
        defer { if !restoreScheduled { isRunning = false } }

        let pasteboard = NSPasteboard.general
        let snapshot = Snapshot.capture()
        let changeCountBeforeCopy = pasteboard.changeCount

        // The clipboard is ours to put back only while it still holds what we
        // last left there. `ourChangeCount` is nil until the synthetic ⌘C, then
        // tracks each write we make; if it stops matching, someone else has
        // copied and the clipboard is now theirs — restoring would overwrite it.
        var ourChangeCount: Int?
        defer {
            if !restoreScheduled, let owned = ourChangeCount {
                if pasteboard.changeCount == owned {
                    snapshot.restore()
                } else {
                    log("clipboard changed under us — leaving it alone")
                }
            }
        }

        guard OriginatingApp.stillFrontmost(originPID, before: "⌘C for the clipboard path") else {
            return .unavailable("focus left the originating app")
        }
        postKey(CGKeyCode(kVK_ANSI_C), flags: .maskCommand)
        guard waitForChangeCount(above: changeCountBeforeCopy, timeout: 0.4) else {
            // Nothing was copied: either nothing is selected, or the app has no
            // Copy command. Either way we have changed nothing.
            log("no clipboard change after ⌘C — nothing selected here")
            return .nothingToDo
        }
        // From here the clipboard holds our copy, so the obligation above owns
        // putting the user's back.
        ourChangeCount = pasteboard.changeCount

        // Precondition 2: a filename is text, but a copied file is not a text
        // selection.
        let types = (pasteboard.types ?? []).map(\.rawValue)
        guard ClipboardPayloadPolicy.isTransformableText(types: types) else {
            log("clipboard payload is not a text selection (\(types.joined(separator: ", ")))")
            return .unavailable("copied content is not a text selection")
        }

        guard let (copied, flavor) = readAttributedString() else {
            return .unavailable("clipboard held no text after ⌘C")
        }
        guard let nextState = AttributedCaseCycle.nextState(for: copied) else {
            log("selection has no cased characters — no-op")
            return .nothingToDo
        }

        let transformed = AttributedCaseCycle.transform(copied, to: nextState)
        guard transformed.string != copied.string else {
            return .nothingToDo
        }

        // Read the pre-paste value while we still can, so the read-back below
        // has something to compare against.
        let valueBeforePaste = stringValue(of: element)
        let expectedValue = expectedValueAfterPaste(
            before: valueBeforePaste, target: target, replacement: transformed.string)

        guard write(transformed, as: flavor) else {
            log("could not re-encode the selection as \(flavor.rawValue) — declining rather than pasting it back without its attachments")
            return .unavailable("selection could not be re-encoded without loss")
        }
        ourChangeCount = pasteboard.changeCount

        guard OriginatingApp.stillFrontmost(originPID, before: "⌘V for the clipboard path") else {
            return .unavailable("focus left the originating app")
        }
        postKey(CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
        // The text is now changed and `originalSelection` describes text that
        // no longer exists, so the selection obligation stands down.
        pasted = true

        let outcome = waitForPaste(
            element: element,
            valueBeforePaste: valueBeforePaste,
            expectedValue: expectedValue,
            timeout: 0.5
        )

        // Restoring too eagerly can beat a lazy reader in the target app, so
        // the clipboard goes back a beat after the paste is believed done —
        // and only if it still holds what we put there. If the user (or
        // anything else) has copied since, that is now their clipboard.
        restoreScheduled = true
        let owned = pasteboard.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            defer { isRunning = false }
            guard NSPasteboard.general.changeCount == owned else {
                log("clipboard changed after our paste — leaving it alone")
                return
            }
            snapshot.restore()
        }

        if let target = target, OriginatingApp.isStillFrontmost(originPID) {
            // Re-select the replacement so a second press keeps cycling the
            // same text instead of the word the caret happens to land in.
            _ = setSelectedRange(
                element,
                location: target.location,
                length: transformed.string.utf16.count
            )
        }

        switch outcome {
        case .diverged:
            return .unavailable("value changed to something unexpected after paste")
        case .verified:
            log("cycled case via clipboard (verified) → \"\(transformed.string)\"")
            return .applied(transformed.string)
        case .unverifiable:
            log("cycled case via clipboard (unverifiable) → \"\(transformed.string)\"")
            return .applied(transformed.string)
        }
    }

    // MARK: - Typing path

    private enum TypingOutcome {
        /// Events were posted; this is the press's final result.
        case posted(Result)
        /// Nothing was posted; the clipboard path may still run.
        case declined(String)
    }

    /// Types `edit.replacement` over the (already confirmed) target selection.
    /// Every precondition is checked before the first event goes out, because
    /// after that there is no way back.
    private static func attemptTyping(
        element: AXUIElement,
        edit: CaseCycle.Edit,
        originPID: pid_t
    ) -> TypingOutcome {
        guard let before = stringValue(of: element) else {
            return .declined("field value is not readable")
        }
        guard let expected = CaseCycle.apply(edit, to: before) else {
            return .declined("planned edit does not fit the current value")
        }
        guard let chunks = UnicodeTypingPlan.chunks(for: edit.replacement), !chunks.isEmpty else {
            return .declined("replacement cannot be split into typeable chunks")
        }
        let sourceType = UnicodeTyper.currentInputSourceType()
        guard UnicodeTypingPlan.isSafeInputSourceType(sourceType) else {
            return .declined("input source is \(sourceType ?? "unknown"), whose input method would capture the keys")
        }
        guard OriginatingApp.stillFrontmost(originPID, before: "typing the change-case replacement") else {
            return .declined("focus left the originating app")
        }

        UnicodeTyper.type(chunks, toPid: originPID)

        switch waitForPaste(element: element, valueBeforePaste: before, expectedValue: expected, timeout: 0.5) {
        case .verified:
            // Re-select the replacement so a second press keeps cycling it.
            _ = setSelectedRange(element, location: edit.target.location, length: edit.replacement.utf16.count)
            log("cycled case via typing (verified, \(chunks.count) event pair(s)) → \"\(edit.replacement)\"")
            return .posted(.applied(edit.replacement))
        case .diverged:
            log("typing DIVERGED: value is neither original nor expected")
            return .posted(.unavailable("value changed to something unexpected after typing"))
        case .unverifiable:
            log("typed \"\(edit.replacement)\" (unverified — value unchanged after 0.5s; not falling back)")
            return .posted(.applied(edit.replacement))
        }
    }

    // MARK: - Paste verification

    private enum PasteOutcome {
        /// The value now reads exactly as the paste should have left it.
        case verified
        /// The app exposes no comparable text — we cannot confirm, only assume.
        case unverifiable
        /// The value changed into something we did not ask for.
        case diverged
    }

    /// What the whole field should read after the paste, when that is knowable.
    /// nil when there is no AX text or no target range to place the
    /// replacement in — in which case the paste is honestly unverifiable
    /// rather than "verified" on the strength of any change at all.
    private static func expectedValueAfterPaste(
        before: String?,
        target: CaseCycle.UTF16Range?,
        replacement: String
    ) -> String? {
        guard let before = before, let target = target else { return nil }
        return CaseCycle.apply(
            CaseCycle.Edit(target: target, replacement: replacement, restored: target),
            to: before
        )
    }

    private static func waitForPaste(
        element: AXUIElement,
        valueBeforePaste: String?,
        expectedValue: String?,
        timeout: TimeInterval
    ) -> PasteOutcome {
        guard let before = valueBeforePaste, let expected = expectedValue else {
            // Nothing to compare against — give the app a moment and say so.
            Thread.sleep(forTimeInterval: 0.15)
            return .unverifiable
        }
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let now = stringValue(of: element) {
                if now == expected { return .verified }
                // Changed, but not into what we asked for: the same condition
                // the AX cascade treats as an abort.
                if now != before { return .diverged }
            }
            usleep(20_000)
        } while Date() < deadline
        return .unverifiable
    }

    // MARK: - Preconditions

    /// True when the focused element is somewhere text is edited. Deliberately
    /// strict: an element that exposes no text at all is indistinguishable
    /// from a file list, and the cost of guessing wrong is a synthetic paste.
    private static func isTextEditingContext(_ element: AXUIElement) -> Bool {
        let textRoles: Set<String> = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String,
            "AXWebArea",
        ]
        if let role = role(of: element), textRoles.contains(role) { return true }

        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success,
              let list = names as? [String] else { return false }
        return list.contains(kAXSelectedTextAttribute as String)
            || list.contains(kAXSelectedTextRangeAttribute as String)
    }

    private static func role(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXRoleAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    // MARK: - Pasteboard

    /// Every flavour of every item currently on the pasteboard, so the user's
    /// clipboard survives our round trip intact rather than as plain text.
    private struct Snapshot {
        let items: [[String: Data]]

        static func capture() -> Snapshot {
            let pasteboard = NSPasteboard.general
            let items = (pasteboard.pasteboardItems ?? []).map { item in
                item.types.reduce(into: [String: Data]()) { partial, type in
                    if let data = item.data(forType: type) {
                        partial[type.rawValue] = data
                    }
                }
            }
            return Snapshot(items: items)
        }

        func restore() {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            guard !items.isEmpty else { return }
            let restored = items.map { flavours -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in flavours {
                    item.setData(data, forType: NSPasteboard.PasteboardType(type))
                }
                return item
            }
            pasteboard.writeObjects(restored)
        }
    }

    private static func waitForChangeCount(above previous: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if NSPasteboard.general.changeCount != previous { return true }
            usleep(10_000)
        } while Date() < deadline
        return false
    }

    /// Which representation the copy came from — and therefore the one it has
    /// to go back as.
    ///
    /// RTFD is the only flavour that carries attachments (an inline image, an
    /// attached file). Reading `.rtf` in preference to it, and re-encoding
    /// everything as RTF on the way out, silently dropped those attachments —
    /// and since ⌘V replaces the selection they came from, "dropped" means
    /// deleted from the user's document (REVIEW.md 2026-07-28 F2).
    private enum TextFlavor: String {
        case rtfd, rtf, plain
    }

    /// The richest representation on the pasteboard, and which one it was.
    private static func readAttributedString() -> (text: NSAttributedString, flavor: TextFlavor)? {
        let pasteboard = NSPasteboard.general
        if let data = pasteboard.data(forType: .rtfd),
           let attributed = NSAttributedString(rtfd: data, documentAttributes: nil) {
            return (attributed, .rtfd)
        }
        if let data = pasteboard.data(forType: .rtf),
           let attributed = NSAttributedString(rtf: data, documentAttributes: nil) {
            return (attributed, .rtf)
        }
        if let plain = pasteboard.string(forType: .string) {
            return (NSAttributedString(string: plain), .plain)
        }
        return nil
    }

    /// Put the transformed text back in the flavour it arrived in. Returns
    /// false if it cannot be encoded that way, which is a refusal to paste
    /// rather than a reason to paste something lossy: the caller declines and
    /// the user's text is left exactly as it was.
    private static func write(_ attributed: NSAttributedString, as flavor: TextFlavor) -> Bool {
        let full = NSRange(location: 0, length: attributed.length)
        var payloads: [(NSPasteboard.PasteboardType, Data)] = []

        switch flavor {
        case .rtfd:
            guard let rtfd = attributed.rtfd(from: full, documentAttributes: [:]) else {
                return false
            }
            payloads.append((.rtfd, rtfd))
            // An RTF flavour alongside it, for readers that cannot take RTFD.
            // Declared second so anything that understands both — including the
            // app we just copied from, which produced the RTFD — prefers the
            // representation that still has the attachments.
            if let rtf = attributed.rtf(from: full, documentAttributes: [:]) {
                payloads.append((.rtf, rtf))
            }
        case .rtf:
            guard let rtf = attributed.rtf(from: full, documentAttributes: [:]) else {
                return false
            }
            payloads.append((.rtf, rtf))
        case .plain:
            break
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        for (type, data) in payloads {
            pasteboard.setData(data, forType: type)
        }
        pasteboard.setString(attributed.string, forType: .string)
        return true
    }

    // MARK: - AX helpers

    /// Make the selection exactly `target`, either because it already is or by
    /// setting it, confirmed by read-back. Chromium applies the write on a
    /// later accessibility pass, hence the poll.
    private static func ensureSelection(
        _ element: AXUIElement,
        equals target: CaseCycle.UTF16Range
    ) -> Bool {
        if let current = selectedRange(of: element), current == target { return true }
        guard setSelectedRange(element, location: target.location, length: target.length) else {
            return false
        }
        let deadline = Date().addingTimeInterval(0.2)
        repeat {
            if let current = selectedRange(of: element), current == target { return true }
            usleep(5_000)
        } while Date() < deadline
        return false
    }

    private static func selectedRange(of element: AXUIElement) -> CaseCycle.UTF16Range? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let axValue = value else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(axValue as! AXValue, .cfRange, &range) else { return nil }
        return CaseCycle.UTF16Range(location: range.location, length: range.length)
    }

    private static func setSelectedRange(
        _ element: AXUIElement, location: Int, length: Int
    ) -> Bool {
        guard let value = AXValueCreate(.cfRange, [CFRange(location: location, length: length)])
        else { return false }
        return AXUIElementSetAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }

    private static func stringValue(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    // MARK: - Event helpers

    private static func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
        // Set the flags exactly. The hotkey's own ⇧ is usually still physically
        // held, and ⇧⌘V is Paste and Match Style in most apps — which would
        // strip the formatting this path exists to preserve.
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// NSLog via "%@" — see AccessibilityHelper.log.
    private static func log(_ message: String) {
        NSLog("%@", "[Menu du Jour] ClipboardCaseFallback: \(message)")
    }
}
