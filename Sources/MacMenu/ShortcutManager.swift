import Carbon
import Cocoa
import Combine
import MenuDuJourCore

/// Manages the two global hotkeys using a CGEvent tap, which intercepts key
/// events at a low level — before other apps (like BetterTouchTool) can consume
/// them.
///
/// ## Why the tap runs on its own thread
///
/// This is an *active* session-level tap: every keystroke on the machine is
/// held until this process replies. The reply happens on whatever run loop the
/// tap's source is attached to. When that was the main run loop, any slow
/// main-thread work — a verified AX write cascade, an Apple Event, a TCC
/// consent prompt — stalled keyboard input system-wide and eventually got the
/// tap killed with `kCGEventTapDisabledByTimeout`.
///
/// Dispatching the handlers off the callback was not enough, because they were
/// dispatched *back onto the same run loop*. So the tap now owns a dedicated
/// thread whose only job is to answer the tap promptly. Handlers still run on
/// the main thread (they touch AppKit, NSAppleScript and AX); if they block,
/// only this app's UI is affected, never the user's typing.
///
/// Everything the callback reads therefore crosses a thread boundary and lives
/// in a lock-protected `TapState` snapshot rather than being read live.
final class ShortcutManager: ObservableObject {

    struct Shortcut: Equatable {
        var keyCode: UInt32
        var modifiers: UInt32  // Carbon modifier flags

        /// Human-readable description, e.g. "⌥M"
        var displayString: String {
            KeyCodeNames.displayString(keyCode: keyCode, carbonModifiers: modifiers)
        }
    }

    // Default: ⌥M (Option + M)
    static let defaultShortcut = Shortcut(keyCode: 0x2E, modifiers: UInt32(optionKey))

    // Default: ⇧F3 (Shift + F3) — Word's change-case key
    static let defaultCaseShortcut = Shortcut(
        keyCode: AppBehaviorPolicy.nativeCaseKeyCode,
        modifiers: AppBehaviorPolicy.nativeCaseCarbonModifiers
    )

    @Published var currentShortcut: Shortcut { didSet { publishTapState() } }
    @Published var caseShortcut: Shortcut { didSet { publishTapState() } }

    /// Called when the hotkey fires, on the main thread, with the PID of the
    /// process the keystroke was actually delivered to. Handlers must treat
    /// that PID as the operation's identity: main can be busy when the key is
    /// pressed, so by the time a handler runs the frontmost app may have
    /// changed, and acting on the new one is never what the user asked for.
    var onHotkeyPressed: ((pid_t) -> Void)?

    /// Called when the change-case hotkey fires. Same contract.
    var onCaseHotkeyPressed: ((pid_t) -> Void)?

    /// When true, the event tap passes all events through without consuming them.
    var isSuspended = false { didSet { publishTapState() } }

    /// Bundle IDs the user has declared we cannot serve, whatever the binding.
    /// Built-in per-app rules (Office's own Shift-F3) live in `AppBehaviorPolicy`.
    static let passThroughDefaultsKey = "caseShortcutPassThrough"
    private(set) var userConfiguredPassThroughBundleIDs: Set<String> = []

    private var defaultsObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private var launchObserver: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var retryTimer: Timer?

    // MARK: - Cross-thread state

    /// Everything the tap callback needs, copied under `stateLock`. The
    /// callback must never touch `@Published` properties, UserDefaults or
    /// NSWorkspace directly — it runs on the tap thread.
    private struct TapState {
        var shortcut = ShortcutManager.defaultShortcut
        var caseShortcut = ShortcutManager.defaultCaseShortcut
        var isSuspended = false
        var userConfiguredPassThrough: Set<String> = []
        /// Whether the opt-in clipboard case fallback is enabled. Gates the
        /// Outlook pass-through: with the fallback off there is no path that can
        /// serve Outlook's compose body, so its Shift-F3 is passed through as a
        /// silent no-op; with it on we claim the key so the cascade reaches it.
        var clipboardFallbackEnabled = false
        var frontmostBundleID: String?
        /// PID → bundle ID for every running app. Keyed by PID on purpose: the
        /// *mapping* never goes stale (a PID's bundle ID cannot change), unlike
        /// "who is frontmost", which is published from a main-queue observer
        /// and is therefore unreliable exactly when main is blocked. The tap
        /// resolves the key event's own target PID through this instead.
        var bundleIDsByPID: [pid_t: String] = [:]
    }

