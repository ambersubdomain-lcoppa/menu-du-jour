import CoreGraphics

/// A single AX bounds query to attempt when locating the caret, plus which edge
/// of the resulting rect represents the caret position.
public struct CaretQuery: Equatable {
    /// Which horizontal point of the resolved character rect to click. `center`
    /// exists for selections: a click on the trailing edge lands on the selection
    /// boundary and, depending on rounding, just outside it — Word-family apps
    /// then drop the selection and reselect the word under the cursor.
    public enum Edge { case leading, trailing, center }

    public let location: Int
    public let length: Int
    public let edge: Edge

    public init(location: Int, length: Int, edge: Edge) {
        self.location = location
        self.length = length
        self.edge = edge
    }
}

/// The marker range to resolve when an app exposes web-style AX text markers
/// instead of the legacy integer-range geometry API.
public enum TextMarkerRangeKind: Equatable {
    case selected
    case previousCharacter
    case nextCharacter
}

public struct TextMarkerQuery: Equatable {
    public let range: TextMarkerRangeKind
    public let edge: CaretQuery.Edge

    public init(range: TextMarkerRangeKind, edge: CaretQuery.Edge) {
        self.range = range
        self.edge = edge
    }
}

/// Pure decision logic for turning a selected-text range into an ordered list of
/// AX bounds queries to try. The caller runs each query against the AX element in
/// order and uses the first that returns a valid rect. Separated from the AX
/// calls so the (subtle, regression-prone) ordering is unit-testable.
public enum CaretRange {

    /// Ordered query plans for a selection at `location` with `length` characters.
    /// A zero `length` means a plain caret.
    public static func queryPlans(location: Int, length: Int) -> [CaretQuery] {
        // Position 0 with no selection: only the first char's leading edge exists.
        if length == 0 && location == 0 {
            return [CaretQuery(location: 0, length: 1, edge: .leading)]
        }

        var plans: [CaretQuery] = []

        if length == 0 {
            // Plain caret after some text: char immediately before the caret,
            // trailing edge.
            plans.append(CaretQuery(location: location - 1, length: 1, edge: .trailing))
        } else {
            // Selection: last selected char first (avoids multi-line bounding-box
            // blow-up), clicking its center so the point stays INSIDE the
            // selection; then the whole range as a fallback.
            plans.append(CaretQuery(location: location + length - 1, length: 1, edge: .center))
            plans.append(CaretQuery(location: location, length: length, edge: .trailing))
        }

        // Universal last resort: first character's leading edge.
        plans.append(CaretQuery(location: 0, length: 1, edge: .leading))
        return plans
    }

    /// Ordered geometry fallbacks for web-style AX text marker ranges.
    public static func textMarkerQueryPlans(hasSelection: Bool) -> [TextMarkerQuery] {
        if hasSelection {
            return [
                TextMarkerQuery(range: .previousCharacter, edge: .center),
                TextMarkerQuery(range: .nextCharacter, edge: .center),
                TextMarkerQuery(range: .selected, edge: .center),
            ]
        }

        return [
            TextMarkerQuery(range: .selected, edge: .leading),
            TextMarkerQuery(range: .previousCharacter, edge: .trailing),
            TextMarkerQuery(range: .nextCharacter, edge: .leading),
        ]
    }

    /// The caret point on the given edge of a resolved character rect.
    public static func point(forEdge edge: CaretQuery.Edge, in rect: CGRect) -> CGPoint {
        switch edge {
        case .leading:  return CGPoint(x: rect.minX, y: rect.midY)
        case .trailing: return CGPoint(x: rect.maxX, y: rect.midY)
        case .center:   return CGPoint(x: rect.midX, y: rect.midY)
        }
    }

    /// Resolves an edge from logical marker boundaries. Unlike a CGRect, this
    /// preserves leading/trailing order for right-to-left text.
    public static func point(
        forEdge edge: CaretQuery.Edge,
        startBoundary: CGPoint,
        endBoundary: CGPoint
    ) -> CGPoint {
        switch edge {
        case .leading:
            return startBoundary
        case .trailing:
            return endBoundary
        case .center:
            return CGPoint(
                x: (startBoundary.x + endBoundary.x) / 2,
                y: (startBoundary.y + endBoundary.y) / 2
            )
        }
    }
}
