import Cocoa
import ApplicationServices
import MenuDuJourCore

/// Asks the frontmost app to open its own contextual menu by posting the
/// PC "Application/Menu" key (virtual keycode 110) directly to it.
///
/// ## Why this is the first thing we try
///
/// Everything else in this app is an attempt to answer "where is the caret, in
/// screen pixels?" so we can synthesize a right-click there. That question is
/// hard (text markers, selection-boundary probes, slide-coordinate mapping)
/// and in several apps we got it wrong or could not answer it at all.
///
/// Keycode 110 sidesteps the question entirely: AppKit routes it through
/// `NSApplication._handleContextMenuHotKey:` → `showContextMenuForSelection:`,
/// so the *app* places the menu from its own caret and selection state. That
/// is exactly what the Windows menu key does, and it is strictly better
/// information than any coordinate we can compute from outside.
///
/// Measured 2026-07-28 by posting keycode 110 and watching for a pop-up-layer
/// window:
///
///     TextEdit      AXTextArea     menu: YES   text unchanged
///     Word          AXTextArea     menu: YES   text unchanged
///     Outlook       AXTextArea     menu: YES   text unchanged
///     Excel         AXLayoutArea   menu: YES
///     Finder        AXOutline      menu: YES
///     Mail          AXTable        menu: YES
///     Chrome        AXTextArea     menu: no
///     Codex/ChatGPT AXTextArea     menu: no
///     Android Studio JavaAxIgnore  menu: no
///
/// The split is AppKit vs everything that draws its own UI, not arbitrary:
/// Chromium and Java/Swing both handle their own key events and never reach
/// AppKit's hotkey path. So this fixes the native world — including the three
/// cases that were broken (PowerPoint beeped; Finder and Word placed the menu
/// nowhere near the caret) — while those toolkits keep using the coordinate
/// click, which is the half that already worked better for them.
///
/// ## Why there is no allowlist and no version check
///
/// The result is verified at runtime: post, then look for a menu. An app that
/// does not implement it simply produces no menu and we fall through to the
/// coordinate path. That self-gates across OS versions and unknown apps, and
/// it is why this needs no per-app configuration to maintain.
///
/// ## Why it is safe to post
///
/// Unlike ⌃↩ — which apps bind to Send, Run Cell, and other irreversible
/// things — keycode 110 is a dedicated menu key that nothing else binds. It
/// also produces no character: the three apps above that expose their text to
/// AX were byte-identical afterwards. And it is delivered with `postToPid`, so
/// it reaches only the app the hotkey was pressed in and is invisible to other
/// event taps.
enum ContextMenuKey {

    /// The PC "Application" / "Menu" key. Apple shipped a physical Contextual
    /// Menu key on the 2024 USB-C Magic Keyboard; this is the same signal.
    private static let applicationKeyCode: CGKeyCode = 110

    /// How long to wait for the app to put its menu up before concluding it
    /// does not handle the key. Menus appear well inside this; the cost is
    /// only paid in apps that never respond (i.e. Chromium).
    private static let menuDeadline: TimeInterval = 0.3
    private static let pollInterval: TimeInterval = 0.02

    /// Which keystroke asks for the menu. See `AppBehaviorPolicy.MenuRequest`.
    typealias Request = AppBehaviorPolicy.MenuRequest

    /// Office's in-page menu has not been timed; give it more room than an
    /// NSMenu window, which appears well inside `menuDeadline`.
    private static let inPageMenuDeadline: TimeInterval = 0.6

    /// Post the request and report whether a menu actually appeared — either
    /// an NSMenu window, or keyboard focus moving onto an in-page menu. The
    /// second matters: without it a web app's own menu counted as "no menu",
    /// and the fallback click then landed on top of it.
    /// Runs on the main queue; never blocks.
    static func attempt(originPID: pid_t, request: Request = .contextMenuKey,
                        completion: @escaping (Bool) -> Void) {
        let name = request == .shiftF10 ? "Shift+F10" : "contextual-menu key"
        guard OriginatingApp.stillFrontmost(originPID, before: "the \(name)") else {
            completion(false)
            return
        }
        guard post(request, to: originPID) else {
            completion(false)
            return
        }

        let deadline = Date().addingTimeInterval(request == .shiftF10 ? inPageMenuDeadline : menuDeadline)
        func poll() {
            if MenuDetection.popUpMenuWindowExists(for: originPID) {
                NSLog("%@", "[Menu du Jour] \(name) opened the app's own menu")
                completion(true)
                return
            }
            if MenuDetection.inPageMenuHasFocus(for: originPID) {
                NSLog("%@", "[Menu du Jour] \(name) opened an in-page menu")
                completion(true)
                return
            }
            guard Date() < deadline else {
                NSLog("%@", "[Menu du Jour] \(name) produced no menu")
                completion(false)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval, execute: poll)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval, execute: poll)
    }

    /// Deliver the key to one process only. Returns false if the events could
    /// not be created.
    /// F10's virtual keycode (kVK_F10), the same whether or not the keyboard's
    /// top row is set to media keys.
    private static let f10KeyCode: CGKeyCode = 0x6D

    @discardableResult
    static func post(_ request: Request = .contextMenuKey, to pid: pid_t) -> Bool {
        let keyCode = request == .shiftF10 ? f10KeyCode : applicationKeyCode
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
        else { return false }
        // Set modifiers exactly: the hotkey's own modifier (e.g. ⌥ of ⌥/) is
        // usually still physically held, and ⌥-menu-key or ⌥⇧F10 is not the
        // signal we mean.
        let flags: CGEventFlags = request == .shiftF10 ? .maskShift : []
        down.flags = flags
        up.flags = flags
        down.postToPid(pid)
        up.postToPid(pid)
        return true
    }
}
