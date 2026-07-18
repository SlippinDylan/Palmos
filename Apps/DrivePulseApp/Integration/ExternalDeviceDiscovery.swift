import DiskArbitration
import Foundation
import IOKit
import IOKit.storage
import os.log

import DrivePulseCore

private let discoveryLog = Logger(subsystem: "com.drivepulse.app", category: "DeviceDiscovery")

protocol ExternalDeviceDiscoveryObservation: Sendable {
    func cancel()
}

protocol ExternalDeviceDiscovering: Sendable {
    func discoverDevices() async -> [ExternalDevice]
    func observeDevices(
        _ onUpdate: @escaping @MainActor ([ExternalDevice]) -> Void
    ) -> any ExternalDeviceDiscoveryObservation
}

protocol DiskArbitrationMonitoringSession: Sendable {
    func activate(
        on queue: DispatchQueue,
        context: UnsafeMutableRawPointer,
        appearedCallback: @escaping DADiskAppearedCallback,
        disappearedCallback: @escaping DADiskDisappearedCallback,
        descriptionChangedCallback: @escaping DADiskDescriptionChangedCallback
    )

    func deactivate()
}

final class LiveExternalDeviceDiscovery: ExternalDeviceDiscovering, @unchecked Sendable {
    private let mapper: ExternalDeviceDiscoveryMapper
    private let monitoringSession: (any DiskArbitrationMonitoringSession)?
    private let sessionQueue: DispatchQueue
    private let observerLock = NSLock()
    private let sessionQueueKey = DispatchSpecificKey<Void>()
    private var observers: [UUID: @MainActor ([ExternalDevice]) -> Void] = [:]
    private var callbackContext: UnsafeMutableRawPointer?
    private var isMonitoring = false

    init(
        mapper: ExternalDeviceDiscoveryMapper = ExternalDeviceDiscoveryMapper(
            identityRegistry: .shared
        ),
        monitoringSession: (any DiskArbitrationMonitoringSession)? = LiveDiskArbitrationMonitoringSession(),
        sessionQueue: DispatchQueue = DispatchQueue(label: "DrivePulse.ExternalDeviceDiscovery")
    ) {
        self.mapper = mapper
        self.monitoringSession = monitoringSession
        self.sessionQueue = sessionQueue
        self.sessionQueue.setSpecific(key: sessionQueueKey, value: ())
    }

    func discoverDevices() async -> [ExternalDevice] {
        await withCheckedContinuation { continuation in
            sessionQueue.async { [weak self] in
                continuation.resume(returning: self?.enumerateDevices() ?? [])
            }
        }
    }

    private func enumerateDevices() -> [ExternalDevice] {
        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            return []
        }

