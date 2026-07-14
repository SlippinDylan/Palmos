import Foundation

@MainActor
final class VolumeCapacityRefresher {
    struct CapacityUpdate: Sendable {
        let bsdName: String
        let totalBytes: Int64
        let availableBytes: Int64
        let consumedBytes: Int64
    }

    var onUpdate: (([CapacityUpdate]) -> Void)?
    private var timer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var refreshPending = false
    private var mountPoints: [String: String] = [:]  // bsdName → mountPoint
    private var physicalBSDNames: [String: String] = [:]
    private let deviceIOTracker: DeviceIOTracker?
    private let capacityReader: @Sendable (String, String) -> CapacityUpdate?

    func usesDeviceIOTracker(_ tracker: DeviceIOTracker) -> Bool {
        deviceIOTracker === tracker
    }

    init(
        deviceIOTracker: DeviceIOTracker? = nil,
        capacityReader: (@Sendable (String, String) -> CapacityUpdate?)? = nil
    ) {
        self.deviceIOTracker = deviceIOTracker
        self.capacityReader = capacityReader ?? Self.readCapacity
    }

    func start(mountPoints: [String: String], physicalBSDNames: [String: String] = [:]) {
        self.mountPoints = mountPoints
        self.physicalBSDNames = physicalBSDNames
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleImmediateRefresh() }
        }
        scheduleImmediateRefresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        refreshTask?.cancel()
        refreshTask = nil
        refreshPending = false
    }

    func updateMountPoints(
        _ mountPoints: [String: String],
        physicalBSDNames: [String: String] = [:]
    ) {
        self.mountPoints = mountPoints
        self.physicalBSDNames = physicalBSDNames
    }

    private func refresh() async {
        let mountPoints = mountPoints
        let physicalBSDNames = physicalBSDNames
        let capacityReader = capacityReader
        var updates: [CapacityUpdate] = []
        for (bsdName, mountPoint) in mountPoints {
            guard !Task.isCancelled else { return }
            var capacityToken: DeviceIOTracker.Token?
            var metadataToken: DeviceIOTracker.Token?
            if let deviceIOTracker, let physicalBSDName = physicalBSDNames[bsdName] {
                do {
                    capacityToken = try await deviceIOTracker.beginTargetOperation(
                        physicalBSDName: physicalBSDName,
                        kind: .capacity
                    )
                    metadataToken = try await deviceIOTracker.beginTargetOperation(
                        physicalBSDName: physicalBSDName,
                        kind: .metadata
                    )
                } catch {
                    if let capacityToken { await deviceIOTracker.finish(capacityToken) }
                    continue
                }
            } else {
                capacityToken = nil
                metadataToken = nil
            }
            let update = await Task.detached(priority: .utility) {
                capacityReader(bsdName, mountPoint)
            }.value
            if let metadataToken { await deviceIOTracker?.finish(metadataToken) }
            if let capacityToken { await deviceIOTracker?.finish(capacityToken) }
            guard !Task.isCancelled else { return }
            guard let update else { continue }
            updates.append(update)
        }
        guard !Task.isCancelled, !refreshPending, !updates.isEmpty else { return }
        onUpdate?(updates)
    }

    private func scheduleImmediateRefresh() {
        guard refreshTask == nil else {
            refreshPending = true
            return
        }
        refreshTask = Task { [weak self] in
            await self?.runRefreshLoop()
        }
    }

    private func runRefreshLoop() async {
        repeat {
            refreshPending = false
            await refresh()
        } while refreshPending && !Task.isCancelled
        refreshTask = nil
    }

    nonisolated private static func readCapacity(
        bsdName: String,
        at mountPoint: String
    ) -> CapacityUpdate? {
        let url = URL(fileURLWithPath: mountPoint)
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey
        ]
        guard let values = try? url.resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacity else { return nil }
        return CapacityUpdate(
            bsdName: bsdName,
            totalBytes: Int64(total),
            availableBytes: Int64(available),
            consumedBytes: Int64(total) - Int64(available)
        )
    }
}
