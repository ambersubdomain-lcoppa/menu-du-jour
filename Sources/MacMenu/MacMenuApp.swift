import MenuDuJourCore
import ServiceManagement
import SwiftUI

@main
struct MenuDuJourApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    static let menuBarIcon: NSImage = {
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        let base = NSImage(systemSymbolName: "contextualmenu.and.cursorarrow", accessibilityDescription: "Menu du Jour")!
            .withSymbolConfiguration(config)!
        base.isTemplate = true
        // Shift the icon up slightly so it looks vertically centered in the menu bar
        let size = base.size
        let yOffset: CGFloat = 3
        let newSize = NSSize(width: size.width, height: size.height + yOffset)
        let image = NSImage(size: newSize, flipped: false) { rect in
            base.draw(in: NSRect(x: 0, y: yOffset, width: size.width, height: size.height))
            return true
        }
        image.isTemplate = true
        return image
    }()

    var body: some Scene {
        // We use MenuBarExtra for the menu bar icon; no main window.
        MenuBarExtra {
            MenuBarView(shortcutManager: appDelegate.shortcutManager, launchAtLoginManager: appDelegate.launchAtLoginManager, appDelegate: appDelegate)
        } label: {
            Image(nsImage: Self.menuBarIcon)
        }
        .menuBarExtraStyle(.menu)
    }
}

// MARK: - Launch at Login

class LaunchAtLoginManager: ObservableObject {
    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if isEnabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                print("[Menu du Jour] Launch-at-login toggle failed: \(error)")
                // Revert the published value so the UI stays in sync with reality
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    let actual = SMAppService.mainApp.status == .enabled
                    if self.isEnabled != actual {
                        self.isEnabled = actual
                    }
                }
            }
        }
    }

    init() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }
}

// MARK: - Menu bar dropdown

struct MenuBarView: View {
    @ObservedObject var shortcutManager: ShortcutManager
    @ObservedObject var launchAtLoginManager: LaunchAtLoginManager
    var appDelegate: AppDelegate

