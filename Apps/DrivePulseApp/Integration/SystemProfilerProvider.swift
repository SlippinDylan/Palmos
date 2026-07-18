import Foundation

import Darwin

import DrivePulseCore

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Data()

    func set(_ newValue: Data) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }

    func get() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

enum SubprocessRunner {
    static let defaultMaxOutputBytes = 4 * 1024 * 1024
    static let defaultTimeout: Duration = .seconds(30)

    static func run(
        executable: String,
        arguments: [String],
        maxOutputBytes: Int = defaultMaxOutputBytes,
        timeout: Duration = defaultTimeout,
        processPrepared: (@Sendable () -> Void)? = nil
    ) async -> Data? {
        guard maxOutputBytes > 0 else { return nil }
        let processBox = ProcessBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                let process = Process()
                processBox.set(process)
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe
                processPrepared?()

                do {
                    try process.run()
                    processBox.processDidStart(process)
                } catch {
                    continuation.resume(returning: nil)
                    return
                }

                let timeoutWorkItem = DispatchWorkItem {
                    processBox.terminateAndEscalate()
                }
                let timeoutNanoseconds = timeout.nanosecondsClamped
                DispatchQueue.global(qos: .utility).asyncAfter(
                    deadline: .now() + .nanoseconds(timeoutNanoseconds),
                    execute: timeoutWorkItem
                )

                let readQueue = DispatchQueue(label: "DrivePulse.SubprocessRunner.read", attributes: .concurrent)
                let group = DispatchGroup()
                let stdoutBox = DataBox()
                let stderrBox = DataBox()

                group.enter()
                readQueue.async {
                    stdoutBox.set(readData(
                        from: stdoutPipe.fileHandleForReading,
                        maxBytes: maxOutputBytes,
                        processBox: processBox
                    ))
                    group.leave()
                }

                group.enter()
                readQueue.async {
                    stderrBox.set(readData(
                        from: stderrPipe.fileHandleForReading,
                        maxBytes: maxOutputBytes,
                        processBox: processBox
                    ))
                    group.leave()
                }

                process.waitUntilExit()
                group.wait()
                timeoutWorkItem.cancel()
                let stdoutData = stdoutBox.get()
                let stderrData = stderrBox.get()
                let succeeded = processBox.isCancelled == false
                    && process.terminationReason == .exit
                    && process.terminationStatus == 0
                if stdoutData.isEmpty,
                   stderrData.isEmpty == false,
                   processBox.isCancelled == false {
                    let stderrMessage = String(data: stderrData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if let stderrMessage, stderrMessage.isEmpty == false {
                        NSLog(
                            "[SubprocessRunner] %@ %@ failed (exit %d): %@",
                            executable,
                            arguments.joined(separator: " "),
                            process.terminationStatus,
                            stderrMessage
                        )
                    }
                }
                continuation.resume(
                    returning: succeeded && stdoutData.isEmpty == false ? stdoutData : nil
                )
                processBox.clear(process)
                }
            }
        } onCancel: {
            processBox.terminateAndEscalate()
        }
    }

    private static func readData(
        from fileHandle: FileHandle,
        maxBytes: Int,
        processBox: ProcessBox
    ) -> Data {
        var output = Data()
        output.reserveCapacity(min(maxBytes, 64 * 1024))
        while output.count <= maxBytes {
            let chunk = fileHandle.readData(ofLength: min(64 * 1024, maxBytes + 1 - output.count))
            guard chunk.isEmpty == false else { break }
            output.append(chunk)
            if output.count > maxBytes {
                processBox.terminateAndEscalate()
                return Data()
            }
        }
        return output
    }
}

private extension Duration {
    var nanosecondsClamped: Int {
        let components = self.components
        let seconds = components.seconds
        let attoseconds = components.attoseconds
        guard seconds >= 0 else { return 0 }
        let secondsPart = min(seconds, Int64(Int.max) / 1_000_000_000)
        let fractionalPart = min(attoseconds / 1_000_000_000, Int64(Int.max))
        let combined = secondsPart.multipliedReportingOverflow(by: 1_000_000_000)
        guard combined.overflow == false else { return Int.max }
        let result = combined.partialValue.addingReportingOverflow(fractionalPart)
        return result.overflow ? Int.max : Int(result.partialValue)
    }
}

