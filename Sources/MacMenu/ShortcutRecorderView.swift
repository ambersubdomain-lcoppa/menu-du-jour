import SwiftUI
import Carbon
import MenuDuJourCore

/// A small window that captures the next key combo the user presses
/// and saves it as the new shortcut.
struct ShortcutRecorderView: View {
    @ObservedObject var shortcutManager: ShortcutManager
    let target: ShortcutManager.ShortcutTarget
    var onDismiss: () -> Void
    @State private var recordedShortcut: ShortcutManager.Shortcut?
    @State private var currentModifierFlags: NSEvent.ModifierFlags = []
    @State private var eventMonitor: Any?

    var body: some View {
        VStack(spacing: 16) {
            Text("Press your desired shortcut")
                .font(.headline)

            Text("Current: \(shortcutManager.shortcut(for: target).displayString)")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Text(displayText)
                .font(.system(size: 24, weight: .medium, design: .rounded))
                .frame(minWidth: 120, minHeight: 44)
                .padding(.horizontal, 16)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.15)))

            if conflictsWithOtherShortcut {
                Text("Already used by the other shortcut")
                    .font(.caption)
                    .foregroundColor(.red)
            }

            HStack(spacing: 12) {
                Button("Cancel") {
                    doCancel()
                }
                .keyboardShortcut(.cancelAction)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.accentColor, lineWidth: 1.5)
                )

                Button("Save") {
                    doSave()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(recordedShortcut == nil || conflictsWithOtherShortcut)
            }
        }
        .padding(24)
        .frame(width: 300)
        .onAppear {
            startMonitoring()
        }
        .onDisappear {
            cleanup()
        }
    }

    private var displayText: String {
        if let shortcut = recordedShortcut {
            return shortcut.displayString
        }
        return "Waiting..."
    }

    /// True when the recorded combo is already used by the other hotkey.
    private var conflictsWithOtherShortcut: Bool {
        recordedShortcut == shortcutManager.otherShortcut(for: target)
    }

    private func doCancel() {
        cleanup()
        onDismiss()
    }

    private func doSave() {
        if let shortcut = recordedShortcut {
            shortcutManager.update(shortcut, for: target)
        }
        cleanup()
        onDismiss()
    }

    private func startMonitoring() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.type == .flagsChanged {
                currentModifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                return nil
            }

            // The keyDown carries its own modifier state; the flagsChanged
            // tracking above is only for the "Waiting…" display. Reading it
            // here would go stale whenever a flagsChanged event is missed
            // (window activation, another app grabbing the modifier).
            let cleanFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let carbonModifiers = KeyModifiers.carbonModifiers(fromCocoaFlags: cleanFlags)

            // Bare Esc/Return/Space drive the window itself. WITH a modifier
            // they are legitimate shortcut keys — ⌥Space must be recordable,
            // not treated as "dismiss".
            if carbonModifiers == 0 {
                switch event.keyCode {
                case 0x35:               return event  // Esc — cancel
                case 0x24, 0x4C:         return event  // Return/Enter — save
                case 0x31:               doCancel(); return nil  // Space — dismiss
                default:                 return nil    // needs a modifier
                }
            }

            // Ignore bare modifier key presses
            let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
            if modifierKeyCodes.contains(event.keyCode) { return nil }

            recordedShortcut = ShortcutManager.Shortcut(
                keyCode: UInt32(event.keyCode),
                modifiers: carbonModifiers
            )

            return nil
        }
    }

    private func cleanup() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

}