        let records = DiskDiscoveryEnumerator(session: session).records()
        return mapper.map(records)
    }

    func observeDevices(
        _ onUpdate: @escaping @MainActor ([ExternalDevice]) -> Void
    ) -> any ExternalDeviceDiscoveryObservation {
        let observerID = UUID()

        observerLock.lock()
        observers[observerID] = onUpdate
        let shouldStartMonitoring = isMonitoring == false
        observerLock.unlock()

        if shouldStartMonitoring {
            startMonitoring()
        }

        return LiveExternalDeviceDiscoveryObservation { [weak self] in
            self?.removeObserver(observerID)
        }
    }

    deinit {
        stopMonitoring()
    }

    private func startMonitoring() {
        guard let monitoringSession else {
            return
        }

        observerLock.lock()
        guard isMonitoring == false else {
            observerLock.unlock()
            return
        }

        let callbackState = LiveExternalDeviceDiscoveryCallbackState(discovery: self)
        let context = Unmanaged.passRetained(callbackState).toOpaque()
        callbackContext = context
        isMonitoring = true
        observerLock.unlock()

        monitoringSession.activate(
            on: sessionQueue,
            context: context,
            appearedCallback: liveExternalDeviceDiscoveryDiskAppearedCallback,
            disappearedCallback: liveExternalDeviceDiscoveryDiskDisappearedCallback,
            descriptionChangedCallback: liveExternalDeviceDiscoveryDiskDescriptionChangedCallback
        )
    }

    private func stopMonitoring() {
        let context: UnsafeMutableRawPointer?
        let monitoringSession: (any DiskArbitrationMonitoringSession)?

        observerLock.lock()
        guard isMonitoring else {
            observerLock.unlock()
            return
        }

        isMonitoring = false
        context = callbackContext
        callbackContext = nil
        monitoringSession = self.monitoringSession
        observerLock.unlock()

        if let context {
            Unmanaged<LiveExternalDeviceDiscoveryCallbackState>
                .fromOpaque(context)
                .takeUnretainedValue()
                .invalidate()
        }

        monitoringSession?.deactivate()

        if DispatchQueue.getSpecific(key: sessionQueueKey) == nil {
            sessionQueue.sync {}
        }

        if let context {
            Unmanaged<LiveExternalDeviceDiscoveryCallbackState>.fromOpaque(context).release()
        }
    }

    private func removeObserver(_ observerID: UUID) {
        var shouldStopMonitoring = false

        observerLock.lock()
        observers.removeValue(forKey: observerID)
        shouldStopMonitoring = observers.isEmpty
        observerLock.unlock()

        if shouldStopMonitoring {
            stopMonitoring()
        }
    }

    fileprivate func handleDiskEvent() {
        let devices = enumerateDevices()

        observerLock.lock()
        let handlers = Array(observers.values)
        observerLock.unlock()

        for handler in handlers {
            Task { @MainActor in
                handler(devices)
            }
        }
    }
}

private final class LiveExternalDeviceDiscoveryObservation: ExternalDeviceDiscoveryObservation, @unchecked Sendable {
    private let onCancel: () -> Void
    private let lock = NSLock()
    private var didCancel = false

    init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }

        guard didCancel == false else {
            return
        }

        didCancel = true
        onCancel()
    }
}

private final class LiveExternalDeviceDiscoveryCallbackState: @unchecked Sendable {
    private let lock = NSLock()
    private weak var discovery: LiveExternalDeviceDiscovery?
    private var isActive = true

    init(discovery: LiveExternalDeviceDiscovery) {
        self.discovery = discovery
    }

    func invalidate() {
        lock.lock()
        isActive = false
        discovery = nil
        lock.unlock()
    }

    func handleDiskEvent() {
        lock.lock()
        let discovery = isActive ? discovery : nil
        lock.unlock()

        discovery?.handleDiskEvent()
    }
}

struct DiskDiscoveryRecord: Equatable {
    let bsdName: String
    let parentBSDName: String?
    let wholeDiskBSDName: String?
    let deviceInternal: Bool?
    let isNetworkVolume: Bool
    let isWholeMedia: Bool
    let isEjectable: Bool
    let registryEntryID: UInt64?
    let mediaUUID: String?
    let volumePath: URL?
    let mediaName: String?
    let deviceModel: String?
    let deviceVendor: String?
    let busName: String?
    let deviceProtocol: String?
    let capacityBytes: Int64?
    let mediaContent: String?
    let ioClassPath: [String]

    init(
        bsdName: String,
        parentBSDName: String?,
        wholeDiskBSDName: String? = nil,
        deviceInternal: Bool?,
        isNetworkVolume: Bool,
        isWholeMedia: Bool,
        isEjectable: Bool = false,
        registryEntryID: UInt64? = nil,
        volumePath: URL?,
        mediaUUID: String? = nil,
        mediaName: String?,
        deviceModel: String?,
        deviceVendor: String?,
        busName: String?,
        deviceProtocol: String?,
        capacityBytes: Int64?,
        mediaContent: String?,
        ioClassPath: [String]
    ) {
        self.bsdName = bsdName
        self.parentBSDName = parentBSDName
        self.wholeDiskBSDName = wholeDiskBSDName
        self.deviceInternal = deviceInternal
        self.isNetworkVolume = isNetworkVolume
        self.isWholeMedia = isWholeMedia
        self.isEjectable = isEjectable
        self.registryEntryID = registryEntryID
        self.mediaUUID = mediaUUID
        self.volumePath = volumePath
        self.mediaName = mediaName
        self.deviceModel = deviceModel
        self.deviceVendor = deviceVendor
        self.busName = busName
        self.deviceProtocol = deviceProtocol
        self.capacityBytes = capacityBytes
        self.mediaContent = mediaContent
        self.ioClassPath = ioClassPath
    }

