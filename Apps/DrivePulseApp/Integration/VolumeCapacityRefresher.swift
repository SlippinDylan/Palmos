import Foundation

@MainActor
final class VolumeCapacityRefresher {
    struct CapacityUpdate {
        let bsdName: String
        let totalBytes: Int64
        let availableBytes: Int64
        let consumedBytes: Int64
    }

    var onUpdate: (([CapacityUpdate]) -> Void)?
    private var timer: Timer?
    private var mountPoints: [String: String] = [:]  // bsdName → mountPoint
    private var physicalBSDNames: [String: String] = [:]
    private let deviceIOTracker: DeviceIOTracker?

    init(deviceIOTracker: DeviceIOTracker? = nil) {
        self.deviceIOTracker = deviceIOTracker
    }

    func start(mountPoints: [String: String], physicalBSDNames: [String: String] = [:]) {
        self.mountPoints = mountPoints
        self.physicalBSDNames = physicalBSDNames
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refresh() }
        }
        Task { await refresh() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func updateMountPoints(_ mountPoints: [String: String]) {
        self.mountPoints = mountPoints
    }

    private func refresh() async {
        var updates: [CapacityUpdate] = []
        for (bsdName, mountPoint) in mountPoints {
            let token: DeviceIOTracker.Token?
            if let deviceIOTracker {
                guard let physicalBSDName = physicalBSDNames[bsdName] else { continue }
                do {
                    token = try await deviceIOTracker.beginTargetOperation(
                        physicalBSDName: physicalBSDName,
                        kind: .capacity
                    )
                } catch {
                    continue
                }
            } else {
                token = nil
            }
            let update = readCapacity(bsdName: bsdName, at: mountPoint)
            if let token { await deviceIOTracker?.finish(token) }
            guard let update else { continue }
            updates.append(update)
        }
        guard !updates.isEmpty else { return }
        onUpdate?(updates)
    }

    private func readCapacity(bsdName: String, at mountPoint: String) -> CapacityUpdate? {
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
