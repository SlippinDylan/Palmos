import Combine
import Foundation

import DrivePulseCore

@MainActor
final class ThroughputMetricsStore: ObservableObject {
    private struct CounterBaseline {
        let physicalBSDName: String
        let counters: DiskIOCounters
    }

    @Published private(set) var metricsByDeviceID: [DeviceID: DeviceSessionMetrics] = [:]

    private let historyLimit: Int
    private let minimumPublishInterval: TimeInterval
    private var counterBaselinesByDeviceID: [DeviceID: CounterBaseline] = [:]
    private var reducersByDeviceID: [DeviceID: SessionMetricsReducer] = [:]
    private var isPanelPresented: Bool
    private var shouldPublishNextSample: Bool
    private var lastPublishTimestamp: Date?

    init(
        historyLimit: Int = 300,
        maximumPublishFrequency: Double = 2,
        isPanelPresented: Bool = true
    ) {
        self.historyLimit = historyLimit
        self.minimumPublishInterval = maximumPublishFrequency > 0
            ? 1 / maximumPublishFrequency
            : .infinity
        self.isPanelPresented = isPanelPresented
        self.shouldPublishNextSample = isPanelPresented
    }

    func metrics(for deviceID: DeviceID) -> DeviceSessionMetrics? {
        metricsByDeviceID[deviceID]
    }

    func setPanelPresented(_ isPresented: Bool) {
        guard isPresented != isPanelPresented else { return }
        isPanelPresented = isPresented
        if isPresented {
            shouldPublishNextSample = true
        }
    }

    func resetCounterBaseline(for deviceID: DeviceID) {
        counterBaselinesByDeviceID.removeValue(forKey: deviceID)
    }

    func ingest(
        _ result: ThroughputSamplingResult,
        for snapshot: ThroughputSamplingSnapshot
    ) {
        let acceptedSamples = ThroughputSamplingResultGate.acceptedSamples(
            result,
            for: snapshot
        )
        guard acceptedSamples.isEmpty == false else { return }

        for sample in acceptedSamples {
            ingest(sample, tick: result.tick)
        }

        guard shouldPublish(at: result.tick.displayTimestamp) else { return }
        publishMetrics(at: result.tick.displayTimestamp)
    }

    func prune(liveDeviceIDs: Set<DeviceID>) {
        counterBaselinesByDeviceID = counterBaselinesByDeviceID.filter {
            liveDeviceIDs.contains($0.key)
        }
        reducersByDeviceID = reducersByDeviceID.filter {
            liveDeviceIDs.contains($0.key)
        }

        guard isPanelPresented else { return }
        let prunedMetrics = metricsByDeviceID.filter { liveDeviceIDs.contains($0.key) }
        if prunedMetrics != metricsByDeviceID {
            metricsByDeviceID = prunedMetrics
        }
    }

    private func ingest(
        _ sample: ThroughputSamplingDeviceResult,
        tick: ThroughputSamplingTick
    ) {
        let previousBaseline = counterBaselinesByDeviceID[sample.deviceID]
        let continuesSameCounterEpoch = previousBaseline?.physicalBSDName == sample.physicalBSDName
        let readDelta = continuesSameCounterEpoch
            ? Self.counterDelta(
                current: sample.counters.readBytes,
                previous: previousBaseline?.counters.readBytes ?? 0
            )
            : 0
        let writeDelta = continuesSameCounterEpoch
            ? Self.counterDelta(
                current: sample.counters.writeBytes,
                previous: previousBaseline?.counters.writeBytes ?? 0
            )
            : 0

        var reducer = reducersByDeviceID[sample.deviceID]
            ?? SessionMetricsReducer(historyLimit: historyLimit)
        reducer.ingest(readBytes: readDelta, writeBytes: writeDelta, tick: tick)
        reducersByDeviceID[sample.deviceID] = reducer
        counterBaselinesByDeviceID[sample.deviceID] = CounterBaseline(
            physicalBSDName: sample.physicalBSDName,
            counters: sample.counters
        )
    }

    private func shouldPublish(at timestamp: Date) -> Bool {
        guard isPanelPresented else { return false }
        if shouldPublishNextSample || lastPublishTimestamp == nil {
            return true
        }
        guard let lastPublishTimestamp else { return true }
        if timestamp < lastPublishTimestamp {
            return true
        }
        return timestamp.timeIntervalSince(lastPublishTimestamp) >= minimumPublishInterval
    }

    private func publishMetrics(at timestamp: Date) {
        metricsByDeviceID = reducersByDeviceID.mapValues(\.metrics)
        lastPublishTimestamp = timestamp
        shouldPublishNextSample = false
    }

    private static func counterDelta(current: Int64, previous: Int64) -> Int64 {
        guard current >= 0, previous >= 0, current >= previous else { return 0 }
        let (delta, overflow) = current.subtractingReportingOverflow(previous)
        return overflow ? .max : delta
    }
}
