import Carbon

/// Built-in per-app compatibility rules for the change-case hotkey.
///
/// Two different reasons an app can want the key left alone, and they are NOT
/// interchangeable:
///
///   1. The app implements Shift-F3 itself (Microsoft Office). Its claim is on
///      *that specific combination* — if the user rebinds our hotkey to ⌃⌥C,
///      Word has no ⌃⌥C command, so passing ⌃⌥C through would silently
///      disable the feature in Office and give nothing back.
///   2. The app hides its text from AX and the user prefers its own command
///      (the user-configured list, default `com.microsoft.VSCode`). That claim
///      is on *whatever* combination the user bound, because the point is that
///      we cannot serve the app at all.
public enum AppBehaviorPolicy {

    /// Word's change-case key: Shift+F3. Apps in `nativeCaseShortcutBundleIDs`
    /// only get a pass when the configured hotkey actually is this combination.
    public static let nativeCaseKeyCode: UInt32 = 0x63
    public static let nativeCaseCarbonModifiers = UInt32(shiftKey)

    /// These apps already provide native Shift-F3 behavior. Note that Outlook
    /// for Mac is deliberately NOT here — see `webBackedOfficeBundleIDs`.
    private static let nativeCaseShortcutBundleIDs: Set<String> = [
        "com.microsoft.Word",
        "com.microsoft.Excel",
        "com.microsoft.Powerpoint",
        "com.microsoft.onenote.mac",
    ]

    /// Office apps whose editor is web-backed and, unlike the rest of Office,
    /// binds no Shift-F3 of its own — passing the chord through gives the user
    /// nothing (verified 2026-09-04: ⇧F3 does nothing in Outlook for Mac even
    /// with this app quit). Its compose body also defeats our AX write paths
    /// (they report success and edit nothing), so the *only* way we can serve
    /// it is the opt-in clipboard fallback. Hence the gated rule below: pass
    /// the key through — a silent no-op, not a beep — while that fallback is
    /// off, and claim it so the cascade reaches the fallback once it is on.
    private static let webBackedOfficeBundleIDs: Set<String> = [
        "com.microsoft.Outlook",
    ]

    /// True when the pressed combination should reach `bundleID` untouched.
    public static func shouldPassThroughCaseShortcut(
        bundleID: String?,
        keyCode: UInt32,
        carbonModifiers: UInt32,
        userConfiguredBundleIDs: Set<String>,
        clipboardFallbackEnabled: Bool
    ) -> Bool {
        guard let bundleID else { return false }
        // (2) The user declared we cannot serve this app — whatever the binding.
        if userConfiguredBundleIDs.contains(bundleID) { return true }
        // (1) Office's own Shift-F3 — only on that exact chord, so a rebound key
        // Office does not implement is not silently swallowed.
        if nativeCaseShortcutBundleIDs.contains(bundleID)
            && isNativeCaseShortcut(keyCode: keyCode, carbonModifiers: carbonModifiers) {
            return true
        }
        // (3) Web-backed Office (Outlook): no native Shift-F3 to defer to, and
        // servable only through the opt-in clipboard fallback. While that is
        // off we cannot do better than the app itself (nothing), so pass the
        // key through for a silent no-op instead of a beep; once it is on, claim
        // the key so the case cascade can reach the fallback.
        if webBackedOfficeBundleIDs.contains(bundleID) {
            return !clipboardFallbackEnabled
        }
        return false
    }

    /// True when the combination is the one Office itself binds.
    public static func isNativeCaseShortcut(keyCode: UInt32, carbonModifiers: UInt32) -> Bool {
        keyCode == nativeCaseKeyCode && carbonModifiers == nativeCaseCarbonModifiers
    }

    // MARK: - Contextual-menu key

    /// Apps whose web-backed editors mishandle the contextual-menu key.
    private static let contextMenuKeyBreaksInWebContent: Set<String> = [
        "com.microsoft.Outlook",
    ]

