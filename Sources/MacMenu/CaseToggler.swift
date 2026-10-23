import Cocoa
import ApplicationServices
import MenuDuJourCore

/// Applies the change-case cycle (⇧F3) to the focused element's text, by
/// preference through pure AX attribute writes — no synthetic events, no
/// clipboard. Only when every AX path has declined *without changing anything*
/// does it consider `ClipboardCaseFallback`, which is off unless the user turns
/// it on.
///
/// A successful AX return code is NOT proof the edit happened: WebKit and
/// Chromium both report success for kAXSelectedText writes without editing
/// anything (verified 2026-07-14 against Safari and Chrome). So every path
/// below is verified by reading the value back, and unverified paths fall
/// through to the next:
///
///   A. kAXSelectedText replacement — native AppKit text views ONLY. Skipped
///      for web content (element exposes AXDOMIdentifier): every web engine
///      lies about it, and Outlook's editor can half-apply it — deleting the
///      selection without inserting the replacement (observed 2026-07-15)
///   B. AXReplaceRangeWithText      — range-targeted replace, NATIVE VIEWS ONLY
///      (like A). Web engines lie about it — Safari answers YES without editing,
///      Chromium answers NO — and Outlook's compose body actively corrupts,
///      inserting a paragraph break that splits the word (2026-09-27). Web
///      content is routed to C / the clipboard fallback instead.
///   C. whole-value kAXValue write  — WebKit and Chromium/Electron honor
///      value writes but flatten rich formatting; only used when the whole
///      value is a single attributed-string run, so flattening is a no-op
///
/// If a read-back ever shows the value changed to something OTHER than the
/// expected text (a half-applied write), the cascade aborts immediately —
/// continuing against stale offsets could corrupt the user's text.
///
/// (WebKit's AXSelectTextWithCriteria find-and-replace was also prototyped
/// and dropped: whether it replaces, selects, or no-ops depends unpredictably
/// on prior selection state and isolated-tree staleness.)
///
/// Only when no path verifies does it beep. "Nothing to transform" (caret not
/// in a word, no cased characters) stays silent.
enum CaseToggler {

    /// Set once at launch by the AppDelegate; called (on the main thread) at
    /// most once per browser per run when that browser's "Allow JavaScript
    /// from Apple Events" toggle is off, so the UI layer can explain the
    /// one-time setup. Keeps NSAlert out of this layer.
    static var onBrowserSetupHint: ((_ browserName: String) -> Void)?
    private static var hintedBrowsers = Set<String>()

    /// Upper bound, in UTF-16 units, on a field we are willing to rewrite whole
    /// (path C). Roughly a long email; beyond that the cost of the rewrite
    /// outweighs changing the case of one word.
    private static let maxWholeValueRewriteLength = 20_000

