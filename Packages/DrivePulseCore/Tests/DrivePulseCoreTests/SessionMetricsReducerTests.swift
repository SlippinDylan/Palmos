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

    func testSessionReducerAccumulatesPerConnectionTotals() {
        var reducer = SessionMetricsReducer(historyLimit: 3)
        let distantPast = Date(timeIntervalSince1970: 1_000)
        let now = Date(timeIntervalSince1970: 1_060)

        reducer.ingest(readBytes: 100, writeBytes: 50, at: distantPast)
        reducer.ingest(readBytes: 25, writeBytes: 75, at: now)

        XCTAssertEqual(reducer.metrics.cumulativeReadBytes, 125)
        XCTAssertEqual(reducer.metrics.cumulativeWriteBytes, 125)
        XCTAssertEqual(reducer.metrics.readHistory.count, 2)
        XCTAssertEqual(reducer.metrics.writeHistory.count, 2)
        XCTAssertEqual(reducer.metrics.readHistory.last?.bytesPerSecond ?? -1, 25.0 / 60.0, accuracy: 0.0001)
        XCTAssertEqual(reducer.metrics.writeHistory.last?.bytesPerSecond ?? -1, 75.0 / 60.0, accuracy: 0.0001)
    }

    func testSessionReducerTrimsHistoryToHistoryLimit() {
        var reducer = SessionMetricsReducer(historyLimit: 2)
        let timestamps = [
            Date(timeIntervalSince1970: 1_000),
            Date(timeIntervalSince1970: 1_010),
            Date(timeIntervalSince1970: 1_020)
        ]

        reducer.ingest(readBytes: 10, writeBytes: 20, at: timestamps[0])
        reducer.ingest(readBytes: 30, writeBytes: 40, at: timestamps[1])
        reducer.ingest(readBytes: 50, writeBytes: 60, at: timestamps[2])

        XCTAssertEqual(reducer.metrics.readHistory.count, 2)
        XCTAssertEqual(reducer.metrics.writeHistory.count, 2)
        XCTAssertEqual(reducer.metrics.readHistory.map(\.timestamp), Array(timestamps.suffix(2)))
        XCTAssertEqual(reducer.metrics.writeHistory.map(\.timestamp), Array(timestamps.suffix(2)))
    }

    func testSessionReducerTrimsHistoryToSixtySamplesForLongRunningSession() {
        var reducer = SessionMetricsReducer(historyLimit: 60)
        let timestamps = (0..<61).map { Date(timeIntervalSince1970: 10_000 + Double($0)) }

        for (index, timestamp) in timestamps.enumerated() {
            reducer.ingest(
                readBytes: Int64(index + 1),
                writeBytes: Int64((index + 1) * 2),
                at: timestamp
            )
        }

        XCTAssertEqual(reducer.metrics.readHistory.count, 60)
        XCTAssertEqual(reducer.metrics.writeHistory.count, 60)
        XCTAssertEqual(reducer.metrics.readHistory.first?.timestamp, timestamps[1])
        XCTAssertEqual(reducer.metrics.readHistory.last?.timestamp, timestamps[60])
        XCTAssertEqual(reducer.metrics.writeHistory.first?.timestamp, timestamps[1])
        XCTAssertEqual(reducer.metrics.writeHistory.last?.timestamp, timestamps[60])
    }

    func testSessionReducerCalculatesThroughputUsingSubsecondIntervals() {
        var reducer = SessionMetricsReducer(historyLimit: 3)
        let start = Date(timeIntervalSince1970: 2_000)
        let end = Date(timeIntervalSince1970: 2_000.25)

        reducer.ingest(readBytes: 100, writeBytes: 50, at: start)
        reducer.ingest(readBytes: 25, writeBytes: 75, at: end)

        XCTAssertEqual(reducer.metrics.currentReadBytesPerSecond, 100, accuracy: 0.0001)
        XCTAssertEqual(reducer.metrics.currentWriteBytesPerSecond, 300, accuracy: 0.0001)
    }

    func testSessionReducerCopiesWithoutSharingState() {
        let timestamp = Date(timeIntervalSince1970: 3_000)
        let nextTimestamp = Date(timeIntervalSince1970: 3_010)
        var original = SessionMetricsReducer(historyLimit: 3)
        var copy = original

        copy.ingest(readBytes: 100, writeBytes: 50, at: timestamp)
        original.ingest(readBytes: 10, writeBytes: 20, at: nextTimestamp)

        XCTAssertEqual(copy.metrics.cumulativeReadBytes, 100)
        XCTAssertEqual(copy.metrics.cumulativeWriteBytes, 50)
        XCTAssertEqual(original.metrics.cumulativeReadBytes, 10)
        XCTAssertEqual(original.metrics.cumulativeWriteBytes, 20)
    }
}
