import Foundation

/// Case-cycling for *styled* text.
///
/// The clipboard fallback copies rich content out of an app and pastes it back,
/// so the transform has to survive the round trip with its formatting intact.
/// Transforming each attribute run independently would be wrong at run
/// boundaries — with runs `["He", "llo"]` (the "He" bold), per-run title-casing
/// produces "HeLlo", because the second run looks like the start of a word.
///
/// So the case decision is made once, over the whole plain string, and the
/// result is re-sliced along the original run boundaries.
///
/// Re-slicing by *offset* only works while the transform preserves UTF-16
/// length, which fails for the expanding characters (ß → SS, ﬁ → FI). This
/// used to fall back to a per-run transform in that case — which reintroduced
/// exactly the boundary bug above, just more rarely: `"ßa" + "bc"` title-cased
/// to `"SSa" + "Bc"` (REVIEW.md 2026-07-28 F3). So the slicing is done by
/// *source character* instead, via `CaseCycle.transformPieces`: there is one
/// piece per character no matter how long that piece turns out to be, so the
/// mapping survives any length change and there is no fallback left to be
/// wrong.
public enum AttributedCaseCycle {

    /// The whole-string transform, applied with every run's attributes kept.
    public static func transform(
        _ attributed: NSAttributedString,
        to state: CaseCycle.CaseState
    ) -> NSAttributedString {
        let plain = attributed.string
        guard !plain.isEmpty else { return attributed }

        // One output piece per source Character, and where each of those
        // characters starts in the UTF-16 offsets the runs are expressed in.
        let pieces = CaseCycle.transformPieces(plain, to: state)
        var starts: [Int] = []
        starts.reserveCapacity(pieces.count)
        var offset = 0
        for character in plain {
            starts.append(offset)
            offset += String(character).utf16.count
        }

        let result = NSMutableAttributedString()
        var next = 0
        attributed.enumerateAttributes(
            in: NSRange(location: 0, length: attributed.length)
        ) { attributes, range, _ in
            let end = range.location + range.length
            var piece = ""
            // A character belongs to the run its FIRST UTF-16 unit falls in, so
            // a run boundary splitting a grapheme cluster assigns it whole to
            // the earlier run rather than dropping or duplicating it.
            while next < starts.count, starts[next] < end {
                piece += pieces[next]
                next += 1
            }
            result.append(NSAttributedString(string: piece, attributes: attributes))
        }
        return result
    }

    /// The current case state of the styled text, as its plain string.
    /// nil when there is nothing cased to cycle.
    public static func classify(_ attributed: NSAttributedString) -> CaseCycle.CaseState? {
        CaseCycle.classify(attributed.string)
    }

    /// The next state in the cycle, or nil when nothing can be cycled.
    public static func nextState(for attributed: NSAttributedString) -> CaseCycle.CaseState? {
        guard let state = classify(attributed) else { return nil }
        return CaseCycle.next(after: state)
    }
}
