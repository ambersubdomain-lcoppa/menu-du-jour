import Cocoa

/// The app a hotkey press belongs to, and the check that we are still talking
/// to it.
///
/// Every operation in this app starts with a keystroke and finishes some
/// milliseconds — sometimes the better part of a second — later: AX probes
/// poll, Apple Events have deadlines, menu detection waits, the clipboard path
/// waits twice. In between, the user can switch apps. Anything we then post is
/// aimed at whatever is frontmost *now*, which is never what they asked for:
/// a right-click opens a menu in the wrong app, a ⌘V pastes into it.
///
/// This was implicitly safe only while the event tap shared the main run loop,
/// because a blocked main thread also blocked the callback. Once the tap moved
/// to its own thread that coupling was gone, so the identity is now explicit:
/// the tap records the PID the key was delivered to (`kCGEventTargetUnixProcessID`,
/// captured atomically with the event) and every later step re-checks it.
///
/// Rule: no AX query and no synthetic event unless `isStillFrontmost` holds.
enum OriginatingApp {

    /// True when `pid` is still the frontmost application.
    ///
    /// A non-positive PID means the window server did not tell us who the key
    /// was for; rather than guess, we allow the operation — this matches the
    /// behaviour before the check existed and keeps the hotkey working if the
    /// field is ever unavailable.
    static func isStillFrontmost(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return true }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    /// `isStillFrontmost`, with a log line naming what was abandoned. Use at
    /// each point where a synthetic event or a mutating AX write would follow.
    static func stillFrontmost(_ pid: pid_t, before step: @autoclosure () -> String) -> Bool {
        if isStillFrontmost(pid) { return true }
        let now = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
        NSLog("[Menu du Jour] focus left pid %d (now %@) — abandoning before %@",
              pid, now, step())
        return false
    }
}
