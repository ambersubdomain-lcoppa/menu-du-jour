import XCTest
@testable import MenuDuJourCore

final class WebMenuRequestTests: XCTestCase {

    /// Office editors run in their own frame on officeapps.live.com even when
    /// the address bar shows SharePoint (probe 2026-09-28:
    /// powerpoint.officeapps.live.com inside msasafety.sharepoint.com).
    func testOfficeEditorFramesUseShiftF10() {
        for host in ["powerpoint.officeapps.live.com", "word-edit.officeapps.live.com",
                     "excel.officeapps.live.com", "officeapps.live.com",
                     "PowerPoint.OfficeApps.Live.com"] {
            XCTAssertEqual(AppBehaviorPolicy.menuRequest(forWebPageHost: host), .shiftF10, host)
            XCTAssertFalse(AppBehaviorPolicy.mayClickAfterFailedMenuRequest(webPageHost: host), host)
        }
    }

    func testOtherPagesKeepTheContextMenuKeyAndTheClickFallback() {
        for host in [nil, "msasafety.sharepoint.com", "www.office.com", "mail.google.com", ""] as [String?] {
            XCTAssertEqual(AppBehaviorPolicy.menuRequest(forWebPageHost: host), .contextMenuKey, host ?? "nil")
            XCTAssertTrue(AppBehaviorPolicy.mayClickAfterFailedMenuRequest(webPageHost: host), host ?? "nil")
        }
    }

    /// Suffix match on a label boundary only: a look-alike domain must not get
    /// synthetic Shift+F10.
    func testLookAlikeHostsDoNotMatch() {
        for host in ["evilofficeapps.live.com", "officeapps.live.com.evil.example", "live.com"] {
            XCTAssertEqual(AppBehaviorPolicy.menuRequest(forWebPageHost: host), .contextMenuKey, host)
        }
    }
}
