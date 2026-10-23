import Carbon
import XCTest
@testable import MenuDuJourCore

final class AppBehaviorPolicyTests: XCTestCase {

    private let shiftF3KeyCode = AppBehaviorPolicy.nativeCaseKeyCode
    private let shiftModifier = AppBehaviorPolicy.nativeCaseCarbonModifiers

    /// Native Shift-F3 Office apps. Outlook is deliberately excluded — it has
    /// no native Shift-F3 on Mac, so it has its own gated rule below.
    private let officeBundleIDs = [
        "com.microsoft.Word",
        "com.microsoft.Excel",
        "com.microsoft.Powerpoint",
        "com.microsoft.onenote.mac",
    ]

    func testOfficeAppsKeepTheirNativeShiftF3() {
        for bundleID in officeBundleIDs {
            XCTAssertTrue(
                AppBehaviorPolicy.shouldPassThroughCaseShortcut(
                    bundleID: bundleID,
                    keyCode: shiftF3KeyCode,
                    carbonModifiers: shiftModifier,
                    userConfiguredBundleIDs: [],
                    clipboardFallbackEnabled: false
                ),
                "\(bundleID) should receive Shift-F3 unchanged"
            )
        }
    }

    /// The regression this policy exists for: Office's claim is on Shift-F3,
    /// not on whatever the user rebinds to. Passing a rebound combination
    /// through would silently disable the feature in Office — Word has no
    /// ⌃⌥C command to run in our place.
    func testOfficeAppsDoNotSwallowAReboundShortcut() {
        for bundleID in officeBundleIDs {
            XCTAssertFalse(
                AppBehaviorPolicy.shouldPassThroughCaseShortcut(
                    bundleID: bundleID,
                    keyCode: 0x08,  // C
                    carbonModifiers: UInt32(controlKey | optionKey),
                    userConfiguredBundleIDs: [],
                    clipboardFallbackEnabled: false
                ),
                "\(bundleID) should not swallow a rebound case shortcut"
            )
        }
    }

    /// Same key, wrong modifiers, must not count as Office's shortcut.
    func testOfficeAppsDoNotSwallowF3WithOtherModifiers() {
        XCTAssertFalse(
            AppBehaviorPolicy.shouldPassThroughCaseShortcut(
                bundleID: "com.microsoft.Word",
                keyCode: shiftF3KeyCode,
                carbonModifiers: UInt32(controlKey),
                userConfiguredBundleIDs: [],
                clipboardFallbackEnabled: false
            )
        )
    }

    // MARK: - Outlook: web-backed, no native Shift-F3

    /// Outlook for Mac binds no Shift-F3 of its own (verified 2026-09-04), so
    /// there is nothing to defer to. While the clipboard fallback — the only
    /// path that can serve its compose body — is off, we still pass the key
    /// through so it is a silent no-op instead of a beep.
    func testOutlookPassesShiftF3ThroughWhenFallbackOff() {
        XCTAssertTrue(
            AppBehaviorPolicy.shouldPassThroughCaseShortcut(
                bundleID: "com.microsoft.Outlook",
                keyCode: shiftF3KeyCode,
                carbonModifiers: shiftModifier,
                userConfiguredBundleIDs: [],
                clipboardFallbackEnabled: false
            )
        )
    }

    /// With the fallback on we can serve Outlook, so claim the key — otherwise
    /// ⇧F3 would go on doing nothing in Outlook, which is the bug being fixed.
    func testOutlookClaimsShiftF3WhenFallbackOn() {
        XCTAssertFalse(
            AppBehaviorPolicy.shouldPassThroughCaseShortcut(
                bundleID: "com.microsoft.Outlook",
                keyCode: shiftF3KeyCode,
                carbonModifiers: shiftModifier,
                userConfiguredBundleIDs: [],
                clipboardFallbackEnabled: true
            )
        )
    }

    /// Outlook's gate is on "can we serve it", not on the chord: a rebound key
    /// it cannot handle either should also stay a silent no-op while the
    /// fallback is off.
    func testOutlookPassesAReboundShortcutThroughWhenFallbackOff() {
        XCTAssertTrue(
            AppBehaviorPolicy.shouldPassThroughCaseShortcut(
                bundleID: "com.microsoft.Outlook",
                keyCode: 0x08,  // C
                carbonModifiers: UInt32(controlKey | optionKey),
                userConfiguredBundleIDs: [],
                clipboardFallbackEnabled: false
            )
        )
    }

    /// The clipboard-fallback gate is Outlook-specific: enabling the fallback
    /// must not make Word start swallowing Shift-F3 to us — Word serves itself.
    func testFallbackOnDoesNotChangeNativeOfficeApps() {
        for bundleID in officeBundleIDs {
            XCTAssertTrue(
                AppBehaviorPolicy.shouldPassThroughCaseShortcut(
                    bundleID: bundleID,
                    keyCode: shiftF3KeyCode,
                    carbonModifiers: shiftModifier,
                    userConfiguredBundleIDs: [],
                    clipboardFallbackEnabled: true
                ),
                "\(bundleID) should still keep its native Shift-F3 with the fallback on"
            )
        }
    }

    /// The user-configured list means "we cannot serve this app at all", so it
    /// applies whatever combination is bound.
    func testConfiguredAppsPassThroughAnyShortcut() {
        XCTAssertTrue(
            AppBehaviorPolicy.shouldPassThroughCaseShortcut(
                bundleID: "com.microsoft.VSCode",
                keyCode: 0x08,
                carbonModifiers: UInt32(controlKey | optionKey),
                userConfiguredBundleIDs: ["com.microsoft.VSCode"],
                clipboardFallbackEnabled: false
            )
        )
    }