final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var wasCancelled = false

    var isCancelled: Bool { lock.withLock { wasCancelled } }

    func set(_ process: Process) {
        let shouldTerminate = lock.withLock {
            self.process = process
            return wasCancelled
        }
        if shouldTerminate, process.isRunning { process.terminate() }
    }

    func clear(_ process: Process) {
        lock.withLock {
            if self.process === process { self.process = nil }
        }
    }

    func processDidStart(_ process: Process) {
        let shouldTerminate = lock.withLock { wasCancelled && self.process === process }
        if shouldTerminate { terminateAndEscalate() }
    }

    func terminate() {
        lock.withLock {
            wasCancelled = true
            if process?.isRunning == true { process?.terminate() }
        }
    }

    func terminateAndEscalate() {
        let runningProcess: Process? = lock.withLock {
            wasCancelled = true
            guard let process, process.isRunning else { return nil }
            process.terminate()
            return process
        }
        guard let runningProcess else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self, weak runningProcess] in
            guard let self, let runningProcess else { return }
            self.killIfStillRunning(runningProcess)
        }
    }

    private func killIfStillRunning(_ expectedProcess: Process) {
        lock.withLock {
            guard process === expectedProcess, expectedProcess.isRunning else { return }
            _ = kill(expectedProcess.processIdentifier, SIGKILL)
        }
    }
}

actor LatestRequestCoordinator {
    private var latestGeneration = 0

    func beginRequest() -> Int {
        latestGeneration += 1
        return latestGeneration
    }

    func isLatest(_ generation: Int) -> Bool {
        generation == latestGeneration
    }
}

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

        return SystemProfilerCache(json: mergedJSON)
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

private struct ThunderboltCandidate {
    let busIndex: Int
    let receptacle: Int
    let item: [String: Any]
}

private extension ThunderboltCandidate {
    var isDockLike: Bool {
        let name = ((item["_name"] as? String) ?? "").lowercased()
        let deviceName = (
            (item["device_name"] as? String)
            ?? (item["device_name_key"] as? String)
            ?? ""
        ).lowercased()
        let combined = name + " " + deviceName
        return combined.contains("dock") || combined.contains("hub") || combined.contains("station")
    }

    static func sort(_ lhs: ThunderboltCandidate, _ rhs: ThunderboltCandidate) -> Bool {
        if lhs.busIndex != rhs.busIndex { return lhs.busIndex < rhs.busIndex }
        return lhs.receptacle < rhs.receptacle
    }
}

private extension Array where Element == ThunderboltCandidate {
    func uniqueResolvedCandidate() -> ThunderboltCandidate? {
        guard isEmpty == false else { return nil }
        let filtered = filter { !$0.isDockLike }
        let pool = filtered.isEmpty ? self : filtered
        guard pool.count == 1 else { return nil }
        return pool.sorted(by: ThunderboltCandidate.sort).first
    }
}

