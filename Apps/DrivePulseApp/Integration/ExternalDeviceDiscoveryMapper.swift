import Foundation

import DrivePulseCore

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

        if record.descriptor.backingEvidence == .physical(.tunnelledPCIe) {
            return "PCIe"
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
