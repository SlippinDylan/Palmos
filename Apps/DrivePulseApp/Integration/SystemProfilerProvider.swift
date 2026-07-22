import Foundation

import DrivePulseCore

private actor SystemProfilerFetchGate {
    private var isFetching = false

    func acquire() -> Bool {
        guard isFetching == false else { return false }
        isFetching = true
        return true
    }

    func release() {
        isFetching = false
    }

    func waitUntilIdle() async -> Bool {
        while isFetching {
            do {
                try await Task.sleep(for: .milliseconds(5))
            } catch {
                return false
            }
        }
        return true
    }
}

// MARK: - Protocol

protocol SystemProfilerProviding: AnyObject, Sendable {
    func fetchIfNeeded() async
    func refresh() async
    func nvmeInfo(forBSDName bsdName: String, modelName: String?) -> NVMeInfo?
    func pciInfo(forNVMeSerialNumber serial: String?) -> PCIInfo?
    /// Heuristic: returns the first non-Apple Thunderbolt leaf device found.
    func thunderboltInfo() -> ThunderboltInfo?
}

// MARK: - Live Implementation

final class LiveSystemProfilerProvider: SystemProfilerProviding, @unchecked Sendable {
    private let cacheBox = SystemProfilerCacheBox()
    private let requestCoordinator = LatestRequestCoordinator()
    private let fetchGate = SystemProfilerFetchGate()
    private let dataTypeRunner: @Sendable (String) async -> Data?
    private let deviceIOTracker: DeviceIOTracker?
    private let cacheTTL: TimeInterval
    private let now: @Sendable () -> Date

    func usesDeviceIOTracker(_ tracker: DeviceIOTracker) -> Bool {
        deviceIOTracker === tracker
    }

    init(
        dataTypeRunner: @escaping @Sendable (String) async -> Data? = LiveSystemProfilerProvider.runSystemProfiler,
        deviceIOTracker: DeviceIOTracker? = nil,
        cacheTTL: TimeInterval = 300,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.dataTypeRunner = dataTypeRunner
        self.deviceIOTracker = deviceIOTracker
        self.cacheTTL = max(cacheTTL, 0)
        self.now = now
    }

    func fetchIfNeeded() async {
        guard cacheBox.hasFreshValue(maxAge: cacheTTL, now: now()) == false else { return }
        guard await fetchGate.acquire() else {
            _ = await fetchGate.waitUntilIdle()
            return
        }
        let generation = await requestCoordinator.beginRequest()
        let cache = await fetchCache()
        if let cache, await requestCoordinator.isLatest(generation) {
            cacheBox.set(cache, at: now())
        }
        await fetchGate.release()
    }

    func refresh() async {
        while await fetchGate.acquire() == false {
            guard await fetchGate.waitUntilIdle() else { return }
        }
        let generation = await requestCoordinator.beginRequest()
        guard let cache = await fetchCache() else {
            await fetchGate.release()
            return
        }

        await fetchGate.release()
        guard await requestCoordinator.isLatest(generation) else { return }
        cacheBox.set(cache, at: now())
    }

    func nvmeInfo(forBSDName bsdName: String, modelName: String?) -> NVMeInfo? {
        cacheBox.get()?.nvmeInfo(forBSDName: bsdName, modelName: modelName)
    }

    func pciInfo(forNVMeSerialNumber serial: String?) -> PCIInfo? {
        cacheBox.get()?.pciInfo(forNVMeSerialNumber: serial)
    }

    func thunderboltInfo() -> ThunderboltInfo? {
        cacheBox.get()?.thunderboltInfo()
    }

    private func fetchCache() async -> SystemProfilerCache? {
        async let thunderboltJSON = fetchJSON(for: "SPThunderboltDataType")
        async let nvmeJSON = fetchJSON(for: "SPNVMeDataType")
        async let pciJSON = fetchJSON(for: "SPPCIDataType")

        let fragments = await [thunderboltJSON, nvmeJSON, pciJSON]
        let mergedJSON = fragments.reduce(into: [String: Any]()) { partial, fragment in
            guard let fragment else { return }
            for (key, value) in fragment {
                partial[key] = value
            }
        }

        guard mergedJSON.isEmpty == false else {
            NSLog("[SystemProfilerProvider] system_profiler returned no data")
            return nil
        }

        return SystemProfilerParser.parse(json: mergedJSON)
    }

    private func fetchJSON(for dataType: String) async -> [String: Any]? {
        let token: DeviceIOTracker.Token?
        do {
            token = try await deviceIOTracker?.beginGlobalOperation(kind: .systemProfiler)
        } catch {
            return nil
        }
        let data = await dataTypeRunner(dataType)
        if let token, let deviceIOTracker {
            await deviceIOTracker.finish(token)
        }
        guard let data else {
            NSLog("[SystemProfilerProvider] system_profiler returned no data for %@", dataType)
            return nil
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            NSLog("[SystemProfilerProvider] Failed to parse system_profiler JSON for %@", dataType)
            return nil
        }

        return json
    }

    private static func runSystemProfiler(for dataType: String) async -> Data? {
        await SubprocessRunner.run(
            executable: "/usr/sbin/system_profiler",
            arguments: [dataType, "-json"]
        )
    }
}

// MARK: - Thread-safe cache box

private final class SystemProfilerCacheBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: SystemProfilerCache?
    private var updatedAt: Date?

    func get() -> SystemProfilerCache? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func hasFreshValue(maxAge: TimeInterval, now: Date = .now) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard value != nil, let updatedAt else { return false }
        return now.timeIntervalSince(updatedAt) <= maxAge
    }

    func set(_ newValue: SystemProfilerCache, at date: Date = .now) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
        updatedAt = date
    }
}