    var descriptor: ExternalDeviceDescriptor {
        ExternalDeviceDescriptor(
            deviceInternal: deviceInternal,
            transportPath: transportPath,
            isNetworkVolume: isNetworkVolume,
            isWholeMedia: isWholeMedia
        )
    }

    var transportPath: [String] {
        [busName, deviceProtocol].compactMap { $0 } + ioClassPath
    }
}

final class DeviceIdentitySessionRegistry: @unchecked Sendable {
    static let shared = DeviceIdentitySessionRegistry()

    private struct ActiveSession {
        let sessionID: String
        let bsdName: String
        let mediaUUID: String?
        let registryEntryID: UInt64?

        func updated(with record: DiskDiscoveryRecord) -> ActiveSession {
            ActiveSession(
                sessionID: sessionID,
                bsdName: record.bsdName,
                mediaUUID: record.normalizedMediaUUID ?? mediaUUID,
                registryEntryID: record.registryEntryID ?? registryEntryID
            )
        }
    }

    private let lock = NSLock()
    private var activeSessions: [ActiveSession] = []

    func identityEvidence(for records: [DiskDiscoveryRecord]) -> [String: DeviceIdentityEvidence] {
        lock.lock()
        defer { lock.unlock() }

        var remainingPrevious = activeSessions
        var allocated: [String: ActiveSession] = [:]
        let currentRegistryEntryCounts = Dictionary(
            grouping: records.compactMap(\.registryEntryID),
            by: { $0 }
        ).mapValues(\.count)

        // A live IORegistry entry is the strongest insertion-session evidence.
        // Resolve it before consulting BSD names, which the kernel may reuse.
        for record in records {
            guard let registryEntryID = record.registryEntryID,
                  currentRegistryEntryCounts[registryEntryID] == 1 else { continue }
            let candidates = remainingPrevious.indices.filter {
                remainingPrevious[$0].registryEntryID == registryEntryID
            }
            guard candidates.count == 1, let index = candidates.first else { continue }
            let session = remainingPrevious.remove(at: index).updated(with: record)
            allocated[record.bsdName] = session
        }

        let currentMediaCounts = Dictionary(
            grouping: records.compactMap(\.normalizedMediaUUID),
            by: { $0 }
        ).mapValues(\.count)
        for record in records where allocated[record.bsdName] == nil {
            // A new registry entry means a new insertion session even when the
            // persistent media UUID is unchanged. Media-only matching is for
            // observations where registry evidence is unavailable.
            guard record.registryEntryID == nil,
                  let mediaUUID = record.normalizedMediaUUID,
                  currentMediaCounts[mediaUUID] == 1 else { continue }
            let candidates = remainingPrevious.indices.filter {
                remainingPrevious[$0].mediaUUID == mediaUUID
            }
            guard candidates.count == 1, let index = candidates.first else { continue }
            let session = remainingPrevious.remove(at: index).updated(with: record)
            allocated[record.bsdName] = session
        }

        for record in records where allocated[record.bsdName] == nil {
            // BSD continuity is only a final fallback. Stable incoming evidence
            // must agree with the prior session; a sparse prior record or a
            // different device must never claim the reused BSD name.
            guard record.registryEntryID == nil,
                  let index = remainingPrevious.firstIndex(where: { previous in
                      guard previous.bsdName == record.bsdName else { return false }
                      guard let mediaUUID = record.normalizedMediaUUID else { return true }
                      return previous.mediaUUID == mediaUUID
                  }) else { continue }
            let session = remainingPrevious.remove(at: index).updated(with: record)
            allocated[record.bsdName] = session
        }

        for record in records where allocated[record.bsdName] == nil {
            allocated[record.bsdName] = ActiveSession(
                sessionID: UUID().uuidString.lowercased(),
                bsdName: record.bsdName,
                mediaUUID: record.normalizedMediaUUID,
                registryEntryID: record.registryEntryID
            )
        }

        activeSessions = records.compactMap { allocated[$0.bsdName] }
        return allocated.mapValues { session in
            DeviceIdentityEvidence(
                mediaUUID: session.mediaUUID,
                registryEntryID: session.registryEntryID,
                sessionID: session.sessionID
            )
        }
    }
}

