import XCTest
@testable import DrivePulseApp

final class PanelPlaceholderTests: XCTestCase {
    func testMissingValuePlaceholderUsesHyphen() {
        XCTAssertEqual(PanelDisplayValue.missing, "-")
    }

    func testStringDisplayUsesHyphenForNilAndEmptyValues() {
        XCTAssertEqual(PanelDisplayValue.string(nil), "-")
        XCTAssertEqual(PanelDisplayValue.string(""), "-")
        XCTAssertEqual(PanelDisplayValue.string("disk5s1"), "disk5s1")
    }
}