    private let stateLock = NSLock()
    private var tapState = TapState()
    private var eventTap: CFMachPort?
    private var tapThread: Thread?

    private func snapshot() -> TapState {
        stateLock.lock()
        defer { stateLock.unlock() }
        return tapState
    }

    /// Copy the current main-thread state into the tap-thread snapshot.
    private func publishTapState() {
        stateLock.lock()
        tapState.shortcut = currentShortcut
        tapState.caseShortcut = caseShortcut
        tapState.isSuspended = isSuspended
        tapState.userConfiguredPassThrough = userConfiguredPassThroughBundleIDs
        tapState.clipboardFallbackEnabled = ClipboardCaseFallback.isEnabled
        stateLock.unlock()
    }

    private func publishFrontmostBundleID(_ bundleID: String?) {
        stateLock.lock()
        tapState.frontmostBundleID = bundleID
        stateLock.unlock()
    }

    private func rememberApp(_ app: NSRunningApplication) {
        guard let bundleID = app.bundleIdentifier, app.processIdentifier > 0 else { return }
        stateLock.lock()
        tapState.bundleIDsByPID[app.processIdentifier] = bundleID
        stateLock.unlock()
    }

    private func forgetApp(_ app: NSRunningApplication) {
        stateLock.lock()
        tapState.bundleIDsByPID.removeValue(forKey: app.processIdentifier)
        stateLock.unlock()
    }

    // MARK: - Lifecycle

    init() {
        let savedKeyCode = UserDefaults.standard.object(forKey: "shortcutKeyCode") as? UInt32
        let savedModifiers = UserDefaults.standard.object(forKey: "shortcutModifiers") as? UInt32

        if let kc = savedKeyCode, let mod = savedModifiers {
            currentShortcut = Shortcut(keyCode: kc, modifiers: mod)
        } else {
            currentShortcut = Self.defaultShortcut
        }

        let savedCaseKeyCode = UserDefaults.standard.object(forKey: "caseShortcutKeyCode") as? UInt32
        let savedCaseModifiers = UserDefaults.standard.object(forKey: "caseShortcutModifiers") as? UInt32

        if let kc = savedCaseKeyCode, let mod = savedCaseModifiers {
            caseShortcut = Shortcut(keyCode: kc, modifiers: mod)
        } else {
            caseShortcut = Self.defaultCaseShortcut
        }

        loadPassThroughList()
        publishTapState()
        publishFrontmostBundleID(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)

        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.loadPassThroughList()
        }