private extension DiskDiscoveryRecord {
    var normalizedMediaUUID: String? {
        guard let value = mediaUUID?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.isEmpty == false else {
            return nil
        }
        return value.lowercased()
    }
}

final class ExternalDeviceDiscoveryMapper: @unchecked Sendable {
    private let reducer = DeviceRegistryReducer()
    private let lock = NSLock()
    private let identityRegistry: DeviceIdentitySessionRegistry

    init(identityRegistry: DeviceIdentitySessionRegistry = DeviceIdentitySessionRegistry()) {
        self.identityRegistry = identityRegistry
    }

    func map(_ records: [DiskDiscoveryRecord]) -> [ExternalDevice] {
        lock.lock()
        defer { lock.unlock() }

        let records = canonicalRecords(from: records)
        let recordsByBSD = Dictionary(
            records.map { ($0.bsdName, $0) },
            uniquingKeysWith: { existing, _ in existing }
        )
        discoveryLog.debug("Discovery: enumerating \(records.count) IOMedia records")
        for r in records {
            let pass = DeviceIdentityResolver.isExternalPhysicalDevice(r.descriptor)
            discoveryLog.debug(
                "  \(r.bsdName) whole=\(r.isWholeMedia) internal=\(r.deviceInternal.map(String.init) ?? "nil") net=\(r.isNetworkVolume) transport=[\(r.transportPath.joined(separator: ","))] → externalPhysical=\(pass)"
            )
        }

        let rootRecords = records
            .filter {
                let pass = DeviceIdentityResolver.isExternalPhysicalDevice($0.descriptor)
                if !pass {
                    discoveryLog.debug("  FILTERED OUT \($0.bsdName): not external physical device")
                }
                return pass
            }
            .filter {
                let root = topLevelExternalRoot(for: $0, recordsByBSD: recordsByBSD)
                let isRoot = root == $0.bsdName
                if !isRoot {
                    discoveryLog.debug("  FILTERED OUT \($0.bsdName): topLevelRoot=\(root ?? "nil") ≠ self")
                }
                return isRoot
            }
            .sorted { $0.bsdName.localizedStandardCompare($1.bsdName) == .orderedAscending }

        discoveryLog.debug("Discovery: \(rootRecords.count) root external device(s) after filtering: \(rootRecords.map(\.bsdName).joined(separator: ", "))")

        let identityEvidenceByBSDName = identityRegistry.identityEvidence(for: rootRecords)

        return rootRecords.map { rootRecord in
            let descendants = descendantRecords(for: rootRecord.bsdName, recordsByBSD: recordsByBSD)

            let apfsContainerBSDName = descendants
                .filter {
                    $0.bsdName != rootRecord.bsdName &&
                    $0.isWholeMedia &&
                    (isAPFSContent($0.mediaContent) || isApfsContainerMedia($0.ioClassPath))
                }
                .sorted { lhs, rhs in
                    let leftDepth = ancestorDepth(of: lhs.bsdName, recordsByBSD: recordsByBSD)
                    let rightDepth = ancestorDepth(of: rhs.bsdName, recordsByBSD: recordsByBSD)

                    if leftDepth == rightDepth {
                        return lhs.bsdName.localizedStandardCompare(rhs.bsdName) == .orderedAscending
                    }

                    return leftDepth < rightDepth
                }
                .first?
                .bsdName

            let mountedVolumes = records
                .filter {
                    $0.volumePath != nil &&
                    $0.isNetworkVolume == false
                }
                .filter { volumeRecord in
                    let resolvedRoot = rootBSDName(
                        forMountedVolume: volumeRecord,
                        recordsByBSD: recordsByBSD
                    )
                    let match = resolvedRoot == rootRecord.bsdName ||
                        (apfsContainerBSDName != nil && volumeRecord.wholeDiskBSDName == apfsContainerBSDName)
                    discoveryLog.debug(
                        "  volumeMap: \(volumeRecord.bsdName) whole=\(volumeRecord.wholeDiskBSDName ?? "nil") → root=\(resolvedRoot ?? "nil") match=\(match) (expect \(rootRecord.bsdName))"
                    )
                    return match
                }
                .map {
                    MountedVolume(
                        bsdName: $0.bsdName,
                        mountPoint: $0.volumePath?.path
                    )
                }
                .sorted { $0.bsdName.localizedStandardCompare($1.bsdName) == .orderedAscending }

            var device = reducer.reduce(
                physicalBSDName: rootRecord.bsdName,
                containerBSDName: apfsContainerBSDName,
                volumes: mountedVolumes,
                identityEvidence: identityEvidenceByBSDName[rootRecord.bsdName]
            )
            device.displayName = displayName(for: rootRecord)
            device.transportName = transportName(for: rootRecord)
            device.capacityBytes = rootRecord.capacityBytes
            device.physicalPartitions = records
                .filter {
                    $0.wholeDiskBSDName == rootRecord.bsdName &&
                    !$0.isWholeMedia &&
                    $0.bsdName != rootRecord.bsdName
                }
                .map {
                    PhysicalPartitionInfo(
                        bsdName: $0.bsdName,
                        partitionType: $0.mediaContent,
                        name: $0.mediaName,
                        sizeBytes: $0.capacityBytes
                    )
                }
                .sorted { $0.bsdName.localizedStandardCompare($1.bsdName) == .orderedAscending }
            return device
        }
    }

