import XCTest
@testable import DrivePulseApp

import DrivePulseCore

final class OverviewCardViewTests: XCTestCase {
    func testRowsExcludeSmartWearAndTemperatureFields() {
        let rows = OverviewCardView.rows(
            for: ExternalDevice.preview(id: "disk4"),
            smartDetails: nil,
            settings: AppSettings()
        )

        XCTAssertEqual(
            rows.map(\.label),
            [
                "Model",
                "Connection",
                "Total Capacity",
                "Used",
                "Available",
                "File System",
                "Mounted"
            ]
        )
    }
}
