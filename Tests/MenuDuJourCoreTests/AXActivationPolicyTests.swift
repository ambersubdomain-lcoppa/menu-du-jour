import ApplicationServices
import XCTest
@testable import MenuDuJourCore

final class AXActivationPolicyTests: XCTestCase {

    /// The app implements the attribute and took it. Never ask again.
    func testSuccessIsSettled() {
        XCTAssertFalse(AXActivationPolicy.shouldRetry(after: .success))
    }

    /// The regression this policy exists for: AXManualAccessibility is now
    /// attempted on every app, and a native app answers attributeUnsupported
    /// permanently. Retrying that on every activation *and* every hotkey press
    /// spends the process-wide AX messaging timeout for an answer that cannot
    /// change.
    func testPermanentRefusalsAreSettled() {
        XCTAssertFalse(AXActivationPolicy.shouldRetry(after: .attributeUnsupported))
        XCTAssertFalse(AXActivationPolicy.shouldRetry(after: .actionUnsupported))
        XCTAssertFalse(AXActivationPolicy.shouldRetry(after: .notImplemented))
        XCTAssertFalse(AXActivationPolicy.shouldRetry(after: .illegalArgument))
    }

    /// The guarantee from the 2026-07-10 F6 verification must survive: a
    /// browser that was still launching has to be retried, or its first-query
    /// race is never resolved for that process.
    func testTransientFailuresAreRetried() {
        XCTAssertTrue(AXActivationPolicy.shouldRetry(after: .cannotComplete))
        XCTAssertTrue(AXActivationPolicy.shouldRetry(after: .apiDisabled))
        XCTAssertTrue(AXActivationPolicy.shouldRetry(after: .notEnoughPrecision))
    }

    /// An invalid element means the process went away; a recycled PID is a
    /// different app that deserves its own attempt.
    func testInvalidElementIsRetried() {
        XCTAssertTrue(AXActivationPolicy.shouldRetry(after: .invalidUIElement))
    }

    /// Unknown codes retry: the cost is one AX call, the cost of wrongly
    /// settling is a permanently un-nudged app.
    func testUnknownErrorsAreRetried() {
        XCTAssertTrue(AXActivationPolicy.shouldRetry(after: AXError(rawValue: -12345)!))
    }
}
