import XCTest
@testable import PalmosCore

final class SessionMetricsReducerTests: XCTestCase {
    func testNewSessionStartsWithZeroedCumulativeCounters() {
        let metrics = DeviceSessionMetrics.empty()
        XCTAssertEqual(metrics.cumulativeReadBytes, 0)
        XCTAssertEqual(metrics.cumulativeWriteBytes, 0)
        XCTAssertEqual(metrics.readHistory.count, 0)
        XCTAssertEqual(metrics.writeHistory.count, 0)
    }

    func testSessionReducerAccumulatesPerConnectionTotals() {
        var reducer = SessionMetricsReducer(historyLimit: 3)
        let distantPast = Date(timeIntervalSince1970: 1_000)
        let now = Date(timeIntervalSince1970: 1_060)

        reducer.ingest(readBytes: 100, writeBytes: 50, tick: tick(distantPast))
        reducer.ingest(readBytes: 25, writeBytes: 75, tick: tick(now, elapsed: .seconds(60)))

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

        reducer.ingest(readBytes: 10, writeBytes: 20, tick: tick(timestamps[0]))
        reducer.ingest(readBytes: 30, writeBytes: 40, tick: tick(timestamps[1], elapsed: .seconds(10)))
        reducer.ingest(readBytes: 50, writeBytes: 60, tick: tick(timestamps[2], elapsed: .seconds(10)))

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
                tick: tick(timestamp, elapsed: index == 0 ? nil : .seconds(1))
            )
        }

        XCTAssertEqual(reducer.metrics.readHistory.count, 60)
        XCTAssertEqual(reducer.metrics.writeHistory.count, 60)
        XCTAssertEqual(reducer.metrics.readHistory.first?.timestamp, timestamps[1])
        XCTAssertEqual(reducer.metrics.readHistory.last?.timestamp, timestamps[60])
        XCTAssertEqual(reducer.metrics.writeHistory.first?.timestamp, timestamps[1])
        XCTAssertEqual(reducer.metrics.writeHistory.last?.timestamp, timestamps[60])
    }

    func testSessionReducerPreservesChronologicalOrderAcrossMultipleRingWraps() {
        var reducer = SessionMetricsReducer(historyLimit: 3)
        let timestamps = (0..<10).map { Date(timeIntervalSince1970: 20_000 + Double($0)) }

        for (index, timestamp) in timestamps.enumerated() {
            reducer.ingest(
                readBytes: Int64(index),
                writeBytes: Int64(index * 2),
                tick: tick(timestamp, elapsed: index == 0 ? nil : .seconds(1))
            )
        }

        XCTAssertEqual(reducer.metrics.readHistory.map(\.timestamp), Array(timestamps.suffix(3)))
        XCTAssertEqual(reducer.metrics.writeHistory.map(\.timestamp), Array(timestamps.suffix(3)))
    }

    func testMetricsSnapshotDoesNotChangeWhenRingBufferWrapsLater() {
        var reducer = SessionMetricsReducer(historyLimit: 2)
        let timestamps = (0..<3).map { Date(timeIntervalSince1970: 30_000 + Double($0)) }

        reducer.ingest(readBytes: 10, writeBytes: 20, tick: tick(timestamps[0]))
        reducer.ingest(readBytes: 30, writeBytes: 40, tick: tick(timestamps[1], elapsed: .seconds(1)))
        let snapshot = reducer.metrics

        reducer.ingest(readBytes: 50, writeBytes: 60, tick: tick(timestamps[2], elapsed: .seconds(1)))

        XCTAssertEqual(snapshot.readHistory.map(\.timestamp), Array(timestamps.prefix(2)))
        XCTAssertEqual(snapshot.writeHistory.map(\.timestamp), Array(timestamps.prefix(2)))
        XCTAssertEqual(reducer.metrics.readHistory.map(\.timestamp), Array(timestamps.suffix(2)))
        XCTAssertEqual(reducer.metrics.writeHistory.map(\.timestamp), Array(timestamps.suffix(2)))
    }

    func testZeroHistoryLimitStillUpdatesCurrentAndCumulativeMetrics() {
        var reducer = SessionMetricsReducer(historyLimit: 0)
        let start = Date(timeIntervalSince1970: 40_000)

        reducer.ingest(readBytes: 10, writeBytes: 20, tick: tick(start))
        reducer.ingest(readBytes: 30, writeBytes: 40, tick: tick(start, elapsed: .seconds(2)))

        XCTAssertEqual(reducer.metrics.currentReadBytesPerSecond, 15)
        XCTAssertEqual(reducer.metrics.currentWriteBytesPerSecond, 20)
        XCTAssertEqual(reducer.metrics.cumulativeReadBytes, 40)
        XCTAssertEqual(reducer.metrics.cumulativeWriteBytes, 60)
        XCTAssertTrue(reducer.metrics.readHistory.isEmpty)
        XCTAssertTrue(reducer.metrics.writeHistory.isEmpty)
    }

    func testSessionReducerCalculatesThroughputUsingSubsecondIntervals() {
        var reducer = SessionMetricsReducer(historyLimit: 3)
        let start = Date(timeIntervalSince1970: 2_000)
        let end = Date(timeIntervalSince1970: 2_000.25)

        reducer.ingest(readBytes: 100, writeBytes: 50, tick: tick(start))
        reducer.ingest(readBytes: 25, writeBytes: 75, tick: tick(end, elapsed: .milliseconds(250)))

        XCTAssertEqual(reducer.metrics.currentReadBytesPerSecond, 100, accuracy: 0.0001)
        XCTAssertEqual(reducer.metrics.currentWriteBytesPerSecond, 300, accuracy: 0.0001)
    }

    func testWallClockRollbackUsesMonotonicElapsedForRateAndChartTimestamp() throws {
        var reducer = SessionMetricsReducer(historyLimit: 3)
        let sessionOrigin = Date(timeIntervalSince1970: 2_000)

        reducer.ingest(
            readBytes: 0,
            writeBytes: 0,
            tick: ThroughputSamplingTick(
                displayTimestamp: sessionOrigin,
                elapsedSincePrevious: nil
            )
        )
        reducer.ingest(
            readBytes: 100,
            writeBytes: 50,
            tick: ThroughputSamplingTick(
                displayTimestamp: Date(timeIntervalSince1970: 1_000),
                elapsedSincePrevious: .seconds(2)
            )
        )

        XCTAssertEqual(reducer.metrics.currentReadBytesPerSecond, 50, accuracy: 0.0001)
        XCTAssertEqual(reducer.metrics.currentWriteBytesPerSecond, 25, accuracy: 0.0001)
        XCTAssertEqual(
            try XCTUnwrap(reducer.metrics.readHistory.last?.timestamp),
            sessionOrigin.addingTimeInterval(2)
        )
        XCTAssertEqual(
            reducer.metrics.readHistory.map(\.timestamp),
            reducer.metrics.readHistory.map(\.timestamp).sorted()
        )
    }

    func testUnchangedWallClockUsesPositiveMonotonicElapsedForRate() throws {
        var reducer = SessionMetricsReducer(historyLimit: 3)
        let wallClockTimestamp = Date(timeIntervalSince1970: 3_000)

        reducer.ingest(
            readBytes: 0,
            writeBytes: 0,
            tick: ThroughputSamplingTick(
                displayTimestamp: wallClockTimestamp,
                elapsedSincePrevious: nil
            )
        )
        reducer.ingest(
            readBytes: 75,
            writeBytes: 25,
            tick: ThroughputSamplingTick(
                displayTimestamp: wallClockTimestamp,
                elapsedSincePrevious: .milliseconds(250)
            )
        )

        XCTAssertEqual(reducer.metrics.currentReadBytesPerSecond, 300, accuracy: 0.0001)
        XCTAssertEqual(reducer.metrics.currentWriteBytesPerSecond, 100, accuracy: 0.0001)
        XCTAssertEqual(
            try XCTUnwrap(reducer.metrics.readHistory.last?.timestamp),
            wallClockTimestamp.addingTimeInterval(0.25)
        )
    }

    func testNonPositiveElapsedDoesNotCreateRateSpikeOrPolluteChartBaseline() throws {
        var reducer = SessionMetricsReducer(historyLimit: 4)
        let sessionOrigin = Date(timeIntervalSince1970: 4_000)

        reducer.ingest(
            readBytes: 0,
            writeBytes: 0,
            tick: ThroughputSamplingTick(
                displayTimestamp: sessionOrigin,
                elapsedSincePrevious: nil
            )
        )
        reducer.ingest(
            readBytes: 100,
            writeBytes: 50,
            tick: ThroughputSamplingTick(
                displayTimestamp: sessionOrigin,
                elapsedSincePrevious: .zero
            )
        )
        reducer.ingest(
            readBytes: 200,
            writeBytes: 100,
            tick: ThroughputSamplingTick(
                displayTimestamp: sessionOrigin.addingTimeInterval(-10),
                elapsedSincePrevious: .milliseconds(-250)
            )
        )

        XCTAssertEqual(reducer.metrics.currentReadBytesPerSecond, 0)
        XCTAssertEqual(reducer.metrics.currentWriteBytesPerSecond, 0)
        XCTAssertEqual(reducer.metrics.readHistory.count, 1)
        XCTAssertEqual(reducer.metrics.cumulativeReadBytes, 300)
        XCTAssertEqual(reducer.metrics.cumulativeWriteBytes, 150)

        reducer.ingest(
            readBytes: 25,
            writeBytes: 10,
            tick: ThroughputSamplingTick(
                displayTimestamp: sessionOrigin,
                elapsedSincePrevious: .milliseconds(250)
            )
        )

        XCTAssertEqual(reducer.metrics.currentReadBytesPerSecond, 100, accuracy: 0.0001)
        XCTAssertEqual(reducer.metrics.currentWriteBytesPerSecond, 40, accuracy: 0.0001)
        XCTAssertEqual(
            try XCTUnwrap(reducer.metrics.readHistory.last?.timestamp),
            sessionOrigin.addingTimeInterval(0.25)
        )
    }

    func testFirstSampleDoesNotAssumeOneSecondInterval() {
        var reducer = SessionMetricsReducer(historyLimit: 3)

        reducer.ingest(
            readBytes: 100,
            writeBytes: 50,
            tick: tick(Date(timeIntervalSince1970: 2_000))
        )

        XCTAssertEqual(reducer.metrics.currentReadBytesPerSecond, 0)
        XCTAssertEqual(reducer.metrics.currentWriteBytesPerSecond, 0)
    }

    func testSessionReducerCopiesWithoutSharingState() {
        let timestamp = Date(timeIntervalSince1970: 3_000)
        let nextTimestamp = Date(timeIntervalSince1970: 3_010)
        var original = SessionMetricsReducer(historyLimit: 3)
        var copy = original

        copy.ingest(readBytes: 100, writeBytes: 50, tick: tick(timestamp))
        original.ingest(readBytes: 10, writeBytes: 20, tick: tick(nextTimestamp))

        XCTAssertEqual(copy.metrics.cumulativeReadBytes, 100)
        XCTAssertEqual(copy.metrics.cumulativeWriteBytes, 50)
        XCTAssertEqual(original.metrics.cumulativeReadBytes, 10)
        XCTAssertEqual(original.metrics.cumulativeWriteBytes, 20)
    }

    func testSessionReducerIgnoresNegativeCounterDeltas() {
        var reducer = SessionMetricsReducer(historyLimit: 3)
        let start = Date(timeIntervalSince1970: 4_000)
        let end = Date(timeIntervalSince1970: 4_001)

        reducer.ingest(readBytes: 100, writeBytes: 50, tick: tick(start))
        reducer.ingest(readBytes: -25, writeBytes: -10, tick: tick(end, elapsed: .seconds(1)))

        XCTAssertEqual(reducer.metrics.cumulativeReadBytes, 100)
        XCTAssertEqual(reducer.metrics.cumulativeWriteBytes, 50)
        XCTAssertEqual(reducer.metrics.currentReadBytesPerSecond, 0)
        XCTAssertEqual(reducer.metrics.currentWriteBytesPerSecond, 0)
    }

    func testSessionReducerSaturatesCumulativeCountersOnOverflow() {
        var reducer = SessionMetricsReducer(historyLimit: 3)
        let start = Date(timeIntervalSince1970: 5_000)
        let end = Date(timeIntervalSince1970: 5_001)

        reducer.ingest(readBytes: Int64.max, writeBytes: Int64.max, tick: tick(start))
        reducer.ingest(readBytes: 1, writeBytes: 1, tick: tick(end, elapsed: .seconds(1)))

        XCTAssertEqual(reducer.metrics.cumulativeReadBytes, Int64.max)
        XCTAssertEqual(reducer.metrics.cumulativeWriteBytes, Int64.max)
    }

    private func tick(
        _ displayTimestamp: Date,
        elapsed: Duration? = nil
    ) -> ThroughputSamplingTick {
        ThroughputSamplingTick(
            displayTimestamp: displayTimestamp,
            elapsedSincePrevious: elapsed
        )
    }
}