    func canonicalRecords(from records: [DiskDiscoveryRecord]) -> [DiskDiscoveryRecord] {
        let candidatesByBSDName = Dictionary(grouping: records, by: \.bsdName)
        let conflictingBSDNames: Set<String> = Set(candidatesByBSDName.compactMap { bsdName, candidates -> String? in
            guard let first = candidates.first,
                  candidates.contains(where: { $0 != first }) else { return nil }
            discoveryLog.error("Ignoring conflicting discovery records for \(bsdName)")
            return bsdName
        })

        var excludedBSDNames = conflictingBSDNames
        var didExcludeDescendant = true
        while didExcludeDescendant {
            didExcludeDescendant = false
            for (bsdName, candidates) in candidatesByBSDName where excludedBSDNames.contains(bsdName) == false {
                guard let record = candidates.first else { continue }
                let touchesExcludedAncestor = record.parentBSDName.map {
                    excludedBSDNames.contains($0)
                } ?? false
                let referencesExcludedWholeDisk = record.wholeDiskBSDName.map {
                    excludedBSDNames.contains($0)
                } ?? false
                if touchesExcludedAncestor || referencesExcludedWholeDisk {
                    excludedBSDNames.insert(bsdName)
                    didExcludeDescendant = true
                }
            }
        }

        return candidatesByBSDName.compactMap { bsdName, candidates in
            guard excludedBSDNames.contains(bsdName) == false else { return nil }
            return candidates.first
        }
    }

    private func topLevelExternalRoot(
        for record: DiskDiscoveryRecord,
        recordsByBSD: [String: DiskDiscoveryRecord]
    ) -> String? {
        var candidate = record.bsdName
        var currentParentBSDName = record.parentBSDName
        var visited = Set([record.bsdName])

        while let parentBSDName = currentParentBSDName,
              let parent = recordsByBSD[parentBSDName],
              visited.insert(parentBSDName).inserted {
            if DeviceIdentityResolver.isExternalPhysicalDevice(parent.descriptor) {
                candidate = parent.bsdName
            }

            currentParentBSDName = parent.parentBSDName
        }

        return candidate
    }