    var body: some View {
        Text("Menu Shortcut: \(shortcutManager.currentShortcut.displayString)")

        Button("Change Menu Shortcut...") {
            appDelegate.openRecorderWindow(target: .rightClick)
        }

        Text("Change Case: \(shortcutManager.caseShortcut.displayString)")

        Button("Change Case Shortcut...") {
            appDelegate.openRecorderWindow(target: .caseCycle)
        }

        Toggle("Change Case: synthetic input fallback", isOn: Binding(
            get: { ClipboardCaseFallback.isEnabled },
            set: { ClipboardCaseFallback.isEnabled = $0 }
        ))
        if ClipboardCaseFallback.isEnabled {
            Text("Types the new text (or uses ⌘C/⌘V) so Change Case works in Outlook, terminals and other apps we can't edit directly.")
        }

        Toggle("Start at Login", isOn: $launchAtLoginManager.isEnabled)

        Divider()

        Toggle("Diagnostic Mode", isOn: Binding(
            get: { appDelegate.diagnosticMode },
            set: { appDelegate.diagnosticMode = $0 }
        ))
        if appDelegate.diagnosticMode {
            Text("Hotkey now probes the focused app; report is copied to clipboard.")
        }

        Divider()

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    let shortcutManager = ShortcutManager()
    let launchAtLoginManager = LaunchAtLoginManager()
    /// When true, the hotkey runs AX diagnostics instead of opening a menu.
    var diagnosticMode = false
    var recorderWindow: NSWindow?
    private var recorderTarget: ShortcutManager.ShortcutTarget = .rightClick
    private var recorderWindowObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Prompt for accessibility permission (single system dialog — no custom alert)
        _ = AccessibilityHelper.isTrusted(promptIfNeeded: true)

        // Wire up the hotkey action
        shortcutManager.onHotkeyPressed = { [weak self] originPID in
            self?.handleHotkey(originPID: originPID)
        }

        shortcutManager.onCaseHotkeyPressed = { [weak self] originPID in
            self?.handleCaseHotkey(originPID: originPID)
        }

        CaseToggler.onBrowserSetupHint = { [weak self] browserName in
            // Async so the hotkey press that triggered the hint still gets
            // its AX fallback immediately; the alert appears right after.
            DispatchQueue.main.async {
                self?.showBrowserSetupAlert(browserName: browserName)
            }
        }

        // Install the event tap (or poll until permission is granted)
        shortcutManager.start()

        // Prewarm AX trees on activation so the first hotkey press sees the
        // full tree — Chromium, Electron and Firefox all build theirs
        // asynchronously after being nudged (REVIEW.md F6).
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                AccessibilityHelper.prewarmAccessibility(for: app)
            }
        }
        // PIDs are recycled: a prewarm cache that never forgets would skip a
        // brand-new process that inherited a dead one's PID.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                AccessibilityHelper.forgetPrewarm(pid: app.processIdentifier)
            }
        }
        if let frontmost = NSWorkspace.shared.frontmostApplication {
            AccessibilityHelper.prewarmAccessibility(for: frontmost)
        }
    }

    /// One-time (per browser, per run) explanation of the browser toggle the
    /// in-page Change Case path needs. Triggered via CaseToggler's hint hook.
    private func showBrowserSetupAlert(browserName: String) {
        let alert = NSAlert()
        alert.messageText = "Enable in-page Change Case for \(browserName)"
        alert.informativeText = """
        Menu du Jour can change case inside web editors (Gmail, etc.) by \
        running JavaScript in the page, but \(browserName) currently \
        blocks that.

        To enable it:
        1. \(browserName == "Safari"
             ? "Safari → Settings → Advanced → “Show features for web developers”, then Develop → Allow JavaScript from Apple Events"
             : "\(browserName) menu → View → Developer → Allow JavaScript from Apple Events")
        2. Approve the Automation permission prompt if macOS shows one.

        Until then, ⇧F3 falls back to the accessibility method \
        (plain-text fields only).
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    func openRecorderWindow(target: ShortcutManager.ShortcutTarget) {
        if let existing = recorderWindow, existing.isVisible {
            if target == recorderTarget {
                // Same shortcut — just bring the window forward
                existing.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                return
            }
            // Different shortcut — close and rebuild (willClose observer
            // resets suspension/policy synchronously before we continue)
            existing.close()
        }
        recorderTarget = target

        // Menu bar apps are "accessory" by default and can't receive key events.
        // Temporarily become a regular app so the window can get focus.
        NSApp.setActivationPolicy(.regular)

        let window = NSWindow()
        window.title = "Set Shortcut"
        window.styleMask = [.titled, .closable]
        window.level = .floating
        window.isReleasedWhenClosed = false

        shortcutManager.isSuspended = true

        let contentView = ShortcutRecorderView(shortcutManager: shortcutManager, target: target) { [weak window] in
            window?.close()
        }
        let hostingController = NSHostingController(rootView: contentView)
        window.contentViewController = hostingController

        // Handle any close path (red button, save callback, programmatic) uniformly.
        recorderWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.shortcutManager.isSuspended = false
            NSApp.setActivationPolicy(.accessory)
            self.recorderWindow = nil
            if let token = self.recorderWindowObserver {
                NotificationCenter.default.removeObserver(token)
                self.recorderWindowObserver = nil
            }
        }

        window.center()
        window.makeKeyAndOrderFront(nil)
        recorderWindow = window

        NSApp.activate(ignoringOtherApps: true)
    }

    private func handleHotkey(originPID: pid_t) {
        Self.logPress("menu", originPID: originPID)
        guard AccessibilityHelper.isTrusted() else {
            showAccessibilityAlert()
            return
        }

        // The press may have queued behind slow work on this thread; if the
        // user has since switched apps, every coordinate we are about to
        // resolve belongs to the wrong one.
        guard OriginatingApp.stillFrontmost(originPID, before: "the menu hotkey") else { return }

        if diagnosticMode {
            AXDiagnostics.run()
            return
        }

        // Office's web editors: Shift+F10 makes them open their own menu at
        // their own caret; the contextual-menu key gets no confirmed menu
        // there, and the caret click lands off the slide. No click afterwards,
        // for the same reason (AppBehaviorPolicy.mayClickAfterFailedMenuRequest).
        let host = AccessibilityHelper.focusedElement()
            .flatMap { AccessibilityHelper.isWebContent($0) ? AccessibilityHelper.nearestWebPageHost(from: $0) : nil }
        if let host = host {
            NSLog("%@", "[Menu du Jour] web page host: \(host)")
        }
        if AppBehaviorPolicy.menuRequest(forWebPageHost: host) == .shiftF10 {
            ContextMenuKey.attempt(originPID: originPID, request: .shiftF10) { opened in
                guard !opened else { return }
                if AppBehaviorPolicy.mayClickAfterFailedMenuRequest(webPageHost: host) { return }
                NSLog("%@", "[Menu du Jour] no confirmed menu in an Office web editor — not clicking (the click lands off the caret there)")
                NSSound.beep()
            }
            return
        }

        // Ask the app to place its own menu first. When it works — every
        // AppKit app measured — it is better than anything we can compute,
        // and we never touch the AX caret machinery at all. Chromium ignores
        // the key, produces no menu, and falls through below.
        //
        // Unless the key is known to do damage here. Self-gating ("no menu
        // appeared, so nothing happened") assumes the key is inert where it
        // fails; in Outlook's web-backed compose body it is not — it selects
        // the word one line below the caret before any check of ours can run.
        guard mayPostContextMenuKey(originPID: originPID) else {
            openMenuAtResolvedCaret(originPID: originPID)
            return
        }

        ContextMenuKey.attempt(originPID: originPID) { [weak self] opened in
            guard !opened else { return }
            self?.openMenuAtResolvedCaret(originPID: originPID)
        }
    }

    /// Whether the contextual-menu key may be posted for this press.
    /// The two facts the policy needs — which app owns the press, and whether
    /// what has focus inside it is web content — are both read here, from the
    /// originating PID rather than from "who is frontmost".
    private func mayPostContextMenuKey(originPID: pid_t) -> Bool {
        let bundleID = NSRunningApplication(processIdentifier: originPID)?.bundleIdentifier
        let isWeb = AccessibilityHelper.focusedElement().map(AccessibilityHelper.isWebContent) ?? false
        let allowed = AppBehaviorPolicy.shouldPostContextMenuKey(
            bundleID: bundleID,
            focusedElementIsWebContent: isWeb
        )
        if !allowed {
            NSLog("[Menu du Jour] skipping the contextual-menu key in %@ web content — it moves the selection there",
                  bundleID ?? "unknown")
        }
        return allowed
    }

    /// The original path: work out where the caret is in screen pixels and
    /// right-click there. Now the fallback for apps that ignore the
    /// contextual-menu key.
    private func openMenuAtResolvedCaret(originPID: pid_t) {
        guard OriginatingApp.stillFrontmost(originPID, before: "caret resolution") else { return }

        guard let result = AccessibilityHelper.caretPosition() else {
            // Could not find caret — do nothing silently
            return
        }

        switch result {
        case .caret(let point):
            // Outlook's compose body opens its spelling menu on a LEFT click.
            // Only the precise caret gets this: a left click on an element's
            // centre would move the user's caret to somewhere arbitrary.
            let bundleID = NSRunningApplication(processIdentifier: originPID)?.bundleIdentifier
            let isWeb = AccessibilityHelper.focusedElement().map(AccessibilityHelper.isWebContent) ?? false
            if AppBehaviorPolicy.caretClickButton(bundleID: bundleID, focusedElementIsWebContent: isWeb) == .left {
                NSLog("%@", "[Menu du Jour] \(bundleID ?? "unknown") web content: left-click at the caret (its spelling menu opens on a left click)")
                RightClickSimulator.leftClick(atCaret: point, originPID: originPID)
            } else {
                RightClickSimulator.rightClick(at: point, originPID: originPID)
            }
        case .selectedChild(let point, _):
            RightClickSimulator.rightClick(at: point, originPID: originPID)
        case .centerOfElement(let point, let element):
            // Imprecise — semantic kAXShowMenuAction first (the app places its
            // own menu), then a real right-click at the focused element's center
            // if no menu actually appears. Same order for browsers: Shift+F10
            // (REVIEW.md F2) was retired after the 2026-07-13/14 diagnostics
            // showed it opening a menu in NONE of the fallback contexts
            // (TextEdit beeps, Chromium ignores it in empty inputs/Gmail),
            // while kAXShowMenuAction and the center click each worked in
            // every tested case.
            RightClickSimulator.showContextMenuForImpreciseTarget(
                element, fallbackPoint: point, originPID: originPID)
        }
    }

    /// Diagnostic Mode intentionally only affects the menu hotkey — the
    /// change-case hotkey stays functional.
    private func handleCaseHotkey(originPID: pid_t) {
        Self.logPress("change-case", originPID: originPID)
        guard AccessibilityHelper.isTrusted() else {
            showAccessibilityAlert()
            return
        }
        guard OriginatingApp.stillFrontmost(originPID, before: "the change-case hotkey") else {
            return
        }
        CaseToggler.cycleCase(originPID: originPID)
    }

    /// One line per press naming the app it belongs to, so a log shows which
    /// app each later decision was made for.
    private static func logPress(_ hotkey: String, originPID: pid_t) {
        let app = NSRunningApplication(processIdentifier: originPID)?.bundleIdentifier ?? "unknown app"
        NSLog("%@", "[Menu du Jour] \(hotkey) hotkey pressed in \(app) (pid \(originPID))")
    }

    private func showAccessibilityAlert() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Accessibility Permission Required"
            alert.informativeText = "Menu du Jour needs Accessibility access to detect the text caret position.\n\nPlease grant access in:\nSystem Settings → Privacy & Security → Accessibility"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Later")

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}
