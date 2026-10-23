import ApplicationServices

/// Whether an accessibility-activation nudge is worth attempting again.
///
/// The prewarm sends `AXManualAccessibility` to *every* app that activates,
/// because that is the only way to catch Electron apps we have never heard of.
/// The overwhelmingly common answer is `attributeUnsupported` from an ordinary
/// native app, and that answer cannot change for the life of the process.
///
/// Caching only successes — correct when the attribute was only ever sent to
/// apps expected to accept it — therefore turns into a repeated AX write on
/// every activation and every hotkey press, each able to spend the
/// process-wide 0.5s messaging timeout against a slow app.
///
/// So the cache key is "settled", not "succeeded": a permanent refusal is as
/// settled as a success. Genuinely transient failures must still be retried,
/// or a browser that was merely still launching never gets nudged at all
/// (the guarantee from REVIEW.md 2026-07-10 F6).
public enum AXActivationPolicy {

    /// True when the nudge should be attempted again on a later activation.
    public static func shouldRetry(after error: AXError) -> Bool {
        switch error {
        case .success:
            return false
        // The app answered definitively: it does not implement this, and
        // never will.
        case .attributeUnsupported, .actionUnsupported, .notImplemented, .illegalArgument:
            return false
        // Everything else — .cannotComplete from an app still launching,
        // .apiDisabled before the trust grant lands, .invalidUIElement from a
        // process that has gone away, and anything unrecognised — can change.
        default:
            return true
        }
    }
}
