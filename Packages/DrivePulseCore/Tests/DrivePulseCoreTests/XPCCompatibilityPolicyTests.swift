import XCTest
@testable import DrivePulseCore

final class XPCCompatibilityPolicyTests: XCTestCase {
    func testMatchingMajorAndMinorIsCompatible() {
        let result = XPCCompatibilityPolicy.evaluate(
            appMajor: 1,
            appMinor: 3,
            helperMajor: 1,
            helperMinor: 3
        )

        XCTAssertEqual(result, .compatible)
    }

    func testNewerHelperMinorVersionRemainsCompatible() {
        let result = XPCCompatibilityPolicy.evaluate(
            appMajor: 1,
            appMinor: 3,
            helperMajor: 1,
            helperMinor: 4
        )

        XCTAssertEqual(result, .compatible)
    }

    func testMajorMismatchRequiresUpdate() {
        let result = XPCCompatibilityPolicy.evaluate(
            appMajor: 1,
            appMinor: 3,
            helperMajor: 2,
            helperMinor: 0
        )

        XCTAssertEqual(result, .updateRequired)
    }

    func testMinorMismatchDefaultsToDegradedCompatibility() {
        let result = XPCCompatibilityPolicy.evaluate(
            appMajor: 1,
            appMinor: 3,
            helperMajor: 1,
            helperMinor: 1
        )

        XCTAssertEqual(result, .degraded)
    }
}
