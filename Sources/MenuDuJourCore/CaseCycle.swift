import Foundation

/// Pure logic for the change-case hotkey (Word's Shift+F3): case-state
/// classification, the lower → Title → UPPER cycle, and the transform itself.
/// Word tokenization treats letters/digits as word characters, with
/// apostrophes joining two letters ("dell'acqua" is one word).
public enum CaseCycle {

    public enum CaseState {
        case lower, title, upper, other
    }

    /// nil when the text contains no cased characters (digits, emoji, CJK…) —
    /// there is nothing to cycle, the caller should treat it as a silent no-op.
    /// Precedence: upper is checked before title so a single capital letter
    /// ("A") cycles back to lowercase instead of matching the title pattern.
    public static func classify(_ text: String) -> CaseState? {
        let casedChars = text.filter(isCased)
        guard !casedChars.isEmpty else { return nil }
        if casedChars.allSatisfy(isUppercase) { return .upper }
        if casedChars.allSatisfy(isLowercase) { return .lower }
        if matchesTitlePattern(text) { return .title }
        return .other
    }

    public static func next(after state: CaseState) -> CaseState {
        switch state {
        case .lower: return .title
        case .title: return .upper
        case .upper: return .lower
        case .other: return .lower
        }
    }

    /// Locale-insensitive transform. `.other` returns the text unchanged
    /// (the cycle never targets `.other`; it only starts from it).
    public static func transform(_ text: String, to state: CaseState) -> String {
        transformPieces(text, to: state).joined()
    }

    /// `transform`, kept as one output string per *source* `Character` instead
    /// of one joined string.
    ///
    /// Styled text needs the pieces, not the result. A case decision has to be
    /// made over the whole string — a style boundary is not a word boundary —
    /// but the output then has to be re-sliced along the original run
    /// boundaries, and offsets stop working the moment a character changes
    /// length (ß → SS, ﬁ → FI). Source characters are the one index that
    /// survives that: there is exactly one piece per character whatever each
    /// piece's length turns out to be. See `AttributedCaseCycle`.
    ///
    /// Joining the pieces reproduces `transform` exactly, which is why
    /// `transform` is now defined in terms of this. That equivalence holds
    /// because Swift applies no context-sensitive case mapping — Greek final
    /// sigma lowercases to σ whether or not it is word-final — and is pinned by
    /// `testJoinedPiecesEqualTheWholeStringTransform`.
    public static func transformPieces(_ text: String, to state: CaseState) -> [String] {
        let chars = Array(text)
        switch state {
        case .lower: return chars.map { String($0).lowercased() }
        case .upper: return chars.map { String($0).uppercased() }
        case .title: return titleCasedPieces(chars)
        case .other: return chars.map(String.init)
        }
    }

    /// A text range in UTF-16 code units — the unit kAXSelectedTextRange uses.
    public struct UTF16Range: Equatable {
        public let location: Int
        public let length: Int
        public init(location: Int, length: Int) {
            self.location = location
            self.length = length
        }
    }

    /// The word the caret is in, or — when the caret sits at a word edge —
    /// the adjacent word (a word ending at the caret beats one starting there).
    /// nil when the caret is in whitespace/punctuation with no adjacent word,
    /// out of bounds, or in the middle of a surrogate pair.
    public static func wordRange(in text: String, aroundUTF16Offset offset: Int) -> UTF16Range? {
        guard offset >= 0, offset <= text.utf16.count else { return nil }
        // Tokenizing the whole value to find one word costs a Character array
        // plus a String allocation per character — hundreds of milliseconds in
        // a long document, on the thread that answers the hotkey. Only the text
        // immediately around the caret can affect the answer, so only that is
        // scanned.
        guard let window = scanWindow(in: text, around: offset) else { return nil }
        guard let local = wordRange(inWindow: window.slice,
                                    aroundUTF16Offset: offset - window.location) else { return nil }
        return UTF16Range(location: window.location + local.location, length: local.length)
    }

    /// The scan window, in UTF-16 units on each side of the caret. Generous
    /// enough that the growth loop below almost never runs.
    private static let scanRadius = 512

