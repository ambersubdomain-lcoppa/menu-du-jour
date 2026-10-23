import Cocoa

/// Runs the case-cycle as JavaScript inside the frontmost browser tab via
/// Apple Events. In-page JS edits through the site's own editor pipeline
/// (document.execCommand("insertText")), so rich formatting survives and
/// undo works — everything the AX layer cannot do in web content.
///
/// The injected script mirrors MenuDuJourCore.CaseCycle (the Swift tests are
/// the reference spec): upper → lower, lower → Title, Title → UPPER,
/// mixed → lower; a single capital letter counts as upper.
enum BrowserCaseScript {

    enum Outcome {
        /// The page applied the edit; payload is the transformed text.
        case applied(String)
        /// The page has a caret but nothing to transform there. Distinct from
        /// `unavailable`: the caller may still try AX, but must not treat this
        /// as an error.
        case nothingToDo
        /// The browser's "Allow JavaScript from Apple Events" toggle is off.
        case jsDisabled(browserName: String)
        /// Any other failure (automation denied, no window, JS error…). The
        /// script definitely did not run, so the caller may try another path.
        case unavailable(String)
        /// The script was abandoned mid-flight and may or may not have edited
        /// the page. Nothing may follow it — see `runInFrontmostBrowser`.
        case indeterminate(String)
    }

    private enum Flavor {
        case chromium, safari
    }

    /// Browsers that can execute JS via Apple Events. Firefox cannot.
    private static let browsers: [String: Flavor] = [
        "com.google.Chrome": .chromium,
        "com.google.Chrome.canary": .chromium,
        "com.brave.Browser": .chromium,
        "com.microsoft.edgemac": .chromium,
        "com.vivaldi.Vivaldi": .chromium,
        "com.operasoftware.Opera": .chromium,
        "com.apple.Safari": .safari,
    ]

    /// The in-page case cycle. Returns a status string the app can trust:
    /// "ok:<text>", "no-selection", "no-word", or "failed". Written without
    /// line comments so it can be flattened to one line for AppleScript.
    ///
    /// Four things this has to get right that the obvious version does not:
    ///
    ///   * "Word" must mean what `MenuDuJourCore.CaseCycle` means by it, or the
    ///     hotkey behaves differently in a browser field than everywhere else.
    ///     An apostrophe counts as part of a word only when flanked by letters
    ///     on both sides — "dell'acqua" is one word, "boys'" is not (REVIEW.md
    ///     2026-07-28 F4). Both the `WORD` regex and the caret expansion use
    ///     that rule; `macmenu_scripts/check-browser-tokenizer.js` runs this
    ///     literal against the Core tests' cases, since `swift test` cannot.
    ///
    ///   * `window.getSelection()` does NOT report the selection inside
    ///     `<input>` and `<textarea>`. Those need selectionStart/selectionEnd.
    ///     Worse, acting on the document selection while a form field has focus
    ///     reads a word from the page and writes it into the field, so form
    ///     fields must be detected FIRST, never fallen back to.
    ///   * The editor is very often inside an iframe (Outlook web, CKEditor,
    ///     TinyMCE). Walk activeElement down through same-origin frames.
    ///   * If the edit does not apply, put the selection back the way it was:
    ///     the caller falls through to the AX cascade, which reads the
    ///     selection we would otherwise have moved.
    private static let javascript = """
    (function () {
      var WORD = /[\\p{L}\\p{N}]*\\p{L}(?:['\\u2019]\\p{L}[\\p{L}\\p{N}]*)+|[\\p{L}\\p{N}]+/gu;
      function deepActive(doc) {
        var el = doc.activeElement;
        while (el && (el.tagName === "IFRAME" || el.tagName === "FRAME")) {
          var inner = null;
          try { inner = el.contentDocument; } catch (e) { inner = null; }
          if (!inner || !inner.activeElement) {
            return { doc: doc, el: el, blocked: true };
          }
          doc = inner;
          el = inner.activeElement;
        }
        return { doc: doc, el: el, blocked: false };
      }
      function titleCase(s) {
        return s.toLowerCase().replace(WORD, function (w) {
          return w.charAt(0).toUpperCase() + w.slice(1);
        });
      }
      function nextCase(word) {
        if (word === word.toUpperCase()) return word.toLowerCase();
        if (word === word.toLowerCase()) return titleCase(word);
        if (word === titleCase(word)) return word.toUpperCase();
        return word.toLowerCase();
      }
      var cased = /[\\p{Lu}\\p{Ll}]/u;
      var wordChar = /[\\p{L}\\p{N}]/u;
      var letter = /\\p{L}/u;
      function joinsWord(s, i) {
        var c = s.charAt(i);
        if (c !== "'" && c !== "\\u2019") return false;
        return letter.test(s.charAt(i - 1)) && letter.test(s.charAt(i + 1));
      }
      var target = deepActive(document);
      if (target.blocked) return "blocked-frame";
      var el = target.el;
      var tag = el ? el.tagName : "";
      var isField = (tag === "INPUT" || tag === "TEXTAREA")
        && typeof el.selectionStart === "number";

      if (isField) {
        var value = el.value;
        var from = el.selectionStart;
        var to = el.selectionEnd;
        if (from === to) {
          while (from > 0) {
            if (wordChar.test(value.charAt(from - 1))) { from--; continue; }
            if (joinsWord(value, from - 1)) { from -= 2; continue; }
            break;
          }
          while (to < value.length) {
            if (wordChar.test(value.charAt(to))) { to++; continue; }
            if (joinsWord(value, to)) { to += 2; continue; }
            break;
          }
        }
        if (from === to) return "no-word";
        var fieldWord = value.slice(from, to);
        if (!cased.test(fieldWord)) return "no-word";
        var fieldNext = nextCase(fieldWord);
        el.setSelectionRange(from, to);
        var fieldOk = false;
        try { fieldOk = target.doc.execCommand("insertText", false, fieldNext); } catch (e) { fieldOk = false; }
        if (!fieldOk) {
          el.value = value.slice(0, from) + fieldNext + value.slice(to);
          el.dispatchEvent(new Event("input", { bubbles: true }));
          el.dispatchEvent(new Event("change", { bubbles: true }));
        }
        el.setSelectionRange(from, from + fieldNext.length);
        return "ok:" + fieldNext;
      }

      var sel = target.doc.getSelection();
      if (!sel || sel.rangeCount === 0) return "no-selection";
      var original = sel.getRangeAt(0).cloneRange();
      var hadCaret = sel.isCollapsed;
      if (hadCaret) {
        sel.modify("move", "backward", "word");
        sel.modify("extend", "forward", "word");
      }
      var word = sel.toString();
      function restore() {
        sel.removeAllRanges();
        sel.addRange(original);
      }
      if (!cased.test(word)) {
        restore();
        return "no-word";
      }
      var next = nextCase(word);
      var ok = false;
      try { ok = target.doc.execCommand("insertText", false, next); } catch (e) { ok = false; }
      if (!ok) {
        restore();
        return "failed";
      }
      return "ok:" + next;
    })();
    """

