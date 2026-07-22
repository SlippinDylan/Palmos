import Foundation

public struct SessionMetricsReducer {
    public private(set) var metrics: DeviceSessionMetrics

    private let historyLimit: Int
    private var lastDisplayTimestamp: Date?

    public init(historyLimit: Int) {
        self.historyLimit = max(historyLimit, 0)
        self.metrics = .empty()
    }

    public mutating func ingest(
        readBytes: Int64,
        writeBytes: Int64,
        tick: ThroughputSamplingTick
    ) {
        let normalizedReadBytes = max(readBytes, 0)
        let normalizedWriteBytes = max(writeBytes, 0)
        metrics.cumulativeReadBytes = saturatingAdd(
            metrics.cumulativeReadBytes,
            normalizedReadBytes
        )
        metrics.cumulativeWriteBytes = saturatingAdd(
            metrics.cumulativeWriteBytes,
            normalizedWriteBytes
        )

        guard let lastDisplayTimestamp else {
            appendSample(
                readBytes: normalizedReadBytes,
                writeBytes: normalizedWriteBytes,
                timestamp: tick.displayTimestamp,
                interval: nil
            )
            self.lastDisplayTimestamp = tick.displayTimestamp
            return
        }

        guard let interval = Self.positiveSeconds(from: tick.elapsedSincePrevious) else {
            metrics.currentReadBytesPerSecond = 0
            metrics.currentWriteBytesPerSecond = 0
            return
        }

        let timestamp = lastDisplayTimestamp.addingTimeInterval(interval)
        appendSample(
            readBytes: normalizedReadBytes,
            writeBytes: normalizedWriteBytes,
            timestamp: timestamp,
            interval: interval
        )
        self.lastDisplayTimestamp = timestamp
    }

    private mutating func appendSample(
        readBytes: Int64,
        writeBytes: Int64,
        timestamp: Date,
        interval: TimeInterval?
    ) {
        let sample = ThroughputSample(
            readBytes: readBytes,
            writeBytes: writeBytes,
            at: timestamp,
            interval: interval
        )

        metrics.currentReadBytesPerSecond = sample.readBytesPerSecond
        metrics.currentWriteBytesPerSecond = sample.writeBytesPerSecond
        metrics.readHistory.append(sample.readPoint)
        metrics.writeHistory.append(sample.writePoint)
        metrics.readHistory = Array(metrics.readHistory.suffix(historyLimit))
        metrics.writeHistory = Array(metrics.writeHistory.suffix(historyLimit))
    }

    private static func positiveSeconds(from duration: Duration?) -> TimeInterval? {
        guard let duration, duration > .zero else {
            return nil
        }

        let components = duration.components
        let seconds = TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    private func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? .max : result.partialValue
    }
}
