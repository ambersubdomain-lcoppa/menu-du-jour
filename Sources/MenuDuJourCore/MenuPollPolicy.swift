/// Decides what the post-click menu poll should do at each tick.
/// Review verdict (REVIEW.md F4): never post arrow-down unless a menu is
/// positively detected AND no menu item is already focused — a blind
/// arrow-down mutates Finder selections, spreadsheet cells, autocomplete
/// choices; an already-focused item would be skipped to the second.
public enum MenuPollAction: Equatable {
    /// Post arrow-down to highlight the menu's first item.
    case highlightFirstItem
    /// Stop polling and post nothing.
    case stop
    /// No conclusion yet — poll again.
    case keepPolling
}

public enum MenuPollPolicy {
    public static func action(menuOpen: Bool,
                              menuItemFocused: Bool,
                              deadlineReached: Bool) -> MenuPollAction {
        if menuItemFocused { return .stop }
        if menuOpen { return .highlightFirstItem }
        if deadlineReached { return .stop }
        return .keepPolling
    }
}