    /// True when the frontmost app is a browser we can script AND the caret is
    /// actually in page content. Without the second half, ⇧F3 in the address
    /// bar, a bookmark sheet or devtools would run the script against whatever
    /// the page happens to have selected.
    static func supportsFrontmostBrowser() -> Bool {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              browsers[bundleID] != nil else { return false }
        return isWebContentFocused()
    }

    /// Web engines expose DOM bookkeeping attributes that the browser's own
    /// AppKit chrome (omnibox, find bar, sheets) does not.
    private static func isWebContentFocused() -> Bool {
        guard let element = AccessibilityHelper.focusedElement() else { return false }
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success,
              let list = names as? [String] else { return false }
        return list.contains("AXDOMIdentifier")
    }

    /// Execute the case-cycle JS in the frontmost browser's active tab.
    static func runInFrontmostBrowser() -> Outcome {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier,
              let flavor = browsers[bundleID] else {
            return .unavailable("frontmost app is not a supported browser")
        }
        let browserName = app.localizedName ?? bundleID

        // Never let a TCC consent dialog park the caller (see AppleScriptRunner).
        switch AppleScriptRunner.permission(forBundleID: bundleID) {
        case .granted:
            break
        case .undetermined:
            AppleScriptRunner.requestPermissionInBackground(forBundleID: bundleID)
            return .unavailable("awaiting Automation permission for \(browserName)")
        case .denied:
            return .unavailable("Automation permission denied for \(browserName)")
        }

        let js = appleScriptStringLiteral(javascript)
        let source: String
        switch flavor {
        case .chromium:
            source = "tell application id \"\(bundleID)\" to execute active tab of front window javascript \(js)"
        case .safari:
            source = "tell application id \"\(bundleID)\" to do JavaScript \(js) in front document"
        }

        // A page can be arbitrarily busy; past this the AX cascade is a better
        // use of the user's time than waiting.
        let outcome = AppleScriptRunner.run(timeout: 2.0) {
            NSAppleScript(source: source)
        }

        let result: NSAppleEventDescriptor
        switch outcome {
        case .timedOut:
            // The deadline protects the caller's latency; it does not stop the
            // script. This one mutates the page, so it may already have cycled
            // the word, or may do so after we return. Anything we tried next
            // would compose with it — an unpredictable double transform. The
            // press ends here.
            return .indeterminate("\(browserName) did not answer within the deadline")
        case .busy:
            // Our script never started, so nothing was mutated.
            return .unavailable("another Apple Event is still running")
        case .completed(let descriptor, let errorNumber, let errorMessage):
            if errorNumber != 0 {
                let message = errorMessage ?? "unknown AppleScript error"
                // Chrome: "Executing JavaScript through AppleScript is turned
                // off…"; Safari uses similar wording. Automation-denied is
                // -1743 (errAEEventNotPermitted) — handled above, but a race
                // is still possible.
                if errorNumber != -1743, message.lowercased().contains("javascript") {
                    return .jsDisabled(browserName: browserName)
                }
                return .unavailable("AppleScript error \(errorNumber): \(message)")
            }
            guard let descriptor else {
                return .unavailable("page returned no result")
            }
            result = descriptor
        }

        guard let status = result.stringValue else {
            return .unavailable("page returned no status")
        }
        if status.hasPrefix("ok:") {
            return .applied(String(status.dropFirst(3)))
        }
        if status == "no-selection" || status == "no-word" {
            return .nothingToDo
        }
        if status == "blocked-frame" {
            // The caret is in a cross-origin frame we cannot reach. The parent
            // document's selection is a different, unrelated thing — reading
            // or replacing it would edit text the user is not looking at.
            return .unavailable("caret is inside a cross-origin frame")
        }
        return .unavailable("page reported: \(status)")
    }

    /// Escape a Swift string into an AppleScript double-quoted literal.
    /// Newlines are flattened to spaces — AppleScript string literals do not
    /// reliably accept embedded line breaks, and the JS above is written
    /// without line comments so flattening is safe.
    private static func appleScriptStringLiteral(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        return "\"\(escaped)\""
    }
}
