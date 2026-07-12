import DiskArbitration
import XCTest
@testable import DrivePulseApp

final class DiskArbitrationErrorClassifierTests: XCTestCase {
    private let classifier = DiskArbitrationErrorClassifier()

    func testClassifiesDiskArbitrationStatusesExplicitly() {
        XCTAssertEqual(classifier.classify(DAReturn(kDAReturnBusy)), .busy)
        XCTAssertEqual(classifier.classify(DAReturn(kDAReturnExclusiveAccess)), .exclusiveAccess)
        XCTAssertEqual(classifier.classify(DAReturn(kDAReturnNotPermitted)), .notPermitted)
        XCTAssertEqual(classifier.classify(DAReturn(kDAReturnNotPrivileged)), .notPermitted)
        XCTAssertEqual(classifier.classify(DAReturn(kDAReturnNotReady)), .notReady)
        XCTAssertEqual(classifier.classify(DAReturn(kDAReturnNotFound)), .notFound)
        XCTAssertEqual(classifier.classify(DAReturn(kDAReturnNotMounted)), .notMounted)
        XCTAssertEqual(classifier.classify(DAReturn(kDAReturnError)), .io)
    }

    func testClassifiesOnlyMachEncodedUnixBusyAsBusy() {
        XCTAssertEqual(classifier.classify(DAReturn(bitPattern: 0x0000_C010)), .busy)
        XCTAssertEqual(classifier.unixErrno(from: DAReturn(bitPattern: 0x0000_C010)), 16)
        XCTAssertEqual(classifier.classify(DAReturn(bitPattern: 0x0000_C00D)), .unknown)
        XCTAssertEqual(classifier.classify(DAReturn(bitPattern: 0x0000_8010)), .unknown)
    }

    func testUnknownStatusRemainsUnknown() {
        XCTAssertEqual(classifier.classify(DAReturn(bitPattern: 0x1234_5678)), .unknown)
        XCTAssertNil(classifier.unixErrno(from: DAReturn(bitPattern: 0x1234_5678)))
    }

    func testCapturedUnixBusyFixtureDocumentsDecodedFields() throws {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "unix-ebusy-status", withExtension: "json")
        )
        let fixture = try JSONDecoder().decode(StatusFixture.self, from: Data(contentsOf: url))

        XCTAssertEqual(fixture.signedStatus, 49_168)
        XCTAssertEqual(fixture.hexStatus, "0x0000C010")
        XCTAssertEqual(fixture.machSystem, 0)
        XCTAssertEqual(fixture.machSubsystem, 3)
        XCTAssertEqual(fixture.unixErrno, 16)
        XCTAssertEqual(fixture.expectedCategory, "busy")
        let fields = classifier.machFields(from: DAReturn(fixture.signedStatus))
        XCTAssertEqual(fields.system, fixture.machSystem)
        XCTAssertEqual(fields.subsystem, fixture.machSubsystem)
        XCTAssertEqual(fields.code, fixture.unixErrno)
        XCTAssertEqual(classifier.classify(DAReturn(fixture.signedStatus)), .busy)
        XCTAssertEqual(classifier.unixErrno(from: DAReturn(fixture.signedStatus)), fixture.unixErrno)
    }
}

private struct StatusFixture: Decodable {
    let signedStatus: Int32
    let hexStatus: String
    let machSystem: Int32
    let machSubsystem: Int32
    let unixErrno: Int32
    let expectedCategory: String
}