    /// A slice of `text` guaranteed to contain every word that could touch
    /// `offset`, plus where that slice starts in UTF-16 units.
    ///
    /// The cut is pushed outwards past any word characters and apostrophes that
    /// straddle it, so tokenization inside the slice is identical to
    /// tokenization of the same region in the full text — a word is never
    /// truncated by the window, however long it is.
    private static func scanWindow(in text: String, around offset: Int) -> (slice: String, location: Int)? {
        let total = text.utf16.count
        // Below this, windowing costs more than it saves.
        if total <= scanRadius * 4 { return (text, 0) }

        guard var low = characterAlignedIndex(in: text, utf16Offset: max(0, offset - scanRadius),
                                              roundingDown: true),
              var high = characterAlignedIndex(in: text, utf16Offset: min(total, offset + scanRadius),
                                               roundingDown: false)
        else { return nil }

        while low > text.startIndex {
            let previous = text.index(before: low)
            guard isWordChar(text[previous]) || isApostrophe(text[previous]) else { break }
            low = previous
        }
        while high < text.endIndex, isWordChar(text[high]) || isApostrophe(text[high]) {
            high = text.index(after: high)
        }

        let location = text.utf16.distance(from: text.utf16.startIndex, to: low)
        return (String(text[low..<high]), location)
    }

    /// Nearest index that is both a valid `String.Index` and a Character
    /// boundary, searching in the given direction. A UTF-16 offset landing
    /// inside a surrogate pair has no Character boundary of its own.
    private static func characterAlignedIndex(
        in text: String,
        utf16Offset: Int,
        roundingDown: Bool
    ) -> String.Index? {
        let utf16 = text.utf16
        guard var cursor = utf16.index(utf16.startIndex, offsetBy: utf16Offset,
                                       limitedBy: utf16.endIndex) else { return nil }
        while true {
            if let aligned = String.Index(cursor, within: text) { return aligned }
            if roundingDown {
                guard cursor > utf16.startIndex else { return text.startIndex }
                cursor = utf16.index(before: cursor)
            } else {
                guard cursor < utf16.endIndex else { return text.endIndex }
                cursor = utf16.index(after: cursor)
            }
        }
    }

    private static func wordRange(inWindow text: String, aroundUTF16Offset offset: Int) -> UTF16Range? {
        let chars = Array(text)
        // Cumulative UTF-16 offset at each Character boundary: starts[i] is
        // the offset where chars[i] begins; starts[chars.count] is the total.
        var starts: [Int] = [0]
        starts.reserveCapacity(chars.count + 1)
        for c in chars {
            starts.append(starts[starts.count - 1] + String(c).utf16.count)
        }
        guard offset >= 0, offset <= starts[chars.count] else { return nil }

        let words = wordCharRanges(in: chars)
        func utf16Range(_ r: Range<Int>) -> UTF16Range {
            UTF16Range(location: starts[r.lowerBound], length: starts[r.upperBound] - starts[r.lowerBound])
        }
        // Strictly inside a word
        if let r = words.first(where: { starts[$0.lowerBound] < offset && offset < starts[$0.upperBound] }) {
            return utf16Range(r)
        }
        // Word ending exactly at the caret
        if let r = words.first(where: { starts[$0.upperBound] == offset }) {
            return utf16Range(r)
        }
        // Word starting exactly at the caret
        if let r = words.first(where: { starts[$0.lowerBound] == offset }) {
            return utf16Range(r)
        }
        return nil
    }

    /// A fully computed edit for the AX layer to apply verbatim:
    /// select `target`, set kAXSelectedText to `replacement`, restore `restored`.
    public struct Edit: Equatable {
        public let target: UTF16Range
        public let replacement: String
        public let restored: UTF16Range
        public init(target: UTF16Range, replacement: String, restored: UTF16Range) {
            self.target = target
            self.replacement = replacement
            self.restored = restored
        }
    }

    /// The single entry point for the AX layer. Returns nil when there is
    /// nothing to transform (caret not in a word, no cased characters, bad
    /// range) — the caller treats nil as a silent no-op, NOT an error.
    public static func plan(text: String, selectionLocation: Int, selectionLength: Int) -> Edit? {
        guard selectionLocation >= 0, selectionLength >= 0,
              selectionLocation + selectionLength <= text.utf16.count else { return nil }

        let target: UTF16Range
        if selectionLength > 0 {
            target = UTF16Range(location: selectionLocation, length: selectionLength)
        } else {
            guard let word = wordRange(in: text, aroundUTF16Offset: selectionLocation) else { return nil }
            target = word
        }

        guard target.length > 0,
              let current = utf16Substring(of: text, location: target.location, length: target.length),
              let state = classify(current) else { return nil }

        let nextState = next(after: state)
        let replacement = transform(current, to: nextState)

        let restored: UTF16Range
        if selectionLength > 0 {
            // Re-select the replacement (its UTF-16 length may differ, e.g. ß → SS).
            restored = UTF16Range(location: target.location, length: replacement.utf16.count)
        } else {
            // Shift the caret by the transformed length of the word text that
            // preceded it, clamped into the replacement.
            let prefixLength = selectionLocation - target.location
            let end = target.location + replacement.utf16.count
            var location = min(selectionLocation, end)
            if let prefix = utf16Substring(of: current, location: 0, length: prefixLength) {
                location = min(target.location + transform(prefix, to: nextState).utf16.count, end)
            }
            restored = UTF16Range(location: location, length: 0)
        }

        return Edit(target: target, replacement: replacement, restored: restored)
    }

