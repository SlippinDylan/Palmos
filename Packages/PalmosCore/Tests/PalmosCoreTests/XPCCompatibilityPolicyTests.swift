import XCTest
@testable import PalmosCore

final class XPCCompatibilityPolicyTests: XCTestCase {
    /// Representative values keep this pure policy test independent from the
    /// production XPC schema version owned by Shared/XPCContracts.
    private let representativeMajor = 1
    private let representativeMinor = 6

    func testMatchingHandshakeContractFieldsAreCompatible() {
        let result = evaluateCompatibility(
            helperHandshake: HelperHandshakePayload(
                helperVersion: "1.3.0",
                contractMajor: representativeMajor,
                contractMinor: representativeMinor
            )
        )

        XCTAssertEqual(result, .compatible)
    }

    func testNewerHandshakeMinorFieldRemainsCompatible() {
        let result = evaluateCompatibility(
            helperHandshake: HelperHandshakePayload(
                helperVersion: "1.4.0",
                contractMajor: representativeMajor,
                contractMinor: representativeMinor + 1
            )
        )

        XCTAssertEqual(result, .compatible)
    }

    func testNewerHandshakeMajorFieldRequiresUpdate() {
        let result = evaluateCompatibility(
            helperHandshake: HelperHandshakePayload(
                helperVersion: "2.0.0",
                contractMajor: representativeMajor + 1,
                contractMinor: 0
            )
        )

        XCTAssertEqual(result, .updateRequired)
    }

    func testOlderHandshakeMajorFieldRequiresUpdate() {
        let result = evaluateCompatibility(
            helperHandshake: HelperHandshakePayload(
                helperVersion: "0.9.0",
                contractMajor: representativeMajor - 1,
                contractMinor: 9
            )
        )

        XCTAssertEqual(result, .updateRequired)
    }

    func testOlderHandshakeMinorFieldDefaultsToDegradedCompatibility() {
        let result = evaluateCompatibility(
            helperHandshake: HelperHandshakePayload(
                helperVersion: "1.1.0",
                contractMajor: representativeMajor,
                contractMinor: 1
            )
        )

        XCTAssertEqual(result, .degraded)
    }

    func testHelperVersionStringDoesNotOverrideOlderContractMinorField() {
        let result = evaluateCompatibility(
            helperHandshake: HelperHandshakePayload(
                helperVersion: "9.9.9",
                contractMajor: representativeMajor,
                contractMinor: representativeMinor - 1
            )
        )

        XCTAssertEqual(result, .degraded)
    }

    func testCompletionAwareCompatibilityMatrixUsesOneMinorGate() {
        XCTAssertEqual(evaluate(appMinor: 3, helperMinor: 3), .compatible)
        XCTAssertEqual(evaluate(appMinor: 3, helperMinor: 4), .compatible)
        XCTAssertEqual(evaluate(appMinor: 4, helperMinor: 3), .degraded)
        XCTAssertEqual(evaluate(appMinor: 4, helperMinor: 4), .compatible)
    }

    private func evaluate(appMinor: Int, helperMinor: Int) -> XPCCompatibilityResult {
        XPCCompatibilityPolicy.evaluate(
            appMajor: representativeMajor,
            appMinor: appMinor,
            helperMajor: representativeMajor,
            helperMinor: helperMinor
        )
    }

    private func evaluateCompatibility(
        helperHandshake: HelperHandshakePayload
    ) -> XPCCompatibilityResult {
        XPCCompatibilityPolicy.evaluate(
            appMajor: representativeMajor,
            appMinor: representativeMinor,
            helperMajor: helperHandshake.contractMajor,
            helperMinor: helperHandshake.contractMinor
        )
    }
}

private struct HelperHandshakePayload {
    let helperVersion: String
    let contractMajor: Int
    let contractMinor: Int
}