    private func descendantRecords(
        for rootBSDName: String,
        recordsByBSD: [String: DiskDiscoveryRecord]
    ) -> [DiskDiscoveryRecord] {
        recordsByBSD.values.filter { record in
            guard record.bsdName != rootBSDName else {
                return true
            }

            return ancestorChain(for: record.bsdName, recordsByBSD: recordsByBSD).contains(rootBSDName)
        }
    }

    private func ancestorDepth(
        of bsdName: String,
        recordsByBSD: [String: DiskDiscoveryRecord]
    ) -> Int {
        ancestorChain(for: bsdName, recordsByBSD: recordsByBSD).count
    }

    private func ancestorChain(
        for bsdName: String,
        recordsByBSD: [String: DiskDiscoveryRecord]
    ) -> [String] {
        var chain: [String] = []
        var currentBSDName = recordsByBSD[bsdName]?.parentBSDName
        var visited = Set([bsdName])

        while let parentBSDName = currentBSDName,
              let parent = recordsByBSD[parentBSDName],
              visited.insert(parentBSDName).inserted {
            chain.append(parentBSDName)
            currentBSDName = parent.parentBSDName
        }

        return chain
    }

    private func rootBSDName(
        forMountedVolume record: DiskDiscoveryRecord,
        recordsByBSD: [String: DiskDiscoveryRecord]
    ) -> String? {
        let wholeDiskBSDName = record.wholeDiskBSDName ?? record.bsdName
        guard let wholeDiskRecord = recordsByBSD[wholeDiskBSDName] else {
            return nil
        }

        return topLevelExternalRoot(for: wholeDiskRecord, recordsByBSD: recordsByBSD)
    }

    private func displayName(for record: DiskDiscoveryRecord) -> String {
        let vendor = normalizedString(record.deviceVendor)
        let model = normalizedString(record.deviceModel)
        let mediaName = normalizedString(record.mediaName)

        let vendorAndModel = [vendor, model]
            .compactMap { $0 }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if vendorAndModel.isEmpty == false {
            return vendorAndModel
        }

        if let mediaName {
            return mediaName
        }

        if let model {
            return model
        }

        return record.bsdName.uppercased()
    }

    private func transportName(for record: DiskDiscoveryRecord) -> String {
        let normalizedPath = record.transportPath
            .map { $0.lowercased() }
            .joined(separator: " ")

        if normalizedPath.contains("thunderbolt") ||
            record.ioClassPath.contains(where: { $0.lowercased().hasPrefix("iothunderbolt") }) {
            return "Thunderbolt"
        }

        if normalizedPath.contains("usb4") {
            return "USB4"
        }

        if normalizedPath.contains("usb") {
            return "USB"
        }

        if matchesSDTransport(in: normalizedPath) {
            return "SD"
        }

        if let busName = normalizedString(record.busName) {
            return busName
        }

        if let deviceProtocol = normalizedString(record.deviceProtocol) {
            return deviceProtocol
        }

        return "External"
    }

    private func isAPFSContent(_ mediaContent: String?) -> Bool {
        normalizedString(mediaContent)?
            .lowercased()
            .contains("apfs") == true
    }

    private func isApfsContainerMedia(_ ioClassPath: [String]) -> Bool {
        ioClassPath.contains("AppleAPFSMedia")
    }

    private func matchesSDTransport(in normalizedPath: String) -> Bool {
        let sdPhrases = [
            "sd card",
            "sd reader",
            "sd slot",
            "sd bus",
            "sd host",
            "sdxc",
            "sdhc",
            "microsd"
        ]

        if sdPhrases.contains(where: normalizedPath.contains) {
            return true
        }

        let separators = CharacterSet.alphanumerics.inverted
        let tokens = normalizedPath
            .components(separatedBy: separators)
            .filter { $0.isEmpty == false }
        return tokens.contains("sd")
    }

