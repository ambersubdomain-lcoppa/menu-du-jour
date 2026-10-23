import Cocoa
import Carbon.HIToolbox
import ApplicationServices

/// Opt-in diagnostic probe. When "Diagnostic Mode" is enabled in the menu,
/// pressing the hotkey runs this against the currently-focused app instead of
/// opening a context menu. It reports which context-menu strategies are
/// available/working so we can decide how to reorder the real flow.
///
/// Four strategies are evaluated:
///   1. kAXShowMenuAction — ask the app to open its own context menu at its caret
///   2. AX caret bounds    — can we resolve a precise caret pixel position?
///   3. Shift+F10          — does a synthetic menu-key keystroke open a menu?
///   4. Control+Return     — macOS 15's own contextual-menu keystroke
/// plus, for comparison, a raw right-click at the AX caret point.
///
/// Output goes to NSLog (Console.app), stdout (`swift run`), and the clipboard.
enum AXDiagnostics {

    private static var buffer = ""

    /// True while a probe chain is in flight. All access is on the main queue.
    private static var isRunning = false

    /// Run the full diagnostic against the frontmost app. Passive inspection is
    /// synchronous; the active menu-opening probes run sequentially on the main
    /// queue with short delays and dismiss each menu with Escape.
    static func run() {
        // The probe chain is async; a second hotkey press mid-run would
        // interleave two chains and corrupt the report. Drop re-entrant calls.
        guard !isRunning else {
            NSLog("[Menu du Jour][diag] run already in progress — ignoring")
            return
        }
        isRunning = true
        buffer = ""

        let app = NSWorkspace.shared.frontmostApplication
        let appName = app?.localizedName ?? "unknown"
        let bundleID = app?.bundleIdentifier ?? "unknown"
        let pid = app?.processIdentifier ?? -1

        line("========== Menu du Jour diagnostics ==========")
        line("App:       \(appName)")
        line("Bundle ID: \(bundleID)")
        line("PID:       \(pid)")

        // --- Focused element (system-wide vs app-scoped) ---
        let systemWide = AXUIElementCreateSystemWide()
        let sysFocused = focusedElement(of: systemWide)
        line("")
        line("Focused element (system-wide): role=\(role(sysFocused) ?? "nil") subrole=\(subrole(sysFocused) ?? "nil")")

        if pid > 0 {
            let appElement = AXUIElementCreateApplication(pid)
            let appFocused = focusedElement(of: appElement)
            line("Focused element (app-scoped):  role=\(role(appFocused) ?? "nil") subrole=\(subrole(appFocused) ?? "nil")")
        }

        guard let focused = sysFocused else {
            line("")
            line("No focused element via AX — cannot probe. (App likely doesn't expose AX, e.g. some browsers.)")
            finish()
            return
        }

        // --- Strategy 1 (advertised): AX actions on the focused element ---
        let actions = actionNames(focused)
        line("")
        line("AX actions advertised on focused element:")
        if actions.isEmpty {
            line("  (none)")
        } else {
            for a in actions { line("  - \(a)") }
        }
        let advertisesShowMenu = actions.contains(kAXShowMenuAction as String)
        line("kAXShowMenuAction advertised: \(advertisesShowMenu ? "YES" : "no")")

        // --- Strategy 2: AX caret bounds ---
        line("")
        let caret = AccessibilityHelper.caretPosition()
        let caretPoint: CGPoint?
        // The element the kAXShowMenuAction probe should start from: the
        // resolved selected row/child when there is one — walking ancestors
        // from the container can never reach the row, a descendant
        // (REVIEW.md F5 verification).
        var showMenuTarget = focused
        switch caret {
        case .caret(let p):
            line("AX caret bounds: RESOLVED (precise caret) → \(fmt(p))")
            caretPoint = p
        case .selectedChild(let p, let child):
            line("AX caret bounds: resolved via selected child (list/table) → \(fmt(p))")
            line("(kAXShowMenuAction probe will start at the selected child)")
            caretPoint = p
            showMenuTarget = child
        case .centerOfElement(let p, _):
            line("AX caret bounds: FELL BACK to element center (imprecise) → \(fmt(p))")
            caretPoint = p
        case nil:
            line("AX caret bounds: FAILED (no position at all)")
            caretPoint = nil
        }

        line("")
        line("--- Active probes (each opens then Escapes a menu) ---")
        line("(note: 'menu opened' is detected via AX; some apps hide the menu")
        line(" from AX, so a 'no' here can be a false negative.)")

        runActiveProbes(focused: showMenuTarget, caretPoint: caretPoint)
    }

    // MARK: - Active probes

    private struct Probe {
        let name: String
        let canRun: Bool
        let trigger: () -> Void
        /// Optional cursor position to restore after the probe (right-click only).
        let restoreCursor: CGPoint?
    }

