import Foundation

public struct SessionMetricsReducer {
    public var metrics: DeviceSessionMetrics {
        DeviceSessionMetrics(
            currentReadBytesPerSecond: currentReadBytesPerSecond,
            currentWriteBytesPerSecond: currentWriteBytesPerSecond,
            cumulativeReadBytes: cumulativeReadBytes,
            cumulativeWriteBytes: cumulativeWriteBytes,
            readHistory: readHistory.orderedElements(),
            writeHistory: writeHistory.orderedElements()
        )
    }

    private var currentReadBytesPerSecond: Double = 0
    private var currentWriteBytesPerSecond: Double = 0
    private var cumulativeReadBytes: Int64 = 0
    private var cumulativeWriteBytes: Int64 = 0
    private var readHistory: BoundedRingBuffer<SpeedPoint>
    private var writeHistory: BoundedRingBuffer<SpeedPoint>
    private var lastDisplayTimestamp: Date?

    public init(historyLimit: Int) {
        let normalizedLimit = max(historyLimit, 0)
        self.readHistory = BoundedRingBuffer(capacity: normalizedLimit)
        self.writeHistory = BoundedRingBuffer(capacity: normalizedLimit)
    }

    public mutating func ingest(
        readBytes: Int64,
        writeBytes: Int64,
        tick: ThroughputSamplingTick
    ) {
        let normalizedReadBytes = max(readBytes, 0)
        let normalizedWriteBytes = max(writeBytes, 0)
        cumulativeReadBytes = saturatingAdd(
            cumulativeReadBytes,
            normalizedReadBytes
        )
        cumulativeWriteBytes = saturatingAdd(
            cumulativeWriteBytes,
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
            currentReadBytesPerSecond = 0
            currentWriteBytesPerSecond = 0
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

        currentReadBytesPerSecond = sample.readBytesPerSecond
        currentWriteBytesPerSecond = sample.writeBytesPerSecond
        readHistory.append(sample.readPoint)
        writeHistory.append(sample.writePoint)
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

private struct BoundedRingBuffer<Element> {
    private let capacity: Int
    private var storage: [Element] = []
    private var oldestIndex = 0

    init(capacity: Int) {
        self.capacity = capacity
    }

    mutating func append(_ element: Element) {
        guard capacity > 0 else { return }

        if storage.count < capacity {
            storage.append(element)
            return
        }

        storage[oldestIndex] = element
        oldestIndex = (oldestIndex + 1) % capacity
    }

    func orderedElements() -> [Element] {
        guard storage.isEmpty == false else { return [] }

        var elements: [Element] = []
        elements.reserveCapacity(storage.count)
        if storage.count == capacity {
            elements.append(contentsOf: storage[oldestIndex...])
            elements.append(contentsOf: storage[..<oldestIndex])
        } else {
            elements.append(contentsOf: storage)
        }
        return elements
    }
}
