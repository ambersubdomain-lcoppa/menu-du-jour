# Menu du Jour

A small macOS menu bar app that gives the Mac a **menu key**: press a shortcut
and the right-click menu opens at the text caret — spelling suggestions, Look
Up, Services and the rest — without reaching for the mouse. It also adds a
Word-style **change-case** shortcut that works system-wide.

- **⌥M** — open the context menu at the caret (or on the selected item in
  Finder and other lists).
- **⇧F3** — cycle the word under the caret, or the selection, through
  lower → Title → UPPER case.

Both shortcuts can be changed from the menu bar icon.

## How it works

Menu du Jour first asks the app to open its own menu, the way the Windows menu
key does. AppKit apps (TextEdit, Mail, Word, Excel, Finder, Firefox…) place it
at their own caret. Apps that ignore the request (Chrome, Electron apps, Java
apps) get a simulated right-click at the caret position read through the
macOS Accessibility API. A few apps get special handling, for example Office
for the web (Shift+F10) and Outlook's compose window, which shows spelling
suggestions on a left click.

Change case edits text in place through the Accessibility API and checks the
result before reporting success. In browsers it runs a small in-page script, so
formatting and undo survive. An optional **synthetic input fallback** (off by
default) types or pastes the replacement in apps that cannot be edited
directly, such as Outlook's compose window and terminals.

## Requirements

- macOS 13 Ventura or later.
- **Accessibility permission** (System Settings → Privacy & Security →
  Accessibility). The app asks on first launch; without it the shortcuts do
  nothing.
- Optional, for change case in browsers with rich text: the browser's
  "Allow JavaScript from Apple Events" setting, and the Automation permission
  macOS asks for the first time.

## Install

Download the latest notarized build from
[Releases](../../releases), unzip it, and move **Menu du Jour.app** to
Applications. Toggle **Start at Login** in its menu to keep it running.

## Build from source

Requires Xcode command-line tools (Swift 5.9+). No third-party dependencies.

```bash
swift build      # compile
swift test       # unit tests for the pure logic in MenuDuJourCore
bash macmenu_scripts/build-release.sh          # ad-hoc signed .app in .build/, launched
bash macmenu_scripts/build-release.sh --log    # same, then stream the app's log
```

An ad-hoc signed build gets a new signature every time, so macOS asks for the
Accessibility permission again after each rebuild.

## Known limitations

- In browsers, a simulated right-click opens the browser's menu, not a web
  app's own menu (Office for the web is the handled exception).
- Simulating a click briefly shows the mouse cursor in apps that hide it while
  you type.
- Some apps that draw their own text views report no caret; the menu then
  opens on the focused element instead.

[CLAUDE.md](CLAUDE.md) holds the detailed design notes: why each strategy
exists, what was measured in which app, and the rules any change must keep.

## License

[MIT](LICENSE)