    private func normalizedString(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.isEmpty == false else {
            return nil
        }

        return trimmed
    }
}

struct DiskDiscoveryEnumerator {
    private let session: DASession

    init(session: DASession) {
        self.session = session
    }

    func records() -> [DiskDiscoveryRecord] {
        guard let matching = IOServiceMatching(kIOMediaClass) else {
            return []
        }

        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard result == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var discoveredRecords: [DiskDiscoveryRecord] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }

            guard let record = makeRecord(for: service) else {
                continue
            }

            discoveryLog.debug(
                "IOMedia: \(record.bsdName) protocol=\(record.deviceProtocol ?? "-") bus=\(record.busName ?? "-") internal=\(record.deviceInternal.map(String.init) ?? "nil") whole=\(record.isWholeMedia) ioPath=[\(record.ioClassPath.prefix(5).joined(separator: "→"))]"
            )
            discoveredRecords.append(record)
        }

        return discoveredRecords
    }

    private func makeRecord(for service: io_service_t) -> DiskDiscoveryRecord? {
        // DADiskCreateFromIOMedia may return nil for synthesized disks such as APFS
        // containers (disk5). Fall back to BSD-name-based creation so those entries
        // remain in recordsByBSD and can serve as chain links during volume mapping.
        let disk: DADisk? = DADiskCreateFromIOMedia(kCFAllocatorDefault, session, service)
            ?? stringProperty(named: "BSD Name", for: service).flatMap { bsdName in
                bsdName.withCString { DADiskCreateFromBSDName(kCFAllocatorDefault, session, $0) }
            }

        guard let disk,
              let bsdNamePointer = DADiskGetBSDName(disk) else {
            return nil
        }

        let bsdName = String(cString: bsdNamePointer)
        let description = DADiskCopyDescription(disk) as? [String: Any]
        let wholeDisk = DADiskCopyWholeDisk(disk)
        let wholeDiskBSDName: String?
        if let wholeDisk,
           let wholeDiskBSDNamePointer = DADiskGetBSDName(wholeDisk) {
            wholeDiskBSDName = String(cString: wholeDiskBSDNamePointer)
        } else {
            wholeDiskBSDName = nil
        }

        return DiskDiscoveryRecord(
            bsdName: bsdName,
            parentBSDName: parentBSDName(for: service),
            wholeDiskBSDName: wholeDiskBSDName,
            deviceInternal: description?[kDADiskDescriptionDeviceInternalKey as String] as? Bool,
            isNetworkVolume: description?[kDADiskDescriptionVolumeNetworkKey as String] as? Bool ?? false,
            isWholeMedia: description?[kDADiskDescriptionMediaWholeKey as String] as? Bool
                ?? boolProperty(named: kIOMediaWholeKey, for: service)
                ?? false,
            isEjectable: description?[kDADiskDescriptionMediaEjectableKey as String] as? Bool
                ?? boolProperty(named: kIOMediaEjectableKey, for: service)
                ?? false,
            registryEntryID: registryEntryID(for: service),
            volumePath: description?[kDADiskDescriptionVolumePathKey as String] as? URL,
            mediaUUID: mediaUUID(from: description?[kDADiskDescriptionMediaUUIDKey as String]),
            mediaName: description?[kDADiskDescriptionMediaNameKey as String] as? String,
            deviceModel: description?[kDADiskDescriptionDeviceModelKey as String] as? String,
            deviceVendor: description?[kDADiskDescriptionDeviceVendorKey as String] as? String,
            busName: description?[kDADiskDescriptionBusNameKey as String] as? String,
            deviceProtocol: description?[kDADiskDescriptionDeviceProtocolKey as String] as? String,
            capacityBytes: description?[kDADiskDescriptionMediaSizeKey as String] as? Int64
                ?? (description?[kDADiskDescriptionMediaSizeKey as String] as? NSNumber)?.int64Value
                ?? int64Property(named: kIOMediaSizeKey, for: service),
            mediaContent: description?[kDADiskDescriptionMediaContentKey as String] as? String,
            ioClassPath: ioClassPath(for: service)
        )
    }

    private func mediaUUID(from value: Any?) -> String? {
        if let uuid = value as? UUID {
            return uuid.uuidString
        }
        if let uuid = value as? NSUUID {
            return uuid.uuidString
        }
        return nil
    }

    private func parentBSDName(for service: io_service_t) -> String? {
        var current = service
        var ownsCurrent = false

        while true {
            var parent: io_registry_entry_t = 0
            let result = IORegistryEntryGetParentEntry(current, "IOService", &parent)

            if ownsCurrent {
                IOObjectRelease(current)
            }

            guard result == KERN_SUCCESS else {
                return nil
            }

            if let bsdName = stringProperty(named: "BSD Name", for: parent) {
                IOObjectRelease(parent)
                return bsdName
            }

            current = parent
            ownsCurrent = true
        }
    }

    private func ioClassPath(for service: io_service_t) -> [String] {
        var classes: [String] = []
        var current = service
        var ownsCurrent = false

        while true {
            if let className = IOObjectCopyClass(current)?.takeRetainedValue() as String? {
                classes.append(className)
            }

            var parent: io_registry_entry_t = 0
            let result = IORegistryEntryGetParentEntry(current, "IOService", &parent)

            if ownsCurrent {
                IOObjectRelease(current)
            }

            guard result == KERN_SUCCESS else {
                return classes
            }

            current = parent
            ownsCurrent = true
        }
    }

    private func stringProperty(named key: String, for service: io_service_t) -> String? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }

    private func boolProperty(named key: String, for service: io_service_t) -> Bool? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool
    }

    private func int64Property(named key: String, for service: io_service_t) -> Int64? {
        if let number = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber {
            return number.int64Value
        }

        return nil
    }

    private func registryEntryID(for service: io_service_t) -> UInt64? {
        var identifier: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &identifier) == KERN_SUCCESS else {
            return nil
        }
        return identifier
    }
}