        // The tap thread must not call into NSWorkspace, so the PID → bundle ID
        // map is maintained here. Seeded with everything already running,
        // because an app the user never switched to since we launched must
        // still resolve.
        for app in NSWorkspace.shared.runningApplications {
            rememberApp(app)
        }

        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.publishFrontmostBundleID(app?.bundleIdentifier)
            if let app { self?.rememberApp(app) }
        }
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.rememberApp(app)
            }
        }
        terminateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.forgetApp(app)
            }
        }
    }

    deinit {
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
        // these all come from the workspace notification center
        for token in [activationObserver, launchObserver, terminateObserver, wakeObserver]
            .compactMap({ $0 }) {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        retryTimer?.invalidate()
        tapThread?.cancel()
    }

    /// Call after accessibility permission has been requested.
    /// Installs the event tap immediately if trusted, otherwise polls until trusted.
    func start() {
        guard tapThread == nil else { return }
        if AccessibilityHelper.isTrusted() {
            Self.log("Accessibility granted — installing the event tap")
            startTapThread()
        } else {
            // Without this line a missing grant is indistinguishable from a
            // broken build: no hotkey works anywhere and nothing is logged
            // (the 2026-09-27 session lost hours to exactly that).
            Self.log("Accessibility NOT granted — hotkeys are inactive; polling every 2s (System Settings → Privacy & Security → Accessibility)")
            // Poll every 2 seconds until the user grants permission
            retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                guard let self = self else { timer.invalidate(); return }
                if AccessibilityHelper.isTrusted() {
                    timer.invalidate()
                    self.retryTimer = nil
                    Self.log("Accessibility granted — installing the event tap")
                    self.startTapThread()
                }
            }
        }
    }

    // MARK: - Shortcut editing

    /// Which of the two hotkeys a recorder edits.
    enum ShortcutTarget {
        case rightClick, caseCycle
    }

    func shortcut(for target: ShortcutTarget) -> Shortcut {
        switch target {
        case .rightClick: return currentShortcut
        case .caseCycle: return caseShortcut
        }
    }

    /// The shortcut of the *other* target — the recorder rejects assigning
    /// one hotkey's combo to the other.
    func otherShortcut(for target: ShortcutTarget) -> Shortcut {
        switch target {
        case .rightClick: return caseShortcut
        case .caseCycle: return currentShortcut
        }
    }

    func update(_ shortcut: Shortcut, for target: ShortcutTarget) {
        switch target {
        case .rightClick:
            currentShortcut = shortcut
            UserDefaults.standard.set(shortcut.keyCode, forKey: "shortcutKeyCode")
            UserDefaults.standard.set(shortcut.modifiers, forKey: "shortcutModifiers")
        case .caseCycle:
            caseShortcut = shortcut
            UserDefaults.standard.set(shortcut.keyCode, forKey: "caseShortcutKeyCode")
            UserDefaults.standard.set(shortcut.modifiers, forKey: "caseShortcutModifiers")
        }
    }

    private func loadPassThroughList() {
        userConfiguredPassThroughBundleIDs = Set(
            UserDefaults.standard.stringArray(forKey: Self.passThroughDefaultsKey)
                ?? ["com.microsoft.VSCode"]
        )
        publishTapState()
    }

    // MARK: - CGEvent Tap

    /// Spins up the dedicated tap thread and runs its run loop until cancelled.
    private func startTapThread() {
        let thread = Thread { [weak self] in
            guard let self = self else { return }
            guard self.createEventTap() else { return }
            // A plain CFRunLoopRun() cannot be cancelled; time-boxed passes let
            // the thread notice `cancel()` at teardown. Each pass gets its own
            // autorelease pool: this thread is permanent and services every
            // keystroke on the machine, and CFRunLoopRunInMode makes no promise
            // of a pool around a Mach-port callout.
            while !Thread.current.isCancelled {
                autoreleasepool {
                    _ = CFRunLoopRunInMode(.defaultMode, 1.0, false)
                }
            }
        }
        thread.name = "com.luca.menudujour.event-tap"
        thread.qualityOfService = .userInteractive
        tapThread = thread
        thread.start()

        // Re-enable the tap after system sleep/wake — macOS can silently kill it
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Self.log("system woke — re-enabling the event tap")
            self?.enableTap()
        }
    }

    private func enableTap() {
        stateLock.lock()
        let tap = eventTap
        stateLock.unlock()
        guard let tap = tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// Runs on the tap thread. Creates the tap and attaches it to *this*
    /// thread's run loop.
    private func createEventTap() -> Bool {
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,      // active tap — can modify/consume events
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: { (proxy, type, event, userInfo) -> Unmanaged<CGEvent>? in
                guard let userInfo = userInfo else {
                    return Unmanaged.passUnretained(event)
                }
                let mgr = Unmanaged<ShortcutManager>.fromOpaque(userInfo).takeUnretainedValue()

                // If the tap gets disabled (e.g. by system timeout), re-enable it
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    mgr.enableTap()
                    // Logged from main: this thread's only job is answering the tap.
                    let reason = type == .tapDisabledByTimeout ? "timeout" : "user input"
                    DispatchQueue.main.async {
                        ShortcutManager.log("event tap was disabled by the system (\(reason)) — re-enabled")
                    }
                    return Unmanaged.passUnretained(event)
                }

                let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
                let cgFlags = event.flags
                let isAutorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

                // Convert CGEventFlags to Carbon modifiers for comparison
                let carbonMods = KeyModifiers.carbonModifiers(fromCGEventFlags: cgFlags)

                // Snapshot once: the callback runs on the tap thread and must
                // not read main-thread state live. Handlers are dispatched to
                // main and may block there — that is fine now, because this
                // thread keeps answering the tap regardless. Autorepeats are
                // consumed (the key is ours) but fire nothing.
                // The PID the window server is delivering this key to. Captured
                // atomically with the event, so unlike "who is frontmost right
                // now" it cannot be stale — and it stays correct even while the
                // main thread is blocked and our activation observer cannot run.
                let targetPID = pid_t(event.getIntegerValueField(.eventTargetUnixProcessID))

                let state = mgr.snapshot()
                if !state.isSuspended {
                    if keyCode == state.shortcut.keyCode && carbonMods == state.shortcut.modifiers {
                        if !isAutorepeat {
                            DispatchQueue.main.async { mgr.onHotkeyPressed?(targetPID) }
                        }
                        return nil
                    }
                    if keyCode == state.caseShortcut.keyCode && carbonMods == state.caseShortcut.modifiers {
                        // Resolve the app from the event's own target PID, not
                        // from the frontmost snapshot: the pass-through
                        // decision is made here and cannot be deferred, so it
                        // must not depend on state that goes stale under load.
                        let bundleID = state.bundleIDsByPID[targetPID] ?? state.frontmostBundleID
                        // Office keeps its own Shift-F3; apps the user listed
                        // keep whatever they bound. Both decided in Core.
                        if AppBehaviorPolicy.shouldPassThroughCaseShortcut(
                            bundleID: bundleID,
                            keyCode: keyCode,
                            carbonModifiers: carbonMods,
                            userConfiguredBundleIDs: state.userConfiguredPassThrough,
                            clipboardFallbackEnabled: state.clipboardFallbackEnabled
                        ) {
                            DispatchQueue.main.async {
                                ShortcutManager.log("change-case key passed through to \(bundleID ?? "unknown app") (app policy — we do not handle it there)")
                            }
                            return Unmanaged.passUnretained(event)
                        }
                        if !isAutorepeat {
                            DispatchQueue.main.async { mgr.onCaseHotkeyPressed?(targetPID) }
                        }
                        return nil
                    }
                }

                return Unmanaged.passUnretained(event)
            },
            userInfo: selfPtr
        )

        guard let tap = tap else {
            Self.log("FAILED to create the event tap — the Accessibility grant is missing or stale (re-grant it; ad-hoc builds lose it on every rebuild)")
            return false
        }

        stateLock.lock()
        eventTap = tap
        stateLock.unlock()

        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        let state = snapshot()
        Self.log("event tap installed — menu \(state.shortcut.displayString), change case \(state.caseShortcut.displayString), synthetic-input fallback \(state.clipboardFallbackEnabled ? "on" : "off")")
        return true
    }

    /// NSLog via "%@", like every logger here, so nothing is parsed as a format
    /// string. To read these unredacted, see CLAUDE.md "Debugging a live build".
    static func log(_ message: String) {
        NSLog("%@", "[Menu du Jour] ShortcutManager: \(message)")
    }
}
