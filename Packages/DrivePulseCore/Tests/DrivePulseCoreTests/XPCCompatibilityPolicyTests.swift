import XCTest
@testable import DrivePulseCore

final class XPCCompatibilityPolicyTests: XCTestCase {
    private let appContractMajor = 1
    private let appContractMinor = 3

    func testMatchingHandshakeContractFieldsAreCompatible() {
        let result = evaluateCompatibility(
            helperHandshake: HelperHandshakePayload(
                helperVersion: "1.3.0",
                contractMajor: 1,
                contractMinor: 3
            )
        )

        XCTAssertEqual(result, .compatible)
    }

    func testNewerHandshakeMinorFieldRemainsCompatible() {
        let result = evaluateCompatibility(
            helperHandshake: HelperHandshakePayload(
                helperVersion: "1.4.0",
                contractMajor: 1,
                contractMinor: 4
            )
        )

        XCTAssertEqual(result, .compatible)
    }

    func testNewerHandshakeMajorFieldRequiresUpdate() {
        let result = evaluateCompatibility(
            helperHandshake: HelperHandshakePayload(
                helperVersion: "2.0.0",
                contractMajor: 2,
                contractMinor: 0
            )
        )

        XCTAssertEqual(result, .updateRequired)
    }

    func testOlderHandshakeMajorFieldRequiresUpdate() {
        let result = evaluateCompatibility(
            helperHandshake: HelperHandshakePayload(
                helperVersion: "0.9.0",
                contractMajor: 0,
                contractMinor: 9
            )
        )

        XCTAssertEqual(result, .updateRequired)
    }

    func testOlderHandshakeMinorFieldDefaultsToDegradedCompatibility() {
        let result = evaluateCompatibility(
            helperHandshake: HelperHandshakePayload(
                helperVersion: "1.1.0",
                contractMajor: 1,
                contractMinor: 1
            )
        )

        XCTAssertEqual(result, .degraded)
    }

    func testHelperVersionStringDoesNotOverrideOlderContractMinorField() {
        let result = evaluateCompatibility(
            helperHandshake: HelperHandshakePayload(
                helperVersion: "9.9.9",
                contractMajor: 1,
                contractMinor: 1
            )
        )

        XCTAssertEqual(result, .degraded)
    }

    private func evaluateCompatibility(
        helperHandshake: HelperHandshakePayload
    ) -> XPCCompatibilityResult {
        XPCCompatibilityPolicy.evaluate(
            appMajor: appContractMajor,
            appMinor: appContractMinor,
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
