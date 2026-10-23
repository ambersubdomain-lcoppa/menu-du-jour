import ApplicationServices

/// Attempts the semantic `kAXShowMenuAction` on an element and, if refused,
/// on its ancestors — some apps expose the context menu on a containing row,
/// table, or web area rather than on the focused leaf, so probing only the
/// leaf gives false negatives (REVIEW.md F1/F5).
enum AXMenuAction {

    struct Attempt {
        let role: String
        let error: AXError
    }

    struct WalkResult {
        let attempts: [Attempt]
        /// The walk stops on the first success, so only the last attempt can be it.
        var succeeded: Bool { attempts.last?.error == .success }
    }

    /// Performs kAXShowMenuAction on `element` and up to `maxDepth` ancestors,
    /// stopping at the first success. Tracks visited elements to survive
    /// AXParent cycles.
    static func performShowMenu(startingAt element: AXUIElement, maxDepth: Int = 5) -> WalkResult {
        var attempts: [Attempt] = []
        var visited: [AXUIElement] = []
        var current: AXUIElement? = element

        for _ in 0...maxDepth {
            guard let el = current else { break }
            guard !visited.contains(where: { CFEqual($0, el) }) else { break }
            visited.append(el)

            let role = axRole(el) ?? "unknown"
            let error = AXUIElementPerformAction(el, kAXShowMenuAction as CFString)
            attempts.append(Attempt(role: role, error: error))
            if error == .success { break }

            current = axParent(el)
        }
        return WalkResult(attempts: attempts)
    }

    private static func axRole(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func axParent(_ element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value) == .success,
              let v = value else { return nil }
        return (v as! AXUIElement)
    }
}
