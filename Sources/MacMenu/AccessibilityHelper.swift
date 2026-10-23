import Cocoa
import ApplicationServices
import MenuDuJourCore

/// Describes how the caret/target position was determined.
enum CaretResult {
    /// Found the actual text caret position
    case caret(CGPoint)
    /// Found a selected item in a list/table/outline; carries the selected
    /// element so diagnostics can probe the actual row, not just the container
    case selectedChild(CGPoint, AXUIElement)
    /// Fell back to the center of the focused element (imprecise); carries the
    /// element so the fallback can try the semantic kAXShowMenuAction on it
    case centerOfElement(CGPoint, AXUIElement)

    var point: CGPoint {
        switch self {
        case .caret(let p): return p
        case .selectedChild(let p, _), .centerOfElement(let p, _): return p
        }
    }
}

enum AccessibilityHelper {

    /// System-wide AX element, created once. Setting a messaging timeout on the
    /// system-wide element applies process-wide, so no AX call from this app can
    /// block for the multi-second default when the target app is hung.
    private static let systemWide: AXUIElement = {
        let element = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(element, 0.5)
        return element
    }()

    /// Chromium-based browser bundle IDs that need AXEnhancedUserInterface to expose
    /// web content in the accessibility tree.
    private static let chromiumBundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser",  // Arc
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
    ]

    private static let firefoxBundleIDs: Set<String> = [
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "org.mozilla.nightly",
        "org.mozilla.floorp",
        "app.zen-browser.zen",
        "org.torproject.torbrowser",
    ]

    /// Setting `AXEnhancedUserInterface` is what makes Chromium expose web
    /// content, but it is also what makes window managers (Rectangle, Magnet,
    /// Moom) go sluggish against that browser — it is VoiceOver's attribute and
    /// Chromium treats it as "a screen reader is present". That trade is worth
    /// it by default, since without it the caret is invisible to us in every
    /// Chromium browser, but it is the user's machine:
    ///     defaults write com.luca.menudujour disableChromiumEnhancedUI -bool YES
    static let disableChromiumEnhancedUIKey = "disableChromiumEnhancedUI"

    /// PIDs whose nudge is *settled*, per mechanism — either it worked or the
    /// app refused permanently (`AXActivationPolicy`). Caching only successes
    /// would mean re-asking every native app on every activation and every
    /// hotkey press for an answer that cannot change. Not pruning these would
    /// eventually skip a *new* process that reused a dead PID, so terminations
    /// clear them.
    private static var enhancedUIPIDs = Set<pid_t>()
    private static var manualAccessibilityPIDs = Set<pid_t>()
    private static var firefoxPokedPIDs = Set<pid_t>()

    /// Ask an app to expose its full accessibility tree, by whichever mechanism
    /// that app understands. All three are asynchronous — the tree is rebuilt
    /// after the nudge — which is why this runs when an app *activates* rather
    /// than at hotkey time (REVIEW.md F6).
    ///
    /// Idempotent per PID and per mechanism; must be called on the main thread
    /// (the PID caches are unsynchronized).
    static func prewarmAccessibility(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid > 0 else { return }
        let bundleID = app.bundleIdentifier
        let appElement = AXUIElementCreateApplication(pid)

        // Electron (Slack, Discord, Notion, Obsidian, Teams, VS Code, …) ships
        // AXManualAccessibility precisely so non-VoiceOver assistive tech can
        // switch its tree on — and unlike AXEnhancedUserInterface it has no
        // window-management side effect. Attempted on every app, since that is
        // the only way to catch Electron apps we have never heard of; the
        // native majority answer attributeUnsupported once and are then never
        // asked again.
        if !manualAccessibilityPIDs.contains(pid) {
            let result = AXUIElementSetAttributeValue(
                appElement, "AXManualAccessibility" as CFString, true as CFTypeRef)
            if !AXActivationPolicy.shouldRetry(after: result) {
                manualAccessibilityPIDs.insert(pid)
                if result == .success {
                    log("Enabled AXManualAccessibility for \(bundleID ?? "pid \(pid)")")
                }
            }
        }

        guard let bundleID else { return }

        // Firefox resolved this differently from Electron: rather than adding
        // an attribute, it enables its accessibility engine as soon as the role
        // of the application element is read (Mozilla bug 1664992 comment 7 /
        // bug 1845364). So the "nudge" is simply a read.
        if firefoxBundleIDs.contains(bundleID), !firefoxPokedPIDs.contains(pid) {
            if axRole(appElement) != nil {
                firefoxPokedPIDs.insert(pid)
                log("Poked Firefox accessibility for \(bundleID)")
            }
        }

        if chromiumBundleIDs.contains(bundleID),
           !enhancedUIPIDs.contains(pid),
           !UserDefaults.standard.bool(forKey: disableChromiumEnhancedUIKey) {
            let result = AXUIElementSetAttributeValue(
                appElement, "AXEnhancedUserInterface" as CFString, true as CFTypeRef)
            // A transient failure (browser still launching, cannotComplete, …)
            // must be retried on the next activation, or the first-query race
            // stays unresolved for that process forever (REVIEW.md 2026-07-10
            // F6 verification). A permanent refusal is settled.
            if !AXActivationPolicy.shouldRetry(after: result) {
                enhancedUIPIDs.insert(pid)
            }
        }
    }

    /// Drop a dead process from the prewarm caches. Without this, a relaunched
    /// browser that lands on a recycled PID is treated as already warmed and
    /// never gets its nudge.
    static func forgetPrewarm(pid: pid_t) {
        enhancedUIPIDs.remove(pid)
        manualAccessibilityPIDs.remove(pid)
        firefoxPokedPIDs.remove(pid)
    }

    /// The system-wide focused UI element (the element that truly has focus,
    /// which for browsers is more reliable than asking the app directly).
    static func focusedElement() -> AXUIElement? {
        var focusedValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedValue)
        guard result == .success, let focused = focusedValue else {
            log("No focused element (error: \(result.rawValue))")
            return nil
        }
        return (focused as! AXUIElement)
    }

    /// True when `element` is web content (Safari, Chromium, Electron, and
    /// embedded web views like Outlook's compose editor) — they expose DOM
    /// bookkeeping attributes native AppKit views don't have.
    ///
    /// One definition, two callers: the case-cycle cascade uses it to pick an
    /// edit path, and the menu hotkey uses it to decide whether the
    /// contextual-menu key is safe to post (`AppBehaviorPolicy`).
    /// Host of the web page nearest `element`: the first `AXWebArea` on its
    /// way up that exposes an `AXURL`. Nearest, not outermost, because an
    /// embedded editor is its own page — PowerPoint on the web is
    /// powerpoint.officeapps.live.com inside a SharePoint page.
    static func nearestWebPageHost(from element: AXUIElement) -> String? {
        var current: AXUIElement? = element
        for _ in 0..<60 {
            guard let el = current else { return nil }
            var role: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role) == .success,
               (role as? String) == "AXWebArea" {
                var raw: CFTypeRef?
                if AXUIElementCopyAttributeValue(el, "AXURL" as CFString, &raw) == .success, let raw = raw {
                    let url = (raw as? URL) ?? URL(string: "\(raw)")
                    if let host = url?.host, !host.isEmpty { return host.lowercased() }
                }
            }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, kAXParentAttribute as CFString, &parent) == .success,
                  let next = parent else { return nil }
            current = (next as! AXUIElement)
        }
        return nil
    }

    static func isWebContent(_ element: AXUIElement) -> Bool {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success,
              let list = names as? [String] else { return false }
        return list.contains("AXDOMIdentifier")
    }

    /// Returns the screen coordinates of the text caret in the frontmost app,
    /// or the selected item in list views (e.g. Finder),
    /// or falls back to the center of the focused element.
    /// Returns `nil` if nothing useful is found.
    static func caretPosition() -> CaretResult? {
        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        let appName = frontmostApplication?.localizedName ?? "unknown"
        log("App: \(appName)")

        // Backstop for the activation-time prewarm (e.g. the browser was
        // already frontmost before our observer existed).
        if let app = frontmostApplication {
            prewarmAccessibility(for: app)
        }

        guard let focusedElement = Self.focusedElement() else { return nil }
        log("Focused element role: \(axRole(focusedElement) ?? "unknown")")

        // PowerPoint is served by the contextual-menu key, which reaches this
        // function only if that key failed. It keeps AX focus on its slide
        // scroll area while text is being edited, so every strategy below
        // resolves to the slide rather than the caret and the imprecise
        // fallback opens the *slide* menu — the wrong menu, which the
        // 2026-07-10 review judged worse than nothing. Decline instead.
        //
        // This replaced ~300 lines that asked PowerPoint for its caret over
        // Apple Events and mapped slide coordinates to the screen. All of that
        // existed to compute a pixel; keycode 110 makes PowerPoint place its
        // own menu at its own caret, so the pixel is no longer needed.
        if frontmostApplication?.bundleIdentifier == "com.microsoft.Powerpoint" {
            log("PowerPoint: no precise caret without the contextual-menu key; suppressing imprecise fallback")
            NSSound.beep()
            return nil
        }

        // Strategy 1: text caret position
        if let point = caretFromInsertionPoint(focusedElement), isOnScreen(point) {
            log("Strategy: caret → \(point)")
            return .caret(point)
        }

        // Strategy 2: selected item in a list/table/outline (e.g. Finder)
        if let target = selectedChildTarget(focusedElement) {
            log("Strategy: selected child → \(target.point)")
            return .selectedChild(target.point, target.child)
        }

        // Strategy 3: fall back to the center of the focused element itself
        if let point = centerOfElement(focusedElement) {
            log("Strategy: center of element → \(point)")
            return .centerOfElement(point, focusedElement)
        }

        log("All strategies failed")
        return nil
    }

    /// Check whether the current process is trusted for Accessibility.
    static func isTrusted(promptIfNeeded: Bool = false) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): promptIfNeeded] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Debug

    /// NSLog, not print: the release bundle is launched by `open`, so stdout
    /// goes nowhere and only the unified log reaches
    /// `build-release.sh --log`. The "%@" form is deliberate — messages carry
    /// user text and AX values, which can contain % and would otherwise be
    /// read as format specifiers.
    private static func log(_ message: String) {
        NSLog("%@", "[Menu du Jour] \(message)")
    }

    private static func axRole(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value)
        guard result == .success else { return nil }
        return value as? String
    }

    // MARK: - Private

    /// Returns true if the point falls within any connected display's bounds.
    /// AX positions are in the global CG coordinate space (top-left origin), so
    /// compare against CGDisplayBounds — NOT NSScreen.frame, which is Cocoa
    /// bottom-left-origin and only coincides numerically on a single primary
    /// display.
    private static func isOnScreen(_ point: CGPoint) -> Bool {
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success, displayCount > 0 else {
            return true  // can't enumerate displays — don't reject a valid caret
        }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        guard CGGetActiveDisplayList(displayCount, &displays, &displayCount) == .success else {
            return true
        }
        for display in displays {
            if CGDisplayBounds(display).contains(point) {
                return true
            }
        }
        log("  Point \(point) is off-screen, ignoring")
        return false
    }

    private static func caretFromInsertionPoint(_ element: AXUIElement) -> CGPoint? {
        var knownSelectionLength: Int?
        var knownSelectionRange: CFRange?

        // Prefer the legacy integer-range API when the app implements it.
        var rangeValue: CFTypeRef?
        let rangeResult = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue)
        if rangeResult == .success, let range = rangeValue {
            var cfRange = CFRange(location: 0, length: 0)
            if AXValueGetValue(range as! AXValue, .cfRange, &cfRange) {
                knownSelectionLength = cfRange.length
                knownSelectionRange = cfRange
                log("  Selection range: location=\(cfRange.location), length=\(cfRange.length)")

                // Query a character rect rather than a zero-length range; many
                // native apps return an unusable caret rectangle for the latter.
                let plans = CaretRange.queryPlans(location: cfRange.location, length: cfRange.length)
                for plan in plans {
                    let range = CFRange(location: plan.location, length: plan.length)
                    if let rect = boundsForRange(element: element, range: range) {
                        let point = CaretRange.point(forEdge: plan.edge, in: rect)
                        log("  Bounds for \(plan) → \(rect) → \(point)")
                        return point
                    }
                }
                log("  Legacy range geometry unavailable")
            } else {
                log("  Could not extract CFRange")
            }
        } else {
            log("  No selected text range")
        }

        // Chromium/WebKit controls often expose web text markers even when
        // AXBoundsForRange is unsupported. Resolve those before falling back to
        // the element center, which can open a menu unrelated to the selection.
        if let point = caretFromTextMarkerRange(
            element,
            knownSelectionLength: knownSelectionLength
        ) {
            return point
        }

        if let range = knownSelectionRange,
           let point = caretByProbingSelectionBoundaries(element, originalRange: range) {
            return point
        }

        log("  All caret geometry queries failed")
        return nil
    }

    private static func caretFromTextMarkerRange(
        _ element: AXUIElement,
        knownSelectionLength: Int?
    ) -> CGPoint? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextMarkerRangeAttribute as CFString,
            &value
        )
        guard result == .success,
              let rawRange = value,
              CFGetTypeID(rawRange) == AXTextMarkerRangeGetTypeID()
        else {
            log("  No selected text marker range")
            return nil
        }

        let selectedRange = rawRange as! AXTextMarkerRange
        let startMarker = AXTextMarkerRangeCopyStartMarker(selectedRange)
        let endMarker = AXTextMarkerRangeCopyEndMarker(selectedRange)
        let hasSelection = knownSelectionLength.map { $0 > 0 }
            ?? !CFEqual(startMarker, endMarker)

        for plan in CaretRange.textMarkerQueryPlans(hasSelection: hasSelection) {
            guard let target = textMarkerTarget(
                for: plan.range,
                selectedRange: selectedRange,
                startMarker: startMarker,
                endMarker: endMarker,
                element: element
            ) else { continue }

            if target.isSingleCharacter,
               let point = pointFromCollapsedTextMarkers(
                   target,
                   edge: plan.edge,
                   element: element
               ) {
                log("  Text marker boundaries for \(plan) → \(point)")
                return point
            }

            if let rect = boundsForTextMarkerRange(element: element, range: target.range) {
                guard !matchesElementFrame(rect, element: element) else {
                    log("  Text marker bounds echoed the focused element, ignoring")
                    continue
                }
                let point = CaretRange.point(forEdge: plan.edge, in: rect)
                log("  Text marker bounds for \(plan) → \(rect) → \(point)")
                return point
            }
        }

        log("  Text marker geometry unavailable")
        return nil
    }

    private struct TextMarkerTarget {
        let range: AXTextMarkerRange
        let startMarker: AXTextMarker
        let endMarker: AXTextMarker
        let isSingleCharacter: Bool
    }

    private static func textMarkerTarget(
        for kind: TextMarkerRangeKind,
        selectedRange: AXTextMarkerRange,
        startMarker: AXTextMarker,
        endMarker: AXTextMarker,
        element: AXUIElement
    ) -> TextMarkerTarget? {
        switch kind {
        case .selected:
            return TextMarkerTarget(
                range: selectedRange,
                startMarker: startMarker,
                endMarker: endMarker,
                isSingleCharacter: false
            )
        case .previousCharacter:
            guard let previous = adjacentTextMarker(
                from: endMarker,
                attribute: kAXPreviousTextMarkerForTextMarkerParameterizedAttribute,
                element: element
            ) else { return nil }
            return TextMarkerTarget(
                range: makeTextMarkerRange(
                    startMarker: previous,
                    endMarker: endMarker,
                    element: element
                ),
                startMarker: previous,
                endMarker: endMarker,
                isSingleCharacter: true
            )
        case .nextCharacter:
            guard let next = adjacentTextMarker(
                from: startMarker,
                attribute: kAXNextTextMarkerForTextMarkerParameterizedAttribute,
                element: element
            ) else { return nil }
            return TextMarkerTarget(
                range: makeTextMarkerRange(
                    startMarker: startMarker,
                    endMarker: next,
                    element: element
                ),
                startMarker: startMarker,
                endMarker: next,
                isSingleCharacter: true
            )
        }
    }

    private static func pointFromCollapsedTextMarkers(
        _ target: TextMarkerTarget,
        edge: CaretQuery.Edge,
        element: AXUIElement
    ) -> CGPoint? {
        let startRange = makeTextMarkerRange(
            startMarker: target.startMarker,
            endMarker: target.startMarker,
            element: element
        )
        let endRange = makeTextMarkerRange(
            startMarker: target.endMarker,
            endMarker: target.endMarker,
            element: element
        )
        guard let startRect = boundsForTextMarkerRange(element: element, range: startRange),
              let endRect = boundsForTextMarkerRange(element: element, range: endRange),
              !matchesElementFrame(startRect, element: element),
              !matchesElementFrame(endRect, element: element)
        else { return nil }

        let startPoint = CGPoint(x: startRect.midX, y: startRect.midY)
        let endPoint = CGPoint(x: endRect.midX, y: endRect.midY)
        let lineTolerance = max(2, min(startRect.height, endRect.height) / 2)
        guard abs(startPoint.y - endPoint.y) <= lineTolerance else { return nil }

        return CaretRange.point(
            forEdge: edge,
            startBoundary: startPoint,
            endBoundary: endPoint
        )
    }

    private static func makeTextMarkerRange(
        startMarker: AXTextMarker,
        endMarker: AXTextMarker,
        element: AXUIElement
    ) -> AXTextMarkerRange {
        let markers = [startMarker, endMarker] as CFArray
        var value: CFTypeRef?
        let result = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXTextMarkerRangeForUnorderedTextMarkersParameterizedAttribute as CFString,
            markers,
            &value
        )
        if result == .success,
           let rawRange = value,
           CFGetTypeID(rawRange) == AXTextMarkerRangeGetTypeID() {
            return rawRange as! AXTextMarkerRange
        }

        return AXTextMarkerRangeCreate(nil, startMarker, endMarker)
    }

    private static func adjacentTextMarker(
        from marker: AXTextMarker,
        attribute: String,
        element: AXUIElement
    ) -> AXTextMarker? {
        var value: CFTypeRef?
        let result = AXUIElementCopyParameterizedAttributeValue(
            element,
            attribute as CFString,
            marker,
            &value
        )
        guard result == .success,
              let rawMarker = value,
              CFGetTypeID(rawMarker) == AXTextMarkerGetTypeID()
        else { return nil }
        return (rawMarker as! AXTextMarker)
    }

    private static func caretByProbingSelectionBoundaries(
        _ element: AXUIElement,
        originalRange: CFRange
    ) -> CGPoint? {
        guard originalRange.location >= 0,
              originalRange.length > 0,
              originalRange.location <= Int.max - originalRange.length
        else { return nil }

        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &settable
        ) == .success,
        settable.boolValue
        else { return nil }

        let originalText = stringAttribute(element, kAXSelectedTextAttribute)
        var restored = false
        defer {
            if !restored,
               !stabilizeSelectedTextRange(originalRange, on: element) {
                log("  WARNING: selection-boundary probe could not stabilize the original range")
            }
        }

        let lastCharacterStart = CFRange(
            location: originalRange.location + originalRange.length - 1,
            length: 0
        )
        let selectionEnd = CFRange(
            location: originalRange.location + originalRange.length,
            length: 0
        )

        guard setSelectedTextRange(lastCharacterStart, on: element) else {
            log("  Selection-boundary probe could not set the character start")
            return nil
        }
        guard let startPoint = collapsedSelectedTextMarkerPoint(element) else {
            log("  Selection-boundary probe could not resolve the character start")
            return nil
        }
        guard setSelectedTextRange(selectionEnd, on: element) else {
            log("  Selection-boundary probe could not set the selection end")
            return nil
        }
        guard let endPoint = collapsedSelectedTextMarkerPoint(element) else {
            log("  Selection-boundary probe could not resolve the selection end")
            return nil
        }
        guard setSelectedTextRange(originalRange, on: element) else {
            log("  Selection-boundary probe could not restore the original range")
            return nil
        }
        restored = true

        guard let restoredRange = selectedTextRange(element),
              rangesEqual(restoredRange, originalRange),
              originalText == nil || stringAttribute(element, kAXSelectedTextAttribute) == originalText
        else {
            log("  Selection-boundary restoration verification failed")
            return nil
        }

        let lineTolerance: CGFloat = 8
        guard abs(startPoint.y - endPoint.y) <= lineTolerance else {
            log("  Selection-boundary points are on different lines")
            return nil
        }

        let point = CaretRange.point(
            forEdge: .center,
            startBoundary: startPoint,
            endBoundary: endPoint
        )
        log("  Verified selection-boundary probe → \(startPoint), \(endPoint) → \(point)")
        return point
    }

    private static func collapsedSelectedTextMarkerPoint(
        _ element: AXUIElement
    ) -> CGPoint? {
        let deadline = Date().addingTimeInterval(0.1)
        repeat {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                element,
                kAXSelectedTextMarkerRangeAttribute as CFString,
                &value
            ) == .success,
            let rawRange = value,
            CFGetTypeID(rawRange) == AXTextMarkerRangeGetTypeID() {
                let range = rawRange as! AXTextMarkerRange
                let startMarker = AXTextMarkerRangeCopyStartMarker(range)
                let endMarker = AXTextMarkerRangeCopyEndMarker(range)
                if CFEqual(startMarker, endMarker),
                   let rect = boundsForTextMarkerRange(element: element, range: range),
                   !matchesElementFrame(rect, element: element) {
                    return CGPoint(x: rect.midX, y: rect.midY)
                }
            }
            usleep(5_000)
        } while Date() < deadline
        return nil
    }

    private static func selectedTextRange(_ element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        ) == .success,
        let rawValue = value,
        CFGetTypeID(rawValue) == AXValueGetTypeID()
        else { return nil }

        let axValue = rawValue as! AXValue
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
    }

    private static func setSelectedTextRange(
        _ range: CFRange,
        on element: AXUIElement
    ) -> Bool {
        let result = writeSelectedTextRange(range, on: element)
        guard result == .success else {
            log("  Selected-range write failed with AX error \(result.rawValue)")
            return false
        }

        // Chromium applies this successful AX write on a later accessibility
        // pass. Do not probe marker geometry until read-back confirms the range.
        let deadline = Date().addingTimeInterval(0.2)
        repeat {
            if let actualRange = selectedTextRange(element),
               rangesEqual(actualRange, range) {
                return true
            }
            usleep(5_000)
        } while Date() < deadline
        return false
    }

    private static func writeSelectedTextRange(
        _ range: CFRange,
        on element: AXUIElement
    ) -> AXError {
        guard let value = AXValueCreate(.cfRange, [range]) else {
            return .illegalArgument
        }
        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            value
        )
    }

    /// A timed-out Chromium write can still land after the caller starts
    /// restoring. Reassert the original range until it stays stable long enough
    /// to outlast the normal asynchronous-write window.
    private static func stabilizeSelectedTextRange(
        _ range: CFRange,
        on element: AXUIElement
    ) -> Bool {
        let deadline = Date().addingTimeInterval(0.6)
        var stableSince: Date?
        var nextWrite = Date.distantPast

        repeat {
            let now = Date()
            if now >= nextWrite {
                _ = writeSelectedTextRange(range, on: element)
                nextWrite = now.addingTimeInterval(0.05)
            }

            if let actualRange = selectedTextRange(element),
               rangesEqual(actualRange, range) {
                if stableSince == nil { stableSince = now }
                if now.timeIntervalSince(stableSince!) >= 0.25 {
                    return true
                }
            } else {
                stableSince = nil
            }
            usleep(5_000)
        } while Date() < deadline
        return false
    }

    private static func rangesEqual(_ lhs: CFRange, _ rhs: CFRange) -> Bool {
        lhs.location == rhs.location && lhs.length == rhs.length
    }

    private static func stringAttribute(
        _ element: AXUIElement,
        _ attribute: String
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success
        else { return nil }
        return value as? String
    }

    /// Look for a selected child/row in list-like containers (Finder, tables,
    /// outlines), returning both its center point and the element itself.
    private static func selectedChildTarget(_ element: AXUIElement) -> (point: CGPoint, child: AXUIElement)? {
        // kAXSelectedRowsAttribute (tables, outlines), then
        // kAXSelectedChildrenAttribute (icon views, general containers)
        for attribute in [kAXSelectedRowsAttribute, kAXSelectedChildrenAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
               let array = value as? [AXUIElement],
               let first = array.first,
               let point = centerOfElement(first) {
                return (point, first)
            }
        }
        return nil
    }

    private static func boundsForRange(element: AXUIElement, range: CFRange) -> CGRect? {
        guard let rangeValue = AXValueCreate(.cfRange, [range]) else { return nil }

        var boundsValue: CFTypeRef?
        let result = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &boundsValue
        )
        guard result == .success, let bounds = boundsValue else { return nil }

        guard let rect = rectValue(from: bounds) else { return nil }
        // Chrome returns bounds with zero size — treat as failure
        guard rect.width > 0 || rect.height > 0 else {
            log("  boundsForRange returned zero-size rect, ignoring")
            return nil
        }
        return rect
    }

    private static func boundsForTextMarkerRange(
        element: AXUIElement,
        range: AXTextMarkerRange
    ) -> CGRect? {
        var boundsValue: CFTypeRef?
        let result = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForTextMarkerRangeParameterizedAttribute as CFString,
            range,
            &boundsValue
        )
        guard result == .success,
              let bounds = boundsValue,
              let rect = rectValue(from: bounds),
              rect.width > 0 || rect.height > 0
        else { return nil }
        return rect
    }

    private static func rectValue(from value: CFTypeRef) -> CGRect? {
        if CFGetTypeID(value) == AXValueGetTypeID() {
            let axValue = value as! AXValue
            guard AXValueGetType(axValue) == .cgRect else { return nil }
            var rect = CGRect.zero
            guard AXValueGetValue(axValue, .cgRect, &rect) else { return nil }
            return rect
        }

        // AX web constants document NSValue for text-marker bounds.
        return (value as? NSValue)?.rectValue
    }

    private static func matchesElementFrame(_ rect: CGRect, element: AXUIElement) -> Bool {
        guard let frame = frameOfElement(element) else { return false }
        let tolerance: CGFloat = 0.5
        return abs(rect.minX - frame.minX) <= tolerance
            && abs(rect.minY - frame.minY) <= tolerance
            && abs(rect.maxX - frame.maxX) <= tolerance
            && abs(rect.maxY - frame.maxY) <= tolerance
    }

    private static func frameOfElement(_ element: AXUIElement) -> CGRect? {
        var posValue: CFTypeRef?
        var sizeValue: CFTypeRef?

        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success
        else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }

        return CGRect(origin: position, size: size)
    }

    private static func centerOfElement(_ element: AXUIElement) -> CGPoint? {
        guard let frame = frameOfElement(element) else { return nil }
        return CGPoint(x: frame.midX, y: frame.midY)
    }
}