    /// Whether keycode 110 may be posted to this app at all.
    ///
    /// The strategy needs no allowlist *because* it self-gates: post the key,
    /// look for a menu, fall through when none appears. That is only safe while
    /// the key is inert where it fails. Outlook's compose body breaks the
    /// assumption — measured 2026-08-06, posting 110 there selects the word one
    /// line BELOW the caret (caret at index 15 on line 0 became a selection of
    /// "ads" at 34..36, the last word of line 1, moving down another line on
    /// each further press) and opens Outlook's menu around that wrong word.
    /// Nothing we send corrects Outlook's hit test, and the damage is done
    /// before any runtime check can see it, so the key must not be sent.
    ///
    /// Scoped to web content, and to Outlook: Outlook's own native surfaces —
    /// message list, subject field — are where the key measurably works, and
    /// Mail's compose editor is WebKit too yet behaves correctly, so neither
    /// "is Outlook" nor "is web content" is on its own the right test.
    public static func shouldPostContextMenuKey(
        bundleID: String?,
        focusedElementIsWebContent: Bool
    ) -> Bool {
        guard let bundleID, focusedElementIsWebContent else { return true }
        return !contextMenuKeyBreaksInWebContent.contains(bundleID)
    }

    // MARK: - Caret click button

    public enum ClickButton: Equatable { case left, right }

    /// Apps whose web-backed editor shows its spelling suggestions on a left
    /// click on the word, not a right-click (owner report 2026-10-22, Outlook
    /// for Mac: a right-click in the compose body does not bring them up).
    private static let spellingMenuOnLeftClickInWebContent: Set<String> = [
        "com.microsoft.Outlook",
    ]

    /// Which button the precise caret click uses. Same app + web-content
    /// scoping as `shouldPostContextMenuKey`, and for the same reason:
    /// Outlook's native surfaces behave like any AppKit app.
    public static func caretClickButton(
        bundleID: String?,
        focusedElementIsWebContent: Bool
    ) -> ClickButton {
        guard let bundleID, focusedElementIsWebContent,
              spellingMenuOnLeftClickInWebContent.contains(bundleID) else { return .right }
        return .left
    }
    // MARK: - Web apps with their own keyboard context menu

    /// How to ask the focused app to open its own context menu.
    public enum MenuRequest: Equatable {
        /// The PC contextual-menu key (keycode 110): AppKit apps and Firefox pages.
        case contextMenuKey
        /// Shift+F10, the keyboard context-menu shortcut Office for the web
        /// listens for.
        case shiftF10
    }

    /// Office's web editors draw their own context menu in the page. Asked
    /// with Shift+F10, PowerPoint on the web opens it at its caret with its
    /// spelling suggestions, identical to a real right-click (owner test
    /// 2026-09-28, Firefox). The contextual-menu key gets no confirmed menu
    /// there, and the fallback click cannot find the caret: the page reports
    /// focus on a list and the same off-slide point on every press, because
    /// Office draws its own caret. The editor always runs in a frame on
    /// officeapps.live.com, even when the address bar shows SharePoint (probe
    /// 2026-09-28: powerpoint.officeapps.live.com inside *.sharepoint.com), so
    /// the host of the nearest web page identifies it.
    private static func isOfficeWebEditor(host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "officeapps.live.com" || host.hasSuffix(".officeapps.live.com")
    }

    /// Which request to make, given the host of the web page nearest the
    /// focused element (nil outside web content).
    public static func menuRequest(forWebPageHost host: String?) -> MenuRequest {
        isOfficeWebEditor(host: host) ? .shiftF10 : .contextMenuKey
    }

    /// Whether the caret click may run when the menu request produced no
    /// confirmed menu. Not in Office's web editors: the click lands off the
    /// caret and opens the wrong menu, which is worse than none (the same
    /// judgement as native PowerPoint).
    public static func mayClickAfterFailedMenuRequest(webPageHost host: String?) -> Bool {
        !isOfficeWebEditor(host: host)
    }
}