    func testConfiguredListIsAppliedInAdditionToOffice() {
        let configured: Set<String> = ["com.microsoft.VSCode"]
        XCTAssertTrue(
            AppBehaviorPolicy.shouldPassThroughCaseShortcut(
                bundleID: "com.microsoft.Powerpoint",
                keyCode: shiftF3KeyCode,
                carbonModifiers: shiftModifier,
                userConfiguredBundleIDs: configured,
                clipboardFallbackEnabled: false
            )
        )
        XCTAssertTrue(
            AppBehaviorPolicy.shouldPassThroughCaseShortcut(
                bundleID: "com.microsoft.VSCode",
                keyCode: shiftF3KeyCode,
                carbonModifiers: shiftModifier,
                userConfiguredBundleIDs: configured,
                clipboardFallbackEnabled: false
            )
        )
    }

    func testUnrelatedMicrosoftAppsAreNotTreatedAsOffice() {
        XCTAssertFalse(
            AppBehaviorPolicy.shouldPassThroughCaseShortcut(
                bundleID: "com.microsoft.edgemac",
                keyCode: shiftF3KeyCode,
                carbonModifiers: shiftModifier,
                userConfiguredBundleIDs: [],
                clipboardFallbackEnabled: false
            )
        )
    }

    func testUnknownAppNeverPassesThrough() {
        XCTAssertFalse(
            AppBehaviorPolicy.shouldPassThroughCaseShortcut(
                bundleID: nil,
                keyCode: shiftF3KeyCode,
                carbonModifiers: shiftModifier,
                userConfiguredBundleIDs: ["com.microsoft.VSCode"],
                clipboardFallbackEnabled: false
            )
        )
    }

    func testIsNativeCaseShortcut() {
        XCTAssertTrue(
            AppBehaviorPolicy.isNativeCaseShortcut(
                keyCode: shiftF3KeyCode, carbonModifiers: shiftModifier))
        XCTAssertFalse(
            AppBehaviorPolicy.isNativeCaseShortcut(
                keyCode: shiftF3KeyCode, carbonModifiers: 0))
    }

    // MARK: - Contextual-menu key

    /// Measured 2026-08-06: posting keycode 110 into Outlook's web-backed
    /// compose body selects the word ONE LINE BELOW the caret and opens the
    /// menu around it — caret at index 15 (line 0) became a selection of
    /// "ads" at 34..36, the last word of line 1, and moved down another line
    /// on the next press. The key is not inert there, so it must not be sent.
    func testOutlookWebContentDoesNotGetTheContextMenuKey() {
        XCTAssertFalse(
            AppBehaviorPolicy.shouldPostContextMenuKey(
                bundleID: "com.microsoft.Outlook",
                focusedElementIsWebContent: true
            )
        )
    }

    /// Outlook's native surfaces — message list, subject field — are where the
    /// key measurably works, and the 2026-07-28 log confirms it opens their
    /// menu. Only the web-backed body is excluded.
    func testOutlookNativeSurfacesKeepTheContextMenuKey() {
        XCTAssertTrue(
            AppBehaviorPolicy.shouldPostContextMenuKey(
                bundleID: "com.microsoft.Outlook",
                focusedElementIsWebContent: false
            )
        )
    }

    /// The exclusion is Outlook-specific on purpose: Mail's compose editor is
    /// WebKit too and behaves correctly today, so web content alone must not
    /// disqualify an app.
    func testOtherAppsKeepTheContextMenuKeyInWebContent() {
        for bundleID in ["com.apple.mail", "com.google.Chrome", "com.apple.TextEdit"] {
            XCTAssertTrue(
                AppBehaviorPolicy.shouldPostContextMenuKey(
                    bundleID: bundleID,
                    focusedElementIsWebContent: true
                ),
                "\(bundleID) should still be offered the contextual-menu key"
            )
        }
    }

    /// An unidentifiable app is not Outlook, so it keeps the default path.
    func testUnknownAppKeepsTheContextMenuKey() {
        XCTAssertTrue(
            AppBehaviorPolicy.shouldPostContextMenuKey(
                bundleID: nil, focusedElementIsWebContent: true))
    }

    // MARK: - Caret click button

    /// Owner report 2026-10-22: Outlook for Mac's compose body shows its
    /// spelling suggestions on a LEFT click on the word; a right-click there
    /// does not bring them up.
    func testOutlookWebContentGetsALeftClickAtTheCaret() {
        XCTAssertEqual(
            AppBehaviorPolicy.caretClickButton(
                bundleID: "com.microsoft.Outlook", focusedElementIsWebContent: true),
            .left)
    }

    /// Outlook's native surfaces keep the ordinary right-click.
    func testOutlookNativeSurfacesKeepTheRightClick() {
        XCTAssertEqual(
            AppBehaviorPolicy.caretClickButton(
                bundleID: "com.microsoft.Outlook", focusedElementIsWebContent: false),
            .right)
    }

    /// Everyone else, web content or not, keeps the right-click.
    func testOtherAppsKeepTheRightClick() {
        for bundleID: String? in ["com.apple.mail", "com.google.Chrome", nil] {
            XCTAssertEqual(
                AppBehaviorPolicy.caretClickButton(
                    bundleID: bundleID, focusedElementIsWebContent: true),
                .right, bundleID ?? "nil")
        }
    }
}