private let liveExternalDeviceDiscoveryDiskAppearedCallback: DADiskAppearedCallback = { _, context in
    liveExternalDeviceDiscoveryCallbackState(from: context)?.handleDiskEvent()
}

private let liveExternalDeviceDiscoveryDiskDisappearedCallback: DADiskDisappearedCallback = { _, context in
    liveExternalDeviceDiscoveryCallbackState(from: context)?.handleDiskEvent()
}

private let liveExternalDeviceDiscoveryDiskDescriptionChangedCallback: DADiskDescriptionChangedCallback = { _, _, context in
    liveExternalDeviceDiscoveryCallbackState(from: context)?.handleDiskEvent()
}

private func liveExternalDeviceDiscoveryCallbackState(
    from context: UnsafeMutableRawPointer?
) -> LiveExternalDeviceDiscoveryCallbackState? {
    guard let context else {
        return nil
    }

    return Unmanaged<LiveExternalDeviceDiscoveryCallbackState>.fromOpaque(context).takeUnretainedValue()
}

private final class LiveDiskArbitrationMonitoringSession: DiskArbitrationMonitoringSession, @unchecked Sendable {
    private let session: DASession?

    init(session: DASession? = DASessionCreate(kCFAllocatorDefault)) {
        self.session = session
    }

    func activate(
        on queue: DispatchQueue,
        context: UnsafeMutableRawPointer,
        appearedCallback: @escaping DADiskAppearedCallback,
        disappearedCallback: @escaping DADiskDisappearedCallback,
        descriptionChangedCallback: @escaping DADiskDescriptionChangedCallback
    ) {
        guard let session else {
            return
        }

        DASessionSetDispatchQueue(session, queue)
        DARegisterDiskAppearedCallback(session, nil, appearedCallback, context)
        DARegisterDiskDisappearedCallback(session, nil, disappearedCallback, context)
        DARegisterDiskDescriptionChangedCallback(session, nil, nil, descriptionChangedCallback, context)
    }

    func deactivate() {
        guard let session else {
            return
        }

        DASessionSetDispatchQueue(session, nil)
    }
}
