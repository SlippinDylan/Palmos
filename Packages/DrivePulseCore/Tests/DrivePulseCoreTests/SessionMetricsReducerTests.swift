import XCTest
@testable import DrivePulseCore

final class SessionMetricsReducerTests: XCTestCase {
    func testNewSessionStartsWithZeroedCumulativeCounters() {
        let metrics = DeviceSessionMetrics.empty(historyLimit: 60)
        XCTAssertEqual(metrics.cumulativeReadBytes, 0)
        XCTAssertEqual(metrics.cumulativeWriteBytes, 0)
        XCTAssertEqual(metrics.readHistory.count, 0)
        XCTAssertEqual(metrics.writeHistory.count, 0)
    }
}
