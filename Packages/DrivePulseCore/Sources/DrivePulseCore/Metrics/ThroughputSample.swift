import Foundation

/// Separates user-visible wall-clock labels from the monotonic interval used for rates.
public struct ThroughputSamplingTick: Equatable, Sendable {
    public let displayTimestamp: Date
    public let elapsedSincePrevious: Duration?

    public init(displayTimestamp: Date, elapsedSincePrevious: Duration?) {
        self.displayTimestamp = displayTimestamp
        self.elapsedSincePrevious = elapsedSincePrevious
    }
}

struct ThroughputSample {
    let timestamp: Date
    let readBytes: Int64
    let writeBytes: Int64
    let readBytesPerSecond: Double
    let writeBytesPerSecond: Double

    init(readBytes: Int64, writeBytes: Int64, at timestamp: Date, interval: TimeInterval?) {
        let rates = interval.map {
            (read: Double(readBytes) / $0, write: Double(writeBytes) / $0)
        } ?? (read: 0, write: 0)
        self.timestamp = timestamp
        self.readBytes = readBytes
        self.writeBytes = writeBytes
        self.readBytesPerSecond = rates.read.isFinite ? rates.read : Double.greatestFiniteMagnitude
        self.writeBytesPerSecond = rates.write.isFinite ? rates.write : Double.greatestFiniteMagnitude
    }

    var readPoint: SpeedPoint {
        .init(timestamp: timestamp, bytesPerSecond: readBytesPerSecond)
    }

    var writePoint: SpeedPoint {
        .init(timestamp: timestamp, bytesPerSecond: writeBytesPerSecond)
    }
}