private extension SystemProfilerCache {
    func thunderboltCandidates() -> [ThunderboltCandidate] {
        var candidates: [ThunderboltCandidate] = []
        for (busIndex, bus) in thunderboltBuses.enumerated() {
            let children = (bus["items"] as? [[String: Any]])
                ?? (bus["Items"] as? [[String: Any]])
                ?? (bus["_items"] as? [[String: Any]])
                ?? []
            for item in children {
                let vendorName = (item["vendor_name"] as? String)
                    ?? (item["vendor_name_key"] as? String)
                    ?? ""
                guard vendorName != "Apple Inc." else { continue }
                let receptacleStr = (item["spthunderbolt_receptacle"] as? String)
                    ?? (item["receptacle"] as? String) ?? "0"
                let receptacle = Int(receptacleStr) ?? 0
                candidates.append(ThunderboltCandidate(busIndex: busIndex, receptacle: receptacle, item: item))
            }
        }
        return candidates
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

// MARK: - Parsed cache

private struct SystemProfilerCache {
    // NVMe leaf items with an extra "__controller__" key injected
    private let nvmeEntries: [[String: Any]]
    private let pciItems: [[String: Any]]
    private let thunderboltBuses: [[String: Any]]

    init(json: [String: Any]) {
        var nvme: [[String: Any]] = []
        if let buses = json["SPNVMeDataType"] as? [[String: Any]] {
            for bus in buses {
                let controllerName = bus["_name"] as? String ?? ""
                let children = (bus["items"] as? [[String: Any]])
                    ?? (bus["Items"] as? [[String: Any]])
                    ?? (bus["_items"] as? [[String: Any]])
                    ?? []
                for child in children {
                    var entry = child
                    entry["__controller__"] = controllerName
                    nvme.append(entry)
                }
                // Some controllers surface bsd_name at the bus level
                if bus["bsd_name"] != nil {
                    var entry = bus
                    entry["__controller__"] = controllerName
                    nvme.append(entry)
                }
            }
        }
        self.nvmeEntries = nvme
        self.pciItems = (json["SPPCIDataType"] as? [[String: Any]]) ?? []
        self.thunderboltBuses = (json["SPThunderboltDataType"] as? [[String: Any]]) ?? []
    }

    func nvmeInfo(forBSDName bsdName: String, modelName: String?) -> NVMeInfo? {
        let item = matchedNVMeEntry(forBSDName: bsdName, modelName: modelName)
        guard let item else {
            return nil
        }

        let controller = item["__controller__"] as? String
        let model = (item["device_model"] as? String)
            ?? (item["_name"] as? String)
            ?? (item["model"] as? String)
        let serialNumber = (item["device_serial"] as? String)
            ?? (item["spsata_serial_no"] as? String)
            ?? (item["serial_no"] as? String)
        let firmwareVersion = (item["device_revision"] as? String)
            ?? (item["spsata_revision"] as? String)
            ?? (item["revision"] as? String)
        let nvmeVersion = item["spnvme_spec_version"] as? String

        let trimRaw = item["spnvme_trim_support"] as? String
        let trimSupport: Bool? = trimRaw.map { $0 == "spnvme_yes" || $0 == "Yes" }

        let linkWidth = (item["spnvme_linkwidth"] as? String)
            ?? (item["spnvme_link_width"] as? String)
            ?? (item["link_width"] as? String)
        let linkSpeed = (item["spnvme_linkspeed"] as? String)
            ?? (item["spnvme_link_speed"] as? String)
            ?? (item["link_speed"] as? String)
        let ieeeOui = item["spnvme_ieee_oui"] as? String

        let firmwareSlots: Int?
        if let str = item["spnvme_number_of_firmware_slots"] as? String {
            firmwareSlots = Int(str)
        } else {
            firmwareSlots = item["spnvme_number_of_firmware_slots"] as? Int
        }

        let fwResetRaw = item["spnvme_fw_update_requires_reset"] as? String
        let firmwareUpdateRequiresReset: Bool? = fwResetRaw.map { $0 == "spnvme_yes" || $0 == "Yes" }

        return NVMeInfo(
            controller: controller,
            model: model,
            serialNumber: serialNumber,
            firmwareVersion: firmwareVersion,
            nvmeVersion: nvmeVersion,
            trimSupport: trimSupport,
            linkWidth: linkWidth,
            linkSpeed: linkSpeed,
            ieeeOui: ieeeOui,
            firmwareSlots: firmwareSlots,
            firmwareUpdateRequiresReset: firmwareUpdateRequiresReset
        )
    }

    func pciInfo(forNVMeSerialNumber serial: String?) -> PCIInfo? {
        guard let serial else { return nil }

        guard let item = pciItems.first(where: { item in
            let type = (item["sppci_type"] as? String) ?? (item["sppci_device_type"] as? String) ?? ""
            let serialNo = (item["serial_no"] as? String)
                ?? (item["sppci_serialnumber"] as? String)
                ?? ""
            return type.uppercased().contains("NVM") && serialNo == serial
        }) else { return nil }

        let slot = (item["sppci_slot_name"] as? String) ?? (item["sppci_slot"] as? String)
        let vendorID = (item["sppci_vendor-id"] as? String) ?? (item["sppci_vendor_id"] as? String)
        let deviceID = (item["sppci_device-id"] as? String) ?? (item["sppci_device_id"] as? String)
        let linkStatus = (item["sppci_link-status"] as? String)
            ?? (item["sppci_link_status"] as? String)
            ?? (item["link_status"] as? String)
        let tunnelRaw = (item["sppci_tunnel-compatible"] as? String)
            ?? (item["sppci_tunnel_compatible"] as? String)
            ?? (item["tunnel_compatible"] as? String)
        let tunnelCompatible: Bool? = tunnelRaw.map { $0 == "Yes" || $0 == "affirmative_string" }
        let linkWidth = (item["sppci_link-width"] as? String)
            ?? (item["sppci_link_width"] as? String)
            ?? (item["link_width"] as? String)
        let linkSpeed = (item["sppci_link-speed"] as? String)
            ?? (item["sppci_link_speed"] as? String)
            ?? (item["link_speed"] as? String)

        return PCIInfo(
            slot: slot,
            vendorID: vendorID,
            deviceID: deviceID,
            linkStatus: linkStatus,
            tunnelCompatible: tunnelCompatible,
            linkWidth: linkWidth,
            linkSpeed: linkSpeed
        )
    }

    func thunderboltInfo() -> ThunderboltInfo? {
        guard let candidate = thunderboltCandidates().uniqueResolvedCandidate() else { return nil }
        let item = candidate.item

        let vendorName = (item["vendor_name_key"] as? String) ?? (item["vendor_name"] as? String)
        let deviceName = (item["device_name_key"] as? String)
            ?? (item["device_name"] as? String)
            ?? (item["_name"] as? String)
        let mode = (item["mode_key"] as? String)
            ?? (item["spthunderbolt_mode"] as? String)
            ?? (item["thunderbolt_mode"] as? String)
            ?? (item["mode"] as? String)

        let busStr = (item["spthunderbolt_bus"] as? String) ?? (item["bus"] as? String)
        let bus = busStr.flatMap { Int($0) } ?? candidate.busIndex

        let receptacleStr = (item["spthunderbolt_receptacle"] as? String) ?? (item["receptacle"] as? String)
        let receptacle = receptacleStr.flatMap { Int($0) }

        let uid = (item["switch_uid_key"] as? String)
            ?? (item["spthunderbolt_uid"] as? String)
            ?? (item["uid"] as? String)
        let firmwareVersion = (item["switch_version_key"] as? String)
            ?? (item["spthunderbolt_fw_ver"] as? String)
            ?? (item["firmware_version"] as? String)

        let upstreamPort: [String: Any]? =
            (item["receptacle_upstream_ambiguous_tag"] as? [String: Any])
            ?? (item["receptacle_upstream_tag"] as? [String: Any])
            ?? (item["port_upstream"] as? [String: Any])
            ?? (item["Port (Upstream)"] as? [String: Any])

        let linkSpeed: String?
        if let port = upstreamPort {
            linkSpeed = (port["current_speed_key"] as? String)
                ?? (port["speed"] as? String)
                ?? (port["link_speed"] as? String)
        } else {
            linkSpeed = item["link_speed"] as? String
        }

        let linkControllerFirmwareVersion: String?
        if let port = upstreamPort {
            linkControllerFirmwareVersion = (port["lc_version_key"] as? String)
                ?? (port["link_controller_firmware_version"] as? String)
        } else {
            linkControllerFirmwareVersion = item["link_controller_firmware_version"] as? String
        }

        let upstreamPortStatus: String?
        if let port = upstreamPort {
            upstreamPortStatus = (port["receptacle_status_key"] as? String)
                ?? (port["status"] as? String)
                ?? (port["upstreamPortStatus"] as? String)
        } else {
            upstreamPortStatus = item["upstreamPortStatus"] as? String
        }

        return ThunderboltInfo(
            vendorName: vendorName,
            deviceName: deviceName,
            mode: mode,
            bus: bus,
            receptacle: receptacle,
            linkSpeed: linkSpeed,
            uid: uid,
            firmwareVersion: firmwareVersion,
            linkControllerFirmwareVersion: linkControllerFirmwareVersion,
            upstreamPortStatus: upstreamPortStatus
        )
    }

    private func matchedNVMeEntry(forBSDName bsdName: String, modelName: String?) -> [String: Any]? {
        if let exact = nvmeEntries.first(where: { ($0["bsd_name"] as? String) == bsdName }) {
            return exact
        }

        guard let modelName = normalized(modelName) else {
            return nil
        }

        let candidates = nvmeEntries.filter { item in
            guard let candidateModel = normalized(
                (item["device_model"] as? String)
                ?? (item["_name"] as? String)
                ?? (item["model"] as? String)
            ) else {
                return false
            }

            return candidateModel == modelName
                || candidateModel.contains(modelName)
                || modelName.contains(candidateModel)
        }

        guard candidates.count == 1 else {
            return nil
        }

        return candidates[0]
    }

    private func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.isEmpty == false else {
            return nil
        }

        return value.lowercased()
    }
}
