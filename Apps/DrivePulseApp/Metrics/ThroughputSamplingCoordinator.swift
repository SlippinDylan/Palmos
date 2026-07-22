import Foundation
import DrivePulseCore

struct ThroughputSamplingDeviceSnapshot: Equatable, Sendable {
    let deviceID: DeviceID
    let physicalBSDName: String
}

struct ThroughputSamplingSnapshot: Equatable, Sendable {
    let generation: Int
    let devices: [ThroughputSamplingDeviceSnapshot]
}

struct ThroughputSamplingDeviceResult: Equatable, Sendable {
    let deviceID: DeviceID
    let physicalBSDName: String
    let counters: DiskIOCounters
}

struct ThroughputSamplingResult: Equatable, Sendable {
    let generation: Int
    let tick: ThroughputSamplingTick
    let samples: [ThroughputSamplingDeviceResult]
}

enum ThroughputSamplingResultGate {
    static func acceptedSamples(
        _ result: ThroughputSamplingResult,
        for snapshot: ThroughputSamplingSnapshot
    ) -> [ThroughputSamplingDeviceResult] {
        guard result.generation == snapshot.generation else { return [] }

        let devicesByID = Dictionary(
            snapshot.devices.map { ($0.deviceID, $0.physicalBSDName) },
            uniquingKeysWith: { first, _ in first }
        )
        return result.samples.filter { sample in
            devicesByID[sample.deviceID] == sample.physicalBSDName
        }
    }
}

actor ThroughputSamplingCoordinator {
    typealias SnapshotProvider = @MainActor @Sendable () -> ThroughputSamplingSnapshot?
    typealias IntervalProvider = @MainActor @Sendable () -> Duration
    typealias ResultHandler = @MainActor @Sendable (ThroughputSamplingResult) -> Void

    private let sampler: any DiskSampling
    private let clock: ContinuousClock
    private let defaultInterval: Duration
    private var loopTask: Task<Void, Never>?

    init(
        sampler: any DiskSampling,
        interval: Duration = .milliseconds(250),
        clock: ContinuousClock = ContinuousClock()
    ) {
        self.sampler = sampler
        self.defaultInterval = interval
        self.clock = clock
    }

    deinit {
        loopTask?.cancel()
    }

    func sample(
        snapshot: ThroughputSamplingSnapshot,
        tick: ThroughputSamplingTick
    ) async -> ThroughputSamplingResult {
        let sampler = self.sampler
        let samples: [ThroughputSamplingDeviceResult] = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let samples = snapshot.devices.compactMap { device -> ThroughputSamplingDeviceResult? in
                    guard let counters = sampler.counters(forBSDName: device.physicalBSDName) else {
                        return nil
                    }
                    return ThroughputSamplingDeviceResult(
                        deviceID: device.deviceID,
                        physicalBSDName: device.physicalBSDName,
                        counters: counters
                    )
                }
                continuation.resume(returning: samples)
            }
        }

        return ThroughputSamplingResult(
            generation: snapshot.generation,
            tick: tick,
            samples: samples
        )
    }

    func start(
        snapshotProvider: @escaping SnapshotProvider,
        intervalProvider: IntervalProvider? = nil,
        resultHandler: @escaping ResultHandler
    ) {
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            guard let self else { return }
            await self.run(
                snapshotProvider: snapshotProvider,
                intervalProvider: intervalProvider,
                resultHandler: resultHandler
            )
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    private func run(
        snapshotProvider: @escaping SnapshotProvider,
        intervalProvider: IntervalProvider?,
        resultHandler: @escaping ResultHandler
    ) async {
        var previousInstant: ContinuousClock.Instant?

        while !Task.isCancelled {
            let instant = clock.now
            let elapsed = previousInstant.map { instant - $0 }
            previousInstant = instant
            guard let snapshot = await snapshotProvider() else {
                await sleepBetweenSamples(for: await intervalProvider?() ?? defaultInterval)
                continue
            }

            let result = await sample(
                snapshot: snapshot,
                tick: ThroughputSamplingTick(
                    displayTimestamp: Date(),
                    elapsedSincePrevious: elapsed
                )
            )
            guard !Task.isCancelled else { return }
            await resultHandler(result)
            await sleepBetweenSamples(for: await intervalProvider?() ?? defaultInterval)
        }
    }

    private func sleepBetweenSamples(for interval: Duration) async {
        do {
            try await clock.sleep(for: interval)
        } catch {
            // Cancellation is the only expected failure for the clock sleep.
        }
    }
}