    /// Call on the main thread (dispatched from the event-tap handler).
    /// `originPID` is the process the keystroke was delivered to; every path
    /// that can post a synthetic event revalidates it first.
    static func cycleCase(originPID: pid_t) {
        // Web pages first, where possible: in-page JS edits through the
        // site's own editor pipeline (rich formatting survives, undo works),
        // which no AX path can do in web content. Failures fall through to
        // the AX cascade below.
        if BrowserCaseScript.supportsFrontmostBrowser() {
            switch BrowserCaseScript.runInFrontmostBrowser() {
            case .applied(let text):
                log("cycled case via in-page JS → \"\(text)\"")
                return
            case .nothingToDo:
                // NOT a return: the page's idea of "no word here" and the AX
                // layer's can differ (canvas editors, shadow DOM, a caret the
                // Selection API cannot see). The JS made no edit, so trying AX
                // afterwards cannot double-apply.
                log("in-page JS found nothing to transform — falling through to AX")
            case .jsDisabled(let browserName):
                log("in-page JS unavailable: \(browserName) has JavaScript from Apple Events turned off")
                if !hintedBrowsers.contains(browserName) {
                    hintedBrowsers.insert(browserName)
                    onBrowserSetupHint?(browserName)
                }
            case .unavailable(let reason):
                log("in-page JS unavailable: \(reason)")
            case .indeterminate(let reason):
                // The script may already have edited the page, or may do so
                // after we return. Falling through to AX or the clipboard
                // would compose two edits into an unpredictable result, so the
                // press stops here. No beep: the likeliest outcome is that the
                // page did apply it.
                log("in-page JS indeterminate (\(reason)) — ending this press rather than risking a double edit")
                return
            }
        }

        let element = AccessibilityHelper.focusedElement()

        // No readable AX text at all (terminals, Electron without an exposed
        // tree, canvas editors). Nothing can be planned here, but the clipboard
        // path needs no plan — it transforms whatever the user has selected.
        guard let element = element,
              let text = stringValue(of: element),
              let selection = selectedTextRange(of: element) else {
            switch ClipboardCaseFallback.attempt(
                element: element, edit: nil, originPID: originPID
            ) {
            case .applied, .nothingToDo:
                return
            case .unavailable(let reason):
                fail("no readable AX text here (\(reason))")
                return
            }
        }

        guard let edit = CaseCycle.plan(
            text: text,
            selectionLocation: selection.location,
            selectionLength: selection.length
        ) else {
            log("nothing to transform at caret — no-op")
            return
        }
        guard let expected = CaseCycle.apply(edit, to: text) else {
            log("edit does not fit the text — no-op")
            return
        }

        // Path A selects `edit.target` before writing, and restoring the
        // selection used to live inside `finish` — reachable only from the
        // three `.verified` arms below. So every failing path left the user's
        // caret replaced by a full-word selection, and the next character they
        // typed deleted the word (REVIEW.md 2026-07-28 F5). The restore is now
        // an obligation taken here and discharged on the way out, so a new
        // failure exit cannot forget it.
        //
        // `settled` is set by the paths that must NOT be tidied up after:
        // a verified edit (which restores its own caret via `finish`, and where
        // `selection` is stale by design), and a diverged write — there the
        // value is unknown and these offsets no longer describe it, so setting
        // a range from them is exactly the mutation the abort rule forbids.
        var settled = false
        var selectionMoved = false
        defer {
            if selectionMoved, !settled,
               !setSelectedRange(element, location: selection.location, length: selection.length) {
                log("WARNING: no edit applied and the selection could not be put back")
            }
        }

        var aborted = false
        if !isWebContent(element) {
            switch replaceViaSelectedText(element, edit: edit, original: text, expected: expected,
                                          didSelect: &selectionMoved) {
            case .verified:
                settled = true
                finish(element, edit: edit, path: "selected-text")
                return
            case .diverged:
                aborted = true
                settled = true
            case .unchanged, .skipped:
                break
            }
        } else {
            log("path A skipped: web content (kAXSelectedText writes lie or half-apply)")
        }
        // Path B is confined to native views, exactly like path A — and for the
        // same reason, now with a sharper edge. In web content AXReplaceRangeWithText
        // does not merely lie (Safari returns YES without editing, Chromium
        // returns NO): Outlook's compose body actively CORRUPTS. Measured
        // 2026-09-27, a ⇧F3 there answers the range replace by inserting a
        // paragraph break that splits the target word, and the read-back catches
        // the divergence only *after* the damage — so the cascade aborts, beeps,
        // and never reaches the clipboard fallback that is the only thing that
        // can serve Outlook. Skipping B in web content lets the cascade fall
        // through to path C / the clipboard fallback (verified working in Outlook
        // on 2026-09-27); C still covers the uniform-formatting web fields where a
        // whole-value write is clean, so nothing that worked before regresses.
        if !aborted && !isWebContent(element) {
            switch replaceViaRangeReplace(element, edit: edit, original: text, expected: expected) {
            case .verified:
                settled = true
                finish(element, edit: edit, path: "replace-range")
                return
            case .diverged:
                aborted = true
                settled = true
            case .unchanged, .skipped:
                break
            }
        } else if !aborted {
            log("path B skipped: web content (AXReplaceRangeWithText half-applies — corrupts Outlook's compose body)")
        }
        if !aborted {
            switch replaceViaWholeValue(element, original: text, expected: expected) {
            case .verified:
                settled = true
                finish(element, edit: edit, path: "whole-value")
                return
            case .diverged:
                aborted = true
                settled = true
            case .unchanged, .skipped:
                break
            }
        }
        if aborted {
            // Deliberately no clipboard attempt here: the text is already in an
            // unknown state and our offsets are stale. Stop.
            fail("ABORTED: a write half-applied (value diverged); not risking further edits")
            return
        }

        // Every AX path declined without changing anything, so the text is
        // exactly as we found it and the clipboard path can still try.
        switch ClipboardCaseFallback.attempt(
            element: element, edit: edit, originPID: originPID
        ) {
        case .applied:
            // It pasted, and re-selected the replacement itself; the offsets
            // this scope holds describe text that no longer exists.
            settled = true
            return
        case .nothingToDo:
            return
        case .unavailable(let reason):
            fail("no edit path verified in this app (\(reason))")
        }
    }

