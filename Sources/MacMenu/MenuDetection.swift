import Cocoa
import ApplicationServices

/// Detects whether the frontmost app has an open context menu, and whether a
/// menu item is already focused.
///
/// Primary signal: a window at the pop-up-menu window layer
/// (`kCGPopUpMenuWindowLevel`) owned by the app. The 2026-07-13 diagnostics
/// showed that open NSMenu context menus appear NOWHERE in the app's AX tree
/// (no AXMenu child, focused element unchanged) in TextEdit, Chrome, and
/// Outlook — but they are real windows, and CGWindowList exposes layer and
/// owner PID without any extra permission (only window *titles* are gated
/// behind Screen Recording).
///
/// The AX checks are kept as a secondary signal: they are how we can tell a
/// menu *item* is focused (highlighted), which the window list can't see.
enum MenuDetection {

    struct MenuState {
        let menuOpen: Bool
        let itemFocused: Bool
    }

    static func currentState() -> MenuState {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return MenuState(menuOpen: false, itemFocused: false)
        }

        var menuOpen = popUpMenuWindowExists(for: app.processIdentifier)

        // Secondary: AXMenu child directly under the app element (rare, but
        // free to check) …
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        if !menuOpen,
           let children = axAttribute(appElement, kAXChildrenAttribute) as? [AXUIElement] {
            for child in children where axRole(child) == (kAXMenuRole as String) {
                menuOpen = true
                break
            }
        }

        // … and the system-wide focused element, the only way to see an
        // already-highlighted menu item.
        var itemFocused = false
        let systemWide = AXUIElementCreateSystemWide()
        if let focused = axAttribute(systemWide, kAXFocusedUIElementAttribute) {
            let role = axRole(focused as! AXUIElement) ?? ""
            if role == (kAXMenuItemRole as String) {
                menuOpen = true
                itemFocused = true
            } else if role == (kAXMenuRole as String) {
                menuOpen = true
            }
        }

        return MenuState(menuOpen: menuOpen, itemFocused: itemFocused)
    }

    /// True if keyboard focus in `pid` sits on a menu or menu item — how an
    /// in-page (ARIA) menu shows up. Native NSMenus never take AX focus (see
    /// above), so this cannot mistake one for the other. Office for the web's
    /// keyboard menu measured as a focused AXMenuItem inside an AXMenu
    /// (probe 2026-09-28).
    static func inPageMenuHasFocus(for pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        guard let focused = axAttribute(app, kAXFocusedUIElementAttribute) else { return false }
        let role = axRole(focused as! AXUIElement) ?? ""
        return role == (kAXMenuItemRole as String) || role == (kAXMenuRole as String)
    }

    /// True if an on-screen window owned by `pid` sits at the pop-up-menu
    /// window layer (where NSMenu hosts open menus).
    static func popUpMenuWindowExists(for pid: pid_t) -> Bool {
        let popUpLevel = CGWindowLevelForKey(.popUpMenuWindow)
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]] else {
            return false
        }
        return info.contains { entry in
            (entry[kCGWindowOwnerPID as String] as? pid_t) == pid
                && (entry[kCGWindowLayer as String] as? CGWindowLevel) == popUpLevel
        }
    }

    private static func axAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private static func axRole(_ element: AXUIElement) -> String? {
        axAttribute(element, kAXRoleAttribute) as? String
    }
}