    /// The full text as it should read after `edit` is applied — used by the
    /// AX layer both to verify that a write actually happened (apps can report
    /// success without editing) and as the payload for whole-value fallbacks.
    /// nil if the edit's target does not fit `text` on Character boundaries.
    public static func apply(_ edit: Edit, to text: String) -> String? {
        let suffixStart = edit.target.location + edit.target.length
        guard let prefix = utf16Substring(of: text, location: 0, length: edit.target.location),
              let suffix = utf16Substring(of: text, location: suffixStart,
                                          length: text.utf16.count - suffixStart)
        else { return nil }
        return prefix + edit.replacement + suffix
    }

    /// Public UTF-16 range extraction (the AX layer needs the target's current
    /// text, e.g. as the search string for find-and-replace based edits).
    public static func substring(of text: String, range: UTF16Range) -> String? {
        utf16Substring(of: text, location: range.location, length: range.length)
    }

    /// Extract a substring by UTF-16 range; nil if either boundary does not
    /// fall on a Character boundary (e.g. mid-surrogate-pair).
    private static func utf16Substring(of text: String, location: Int, length: Int) -> String? {
        let utf16 = text.utf16
        guard let start16 = utf16.index(utf16.startIndex, offsetBy: location, limitedBy: utf16.endIndex),
              let end16 = utf16.index(start16, offsetBy: length, limitedBy: utf16.endIndex),
              let start = String.Index(start16, within: text),
              let end = String.Index(end16, within: text) else { return nil }
        return String(text[start..<end])
    }

    // MARK: - Word tokenization (shared with wordRange in this file)

    /// Maximal runs of letters/digits over a Character array; an apostrophe
    /// (' or ’) is absorbed only when flanked by letters on both sides, so
    /// "boys'" tokenizes as "boys" but "dell'acqua" stays one word.
    static func wordCharRanges(in chars: [Character]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var i = 0
        while i < chars.count {
            guard isWordChar(chars[i]) else { i += 1; continue }
            var j = i + 1
            while j < chars.count {
                if isWordChar(chars[j]) {
                    j += 1
                } else if isApostrophe(chars[j]), j + 1 < chars.count,
                          chars[j - 1].isLetter, chars[j + 1].isLetter {
                    j += 2
                } else {
                    break
                }
            }
            ranges.append(i..<j)
            i = j
        }
        return ranges
    }

    private static func isWordChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber
    }

    private static func isApostrophe(_ c: Character) -> Bool {
        c == "'" || c == "’"
    }

    // MARK: - Case predicates

    private static func isCased(_ c: Character) -> Bool {
        String(c).lowercased() != String(c).uppercased()
    }

    private static func isUppercase(_ c: Character) -> Bool {
        String(c) == String(c).uppercased()
    }

    private static func isLowercase(_ c: Character) -> Bool {
        String(c) == String(c).lowercased()
    }

    /// Every word: first cased character uppercase, remaining cased lowercase.
    private static func matchesTitlePattern(_ text: String) -> Bool {
        let chars = Array(text)
        for range in wordCharRanges(in: chars) {
            let cased = chars[range].filter(isCased)
            guard let first = cased.first else { continue }
            if !isUppercase(first) { return false }
            if cased.dropFirst().contains(where: { !isLowercase($0) }) { return false }
        }
        return true
    }

    /// Lowercase everything, then uppercase the first cased character of each
    /// word — as one piece per source character.
    private static func titleCasedPieces(_ chars: [Character]) -> [String] {
        var pieces = chars.map { String($0).lowercased() }
        for range in wordCharRanges(in: chars) {
            for i in range where isCased(chars[i]) {
                pieces[i] = String(chars[i]).uppercased()
                break
            }
        }
        return pieces
    }
}
