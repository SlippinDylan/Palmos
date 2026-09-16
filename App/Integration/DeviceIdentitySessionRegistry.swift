import Foundation

import PalmosCore

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