    /// Outcome of an edit-path attempt.
    private enum VerifyResult {
        /// The value now reads exactly as expected — edit confirmed.
        case verified
        /// Nothing changed — safe to try the next path.
        case unchanged
        /// The value changed to something OTHER than expected: a write
        /// half-applied. The cascade must stop; offsets are now stale.
        case diverged
        /// Preconditions failed before anything was written.
        case skipped
    }

    /// Web content detection lives in `AccessibilityHelper` — the menu hotkey
    /// needs the same answer to decide whether the contextual-menu key is safe
    /// to post, and two copies would be free to drift apart.
    private static func isWebContent(_ element: AXUIElement) -> Bool {
        AccessibilityHelper.isWebContent(element)
    }

    // MARK: - Edit paths (each verified by read-back before claiming success)

    /// Path A (native views only): select the target range, replace via
    /// kAXSelectedText.
    ///
    /// `didSelect` is set as soon as the selection write is attempted — not
    /// when it succeeds — because a rejected write can still have moved the
    /// selection, and the caller's obligation is to put it back either way.
    private static func replaceViaSelectedText(_ element: AXUIElement, edit: CaseCycle.Edit, original: String, expected: String, didSelect: inout Bool) -> VerifyResult {
        guard isSettable(element, kAXSelectedTextRangeAttribute),
              isSettable(element, kAXSelectedTextAttribute) else {
            log("path A skipped: selection or selected-text not settable")
            return .skipped
        }
        didSelect = true
        guard setSelectedRange(element, location: edit.target.location, length: edit.target.length) else {
            log("path A failed: could not select target range")
            return .skipped
        }
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, edit.replacement as CFTypeRef) == .success else {
            log("path A failed: selected-text write rejected")
            return .unchanged
        }
        return verifyValue(of: element, original: original, expected: expected, label: "A")
    }

    /// Path B: AppKit's parameterized bridge to accessibilityReplaceRange:
    /// withText: — a true range edit that preserves surrounding formatting
    /// where implemented. The returned boolean is untrusted: Safari returns
    /// YES without editing, so read-back decides. A definitive NO (Chromium)
    /// skips the verification wait.
    private static func replaceViaRangeReplace(_ element: AXUIElement, edit: CaseCycle.Edit, original: String, expected: String) -> VerifyResult {
        guard let rangeValue = AXValueCreate(.cfRange, [CFRange(location: edit.target.location, length: edit.target.length)]) else {
            return .skipped
        }
        let param = [
            "AXRange": rangeValue,
            "AXText": edit.replacement as CFTypeRef,
        ] as CFDictionary
        var out: CFTypeRef?
        let result = AXUIElementCopyParameterizedAttributeValue(
            element, "AXReplaceRangeWithText" as CFString, param, &out)
        guard result == .success else {
            log("path B skipped: AXReplaceRangeWithText error \(result.rawValue)")
            return .skipped
        }
        if let answer = out as? Int, answer == 0 {
            log("path B declined by app (returned NO)")
            return .unchanged
        }
        return verifyValue(of: element, original: original, expected: expected, label: "B")
    }

    /// Path C (WebKit/Chromium/Electron): replace the whole kAXValue. These
    /// engines honor value writes but plain-textify the content, so it is only
    /// safe when the current value already has uniform formatting (one
    /// attributed run).
    private static func replaceViaWholeValue(_ element: AXUIElement, original: String, expected: String) -> VerifyResult {
        guard isSettable(element, kAXValueAttribute) else {
            log("path C skipped: kAXValue not settable")
            return .skipped
        }
        // Rewriting the entire field to change one word is a blunt instrument:
        // it collapses the app's undo stack to a single enormous edit and can
        // reset scroll and caret state. Tolerable for a search box, not for a
        // long document — and the attributed-string probe below would have to
        // walk the whole thing first anyway.
        guard original.utf16.count <= maxWholeValueRewriteLength else {
            log("path C skipped: value is \(original.utf16.count) UTF-16 units, over the \(maxWholeValueRewriteLength) limit for a whole-value rewrite")
            return .skipped
        }
        // Re-read: an earlier path's write may have landed late. Divergence
        // from the original text means stale offsets — abort, don't write.
        guard let current = stringValue(of: element) else { return .skipped }
        if current == expected { return .verified }
        guard current == original else {
            log("path C aborted: value changed underneath us")
            return .diverged
        }
        guard hasUniformFormatting(element, utf16Length: current.utf16.count) else {
            log("path C skipped: mixed formatting — whole-value write would flatten it")
            return .skipped
        }
        guard AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, expected as CFTypeRef) == .success else {
            log("path C failed: kAXValue write rejected")
            return .unchanged
        }
        return verifyValue(of: element, original: original, expected: expected, label: "C")
    }

    /// Restore the caret/selection after a verified edit. Best effort: in
    /// Chromium the range write applies asynchronously and cannot be verified
    /// immediately; a failed restore never undoes the (verified) edit.
    private static func finish(_ element: AXUIElement, edit: CaseCycle.Edit, path: String) {
        if !setSelectedRange(element, location: edit.restored.location, length: edit.restored.length) {
            log("WARNING: edit applied via \(path) but selection restore failed")
        }
        log("cycled case via \(path) → \"\(edit.replacement)\"")
    }

    // MARK: - Verification

    /// Poll kAXValue until it equals `expected`. Native apps apply writes
    /// synchronously (first check hits); Chromium applies them on its next
    /// accessibility pass, hence the short deadline instead of one read.
    /// A value that is neither the original nor the expected text means a
    /// write half-applied — reported as .diverged so the cascade aborts.
    private static func verifyValue(of element: AXUIElement, original: String, expected: String, label: String) -> VerifyResult {
        let deadline = Date().addingTimeInterval(0.35)
        while true {
            let value = stringValue(of: element)
            if value == expected {
                return .verified
            }
            if let value = value, value != original {
                log("path \(label) DIVERGED: write half-applied (value is neither original nor expected)")
                return .diverged
            }
            guard Date() < deadline else {
                log("path \(label) not verified: value unchanged after write")
                return .unchanged
            }
            usleep(50_000)  // 50 ms
        }
    }

    /// True when the element's whole text renders as a single attributed run —
    /// i.e. replacing the plain value cannot destroy formatting. Conservative:
    /// any failure to fetch the attributed string counts as NOT uniform.
    private static func hasUniformFormatting(_ element: AXUIElement, utf16Length: Int) -> Bool {
        if utf16Length == 0 { return true }
        guard let rangeValue = AXValueCreate(.cfRange, [CFRange(location: 0, length: utf16Length)]) else { return false }
        var out: CFTypeRef?
        let result = AXUIElementCopyParameterizedAttributeValue(
            element, kAXAttributedStringForRangeParameterizedAttribute as CFString, rangeValue, &out)
        guard result == .success, let attributed = out as? NSAttributedString else { return false }
        var runs = 0
        attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { _, _, stop in
            runs += 1
            if runs > 1 { stop.pointee = true }
        }
        return runs <= 1
    }

    // MARK: - AX helpers

    private static func stringValue(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func selectedTextRange(of element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let axValue = value else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(axValue as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    private static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable = DarwinBoolean(false)
        let result = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        return result == .success && settable.boolValue
    }

    private static func setSelectedRange(_ element: AXUIElement, location: Int, length: Int) -> Bool {
        guard let value = AXValueCreate(.cfRange, [CFRange(location: location, length: length)]) else {
            return false
        }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }

    private static func fail(_ reason: String) {
        log("unavailable here: \(reason)")
        NSSound.beep()
    }

    /// NSLog via "%@" — see AccessibilityHelper.log. These messages quote the
    /// user's own text, so a literal format string would be a live grenade.
    private static func log(_ message: String) {
        NSLog("%@", "[Menu du Jour] CaseToggler: \(message)")
    }
}
