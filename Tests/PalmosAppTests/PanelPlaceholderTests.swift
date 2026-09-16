import XCTest
@testable import PalmosApp

import SwiftUI

@MainActor
final class PanelPlaceholderTests: XCTestCase {
    func testMissingValuePlaceholderUsesHyphen() {
        XCTAssertEqual(PanelDisplayValue.missing, "-")
    }

    func testStringDisplayUsesHyphenForNilAndEmptyValues() {
        XCTAssertEqual(PanelDisplayValue.string(nil), "-")
        XCTAssertEqual(PanelDisplayValue.string(""), "-")
        XCTAssertEqual(PanelDisplayValue.string("disk5s1"), "disk5s1")
    }

    func testPanelSectionSupportsPlainAndAccessoryHeaders() {
        let plainSection = PanelSection("Plain") {
            Text("Content")
        }
        let accessorySection = PanelSection("With Accessory") {
            ProgressView()
        } content: {
            Text("Content")
        }

        XCTAssertEqual(
            String(reflecting: Mirror(reflecting: plainSection.headerAccessory).subjectType),
            String(reflecting: EmptyView.self)
        )
        XCTAssertEqual(
            String(reflecting: Mirror(reflecting: accessorySection.headerAccessory).subjectType),
            String(reflecting: ProgressView<EmptyView, EmptyView>.self)
        )
    }
}