    private static func runActiveProbes(focused: AXUIElement, caretPoint: CGPoint?) {
        let savedCursor = CGEvent(source: nil)?.location

        let probes: [Probe] = [
            Probe(
                name: "kAXShowMenuAction",
                canRun: true,
                trigger: {
                    // Per-level AXError is the decisive datum: actionUnsupported
                    // on the leaf with success on an ancestor row/table means
                    // the semantic path works — probing only the leaf gave
                    // false negatives (REVIEW.md F5).
                    let walk = AXMenuAction.performShowMenu(startingAt: focused)
                    for (depth, attempt) in walk.attempts.enumerated() {
                        line("[kAXShowMenuAction] depth \(depth) role=\(attempt.role) → \(axErrorName(attempt.error))")
                    }
                },
                restoreCursor: nil
            ),
            // The production first strategy: the app places its own menu.
            Probe(
                name: "Contextual-menu key (110), postToPid",
                canRun: NSWorkspace.shared.frontmostApplication != nil,
                trigger: {
                    if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
                        ContextMenuKey.post(to: pid)
                    }
                },
                restoreCursor: nil
            ),
            Probe(
                name: "Shift+F10",
                canRun: true,
                trigger: { pressKey(CGKeyCode(kVK_F10), flags: .maskShift) },
                restoreCursor: nil
            ),
            // macOS 15 gave AppKit a native "show contextual menu for the
            // current selection" keystroke, which is the closest thing the
            // platform has to Windows' menu key: the app places the menu from
            // its own caret state instead of from a coordinate we guessed.
            // Measured here rather than shipped — Shift+F10 also looked
            // promising on paper and opened a menu in no context at all
            // (2026-07-14). Promote it to the production fallback only on
            // evidence from these reports.
            Probe(
                name: "Control+Return (macOS 15 native)",
                canRun: ProcessInfo.processInfo.isOperatingSystemAtLeast(
                    OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)),
                trigger: { pressKey(CGKeyCode(kVK_Return), flags: .maskControl) },
                restoreCursor: nil
            ),
            Probe(
                name: "Right-click at AX caret point",
                canRun: caretPoint != nil,
                trigger: { if let p = caretPoint { rawRightClick(at: p) } },
                restoreCursor: caretPoint != nil ? savedCursor : nil
            ),
        ]

        runProbe(probes, index: 0)
    }

    /// Runs probes one at a time: trigger → poll for a menu → record → Escape → next.
    private static func runProbe(_ probes: [Probe], index: Int) {
        guard index < probes.count else {
            finish()
            return
        }
        let probe = probes[index]

        guard probe.canRun else {
            line("[\(probe.name)] SKIPPED (prerequisite unavailable)")
            runProbe(probes, index: index + 1)
            return
        }

        // Dismiss a stale menu before triggering — but never post Escape
        // blindly: with no menu open it would cancel sheets/popups/drafts in
        // the focused app. (Cost: an AX-invisible menu can't be dismissed, so
        // later probes may be tainted; the report already warns about AX
        // false negatives.)
        if isContextMenuOpen() {
            pressKey(CGKeyCode(kVK_Escape))
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            probe.trigger()
            pollForMenu(deadline: Date().addingTimeInterval(0.4)) { opened in
                line("[\(probe.name)] menu opened: \(opened ? "YES" : "no")")
                if !opened {
                    dumpMenuHuntSnapshot()
                }
                // Diagnostic-only exception to the no-blind-Escape rule: we
                // just actively tried to open a menu, and detection itself is
                // what's under investigation — an un-dismissed menu taints
                // every later probe (2026-07-13 reports: probes fired into
                // each other's still-open menus). The user opted into
                // diagnostics; reset state unconditionally.
                line("[\(probe.name)] posting Escape to reset (unconditional in diagnostics)")
                pressKey(CGKeyCode(kVK_Escape))
                if let restore = probe.restoreCursor {
                    let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                       mouseCursorPosition: restore, mouseButton: .left)
                    move?.post(tap: .cghidEventTap)
                }
                // Gap before the next probe so the menu fully closes.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    runProbe(probes, index: index + 1)
                }
            }
        }
    }

    private static func pollForMenu(deadline: Date, completion: @escaping (Bool) -> Void) {
        if isContextMenuOpen() {
            completion(true)
            return
        }
        guard Date() < deadline else {
            completion(false)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            pollForMenu(deadline: deadline, completion: completion)
        }
    }

    private static func finish() {
        line("==============================================")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(buffer, forType: .string)
        appendToLogFile()
        line("(report copied to clipboard and appended to ~/Library/Logs/Menu du Jour/diagnostics.log)")
        isRunning = false
    }

    /// Appends the finished report to a persistent log file — the clipboard is
    /// one-paste and the unified log has limited retention.
    private static func appendToLogFile() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Menu du Jour", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("diagnostics.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let data = ("\n[\(stamp)]\n" + buffer).data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: file)
        }
    }

    /// When a probe's menu poll comes up empty, dump where a menu MIGHT be
    /// hiding: the app element's direct children (with one level of their
    /// children), plus the system-wide focused element. Evidence for fixing
    /// menu detection — the 2026-07-13 smoke test showed detection reporting
    /// 'no' for visibly open menus in every app tested.
    private static func dumpMenuHuntSnapshot() {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            line("  [snapshot] no frontmost app")
            return
        }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let children = (attribute(appElement, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        line("  [snapshot] app children (\(children.count)):")
        for (i, child) in children.enumerated() {
            let grandchildren = (attribute(child, kAXChildrenAttribute) as? [AXUIElement]) ?? []
            let inner = grandchildren.prefix(8)
                .map { "\(role($0) ?? "nil")/\(subrole($0) ?? "-")" }
                .joined(separator: ", ")
            let overflow = grandchildren.count > 8 ? " +\(grandchildren.count - 8) more" : ""
            line("  [snapshot]   [\(i)] \(role(child) ?? "nil")/\(subrole(child) ?? "-") children: [\(inner)]\(overflow)")
        }
        let systemWide = AXUIElementCreateSystemWide()
        if let focused = focusedElement(of: systemWide) {
            line("  [snapshot] system-wide focused: \(role(focused) ?? "nil")/\(subrole(focused) ?? "-")")
        } else {
            line("  [snapshot] system-wide focused: nil")
        }

        // Menus never showed up in the AX tree (2026-07-13), but they are real
        // windows — list every elevated on-screen window so the report shows
        // the menu window directly.
        let popUpLevel = CGWindowLevelForKey(.popUpMenuWindow)
        if let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
            as? [[String: Any]] {
            let elevated = info.filter { (($0[kCGWindowLayer as String] as? CGWindowLevel) ?? 0) != 0 }
            line("  [snapshot] elevated windows (layer != 0): \(elevated.count)")
            for entry in elevated.prefix(10) {
                let layer = entry[kCGWindowLayer as String] as? CGWindowLevel ?? -1
                let pid = entry[kCGWindowOwnerPID as String] as? pid_t ?? -1
                let owner = entry[kCGWindowOwnerName as String] as? String ?? "?"
                let marker = layer == popUpLevel ? "  ← pop-up menu level" : ""
                line("  [snapshot]   layer=\(layer) pid=\(pid) owner=\(owner)\(marker)")
            }
        }
    }

    // MARK: - AX helpers

    private static func axErrorName(_ error: AXError) -> String {
        switch error {
        case .success:              return "success"
        case .actionUnsupported:    return "actionUnsupported"
        case .attributeUnsupported: return "attributeUnsupported"
        case .apiDisabled:          return "apiDisabled"
        case .cannotComplete:       return "cannotComplete"
        case .notImplemented:       return "notImplemented"
        case .invalidUIElement:     return "invalidUIElement"
        case .failure:              return "failure"
        default:                    return "AXError(\(error.rawValue))"
        }
    }

    private static func focusedElement(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let v = value else { return nil }
        return (v as! AXUIElement)
    }

    private static func role(_ element: AXUIElement?) -> String? {
        guard let element = element else { return nil }
        return attribute(element, kAXRoleAttribute) as? String
    }

    private static func subrole(_ element: AXUIElement?) -> String? {
        guard let element = element else { return nil }
        return attribute(element, kAXSubroleAttribute) as? String
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func actionNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success,
              let array = names as? [String] else { return [] }
        return array
    }

    /// Shared with production so the diagnostic exercises the real detection.
    private static func isContextMenuOpen() -> Bool {
        MenuDetection.currentState().menuOpen
    }

    // MARK: - Event helpers

    private static func pressKey(_ keyCode: CGKeyCode, flags: CGEventFlags = []) {
        let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private static func rawRightClick(at point: CGPoint) {
        let down = CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown,
                           mouseCursorPosition: point, mouseButton: .right)
        let up = CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp,
                         mouseCursorPosition: point, mouseButton: .right)
        down?.setIntegerValueField(.mouseEventClickState, value: 1)
        up?.setIntegerValueField(.mouseEventClickState, value: 1)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    // MARK: - Output

    private static func fmt(_ p: CGPoint) -> String {
        String(format: "(%.0f, %.0f)", p.x, p.y)
    }

    private static func line(_ text: String) {
        buffer += text + "\n"
        NSLog("[Menu du Jour][diag] %@", text)
        print("[Menu du Jour][diag] \(text)")
    }
}
