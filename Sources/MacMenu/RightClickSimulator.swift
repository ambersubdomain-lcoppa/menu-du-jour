import Cocoa
import Carbon.HIToolbox
import ApplicationServices
import MenuDuJourCore

enum RightClickSimulator {

    /// Watches for a context menu to appear after we tried to open one.
    ///
    /// Calls back with the detected state, or `nil` if the deadline passed with
    /// no menu at all. Runs on the main queue; never blocks.
    private static func awaitMenu(maxWait: TimeInterval = 0.3,
                                  pollInterval: TimeInterval = 0.02,
                                  completion: @escaping (MenuDetection.MenuState?) -> Void) {
        let start = Date()
        let deadline = start.addingTimeInterval(maxWait)

        func poll() {
            let state = MenuDetection.currentState()
            let action = MenuPollPolicy.action(menuOpen: state.menuOpen,
                                               menuItemFocused: state.itemFocused,
                                               deadlineReached: Date() >= deadline)
            switch action {
            case .highlightFirstItem, .stop:
                completion(state.menuOpen ? state : nil)
            case .keepPolling:
                DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval, execute: poll)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval, execute: poll)
    }

    /// After opening a context menu, highlight its first item so the user can
    /// immediately hit Return or arrow further without reaching for the mouse.
    /// Posts arrow-down only when a menu is positively detected AND no menu
    /// item is already focused; if the app doesn't expose the menu, posts
    /// nothing — a blind arrow-down can move a Finder selection, spreadsheet
    /// cell, or autocomplete choice (REVIEW.md F4).
    private static func selectFirstMenuItem(originPID: pid_t) {
        let start = Date()
        let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"

        awaitMenu { state in
            let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
            guard OriginatingApp.stillFrontmost(
                originPID, before: "arrow-down into the menu") else { return }
            guard let state = state, !state.itemFocused else {
                let reason = state?.itemFocused == true
                    ? "menu item already focused"
                    : "no menu detected"
                NSLog("[Menu du Jour] [%@] %@ after %dms — not posting arrow-down",
                      appName, reason, elapsedMs)
                return
            }
            NSLog("[Menu du Jour] [%@] menu detected after %dms — posting arrow-down",
                  appName, elapsedMs)
            postArrowDown()
        }
    }

    private static func postArrowDown() {
        let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_DownArrow), keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_DownArrow), keyDown: false)
        // Clear inherited modifiers: the hotkey's own modifier (e.g. ⌥ of ⌥M)
        // is often still physically held this soon after detection, and ⌥↓ in a
        // menu jumps to the LAST item instead of the first.
        keyDown?.flags = []
        keyUp?.flags = []
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    /// The imprecise fallback: ask the app to open its own menu (REVIEW.md F1,
    /// narrowed scope — the precise caret/row paths stay click-first per
    /// CLAUDE.md plan of record), and right-click the element's centre if that
    /// does not actually produce a menu.
    ///
    /// `AXUIElementPerformAction` returning `.success` only means the action was
    /// accepted; several apps accept it and show nothing. Treating "accepted"
    /// as "opened" left the hotkey silently dead in those apps, so the result is
    /// now confirmed against `MenuDetection` before the click is skipped.
    static func showContextMenuForImpreciseTarget(
        _ element: AXUIElement,
        fallbackPoint: CGPoint,
        originPID: pid_t
    ) {
        let walk = AXMenuAction.performShowMenu(startingAt: element)
        guard walk.succeeded else {
            NSLog("[Menu du Jour] kAXShowMenuAction refused at every level — right-clicking instead")
            rightClick(at: fallbackPoint, originPID: originPID)
            return
        }

        awaitMenu { state in
            guard let state = state else {
                // Up to 300ms have passed. The click below is aimed at a
                // coordinate that only means anything in the app the key was
                // pressed in.
                guard OriginatingApp.stillFrontmost(
                    originPID, before: "fallback right-click") else { return }
                NSLog("[Menu du Jour] kAXShowMenuAction was accepted but no menu appeared — right-clicking instead")
                rightClick(at: fallbackPoint, originPID: originPID)
                return
            }
            if !state.itemFocused {
                guard OriginatingApp.stillFrontmost(
                    originPID, before: "arrow-down into the menu") else { return }
                postArrowDown()
            }
        }
    }

    /// Simulates a right-click (context menu click) at the given screen coordinates,
    /// then moves the mouse cursor back to where it was before.
    static func rightClick(at point: CGPoint, originPID: pid_t) {
        click(at: point, button: .right, originPID: originPID)
    }

    /// A left-click at the caret, for editors that open their spelling menu on
    /// a left click (Outlook's compose body — `AppBehaviorPolicy.caretClickButton`).
    /// The caret point is the trailing edge of the character before the caret,
    /// i.e. exactly on a boundary, and a hit test there can resolve to the NEXT
    /// character — past the end of a just-typed word. One point to the left
    /// lands inside the word, and the caret still snaps to the same boundary.
    static func leftClick(atCaret point: CGPoint, originPID: pid_t) {
        click(at: CGPoint(x: point.x - 1, y: point.y), button: .left, originPID: originPID)
    }

    private static func click(at point: CGPoint, button: CGMouseButton, originPID: pid_t) {
        let name = button == .left ? "left-click" : "right-click"
        guard OriginatingApp.stillFrontmost(originPID, before: "\(name) at \(point)") else {
            return
        }

        // Save current mouse position
        let originalPosition = CGEvent(source: nil)?.location ?? point

        let mouseDown = CGEvent(
            mouseEventSource: nil,
            mouseType: button == .left ? .leftMouseDown : .rightMouseDown,
            mouseCursorPosition: point,
            mouseButton: button
        )
        let mouseUp = CGEvent(
            mouseEventSource: nil,
            mouseType: button == .left ? .leftMouseUp : .rightMouseUp,
            mouseCursorPosition: point,
            mouseButton: button
        )

        // Set click count — some apps check this field
        mouseDown?.setIntegerValueField(.mouseEventClickState, value: 1)
        mouseUp?.setIntegerValueField(.mouseEventClickState, value: 1)

        // Clear inherited modifiers — the hotkey's modifier is often still
        // physically held, and e.g. an Option-right-click in Finder shows
        // alternate menu items (a Shift-left-click would extend the selection).
        mouseDown?.flags = []
        mouseUp?.flags = []

        mouseDown?.post(tap: .cghidEventTap)
        mouseUp?.post(tap: .cghidEventTap)

        // Restore the mouse cursor after a short delay — moving back immediately
        // can interfere if the app shows a context menu on mouseDown
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            let moveBack = CGEvent(
                mouseEventSource: nil,
                mouseType: .mouseMoved,
                mouseCursorPosition: originalPosition,
                mouseButton: .left
            )
            moveBack?.post(tap: .cghidEventTap)
        }

        selectFirstMenuItem(originPID: originPID)
    }
}
