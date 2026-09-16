import Foundation
import IOKit
import IOKit.storage

struct HelperAuthoritativeSnapshotProvider: Sendable {
    typealias Snapshot = @Sendable (
        String,
        ContinuousClock.Instant,
        HelperOperationCancellation
    ) async throws -> HelperOccupancyScope
    private let snapshot: Snapshot

    init(snapshot: @escaping Snapshot = LiveHelperAuthoritativeSnapshot.snapshot) {
        self.snapshot = snapshot
    }

    func scope(
        for bsdName: String,
        deadline: ContinuousClock.Instant,
        cancellation: HelperOperationCancellation
    ) async throws -> HelperOccupancyScope {
        try await snapshot(bsdName, deadline, cancellation)
    }

    static func validating(
        registryIdentity: @escaping @Sendable (String) async -> UInt64?,
        media: @escaping @Sendable (String) async throws -> HelperDiskMedia?,
        topology: @escaping @Sendable (
            String,
            ContinuousClock.Instant,
            HelperOperationCancellation
        ) async throws -> HelperDiskTopology?
    ) -> Self {
        Self { bsdName, deadline, cancellation in
            try HelperOccupancyRequestValidator.validateBSDName(bsdName)
            guard let identityBefore = await registryIdentity(bsdName),
                  let currentMedia = try await media(bsdName) else {
                throw HelperOccupancyError.targetUnavailable
            }
            try HelperOccupancyRequestValidator.validate(currentMedia)
            guard !cancellation.isCancelled, ContinuousClock.now < deadline else {
                throw CancellationError()
            }
            guard let currentTopology = try await topology(bsdName, deadline, cancellation) else {
                throw HelperOccupancyError.targetUnavailable
            }
            guard !cancellation.isCancelled, ContinuousClock.now < deadline else {
                throw CancellationError()
            }
            guard let identityAfter = await registryIdentity(bsdName),
                  identityBefore == identityAfter else {
                throw HelperOccupancyError.unsafeTarget
            }
            return try await HelperDiskTopologyResolver(load: { _ in currentTopology })
                .resolve(wholeBSDName: bsdName)
        }
    }
}

enum LiveHelperAuthoritativeSnapshot {
    static func snapshot(
        _ bsdName: String,
        deadline: ContinuousClock.Instant,
        cancellation: HelperOperationCancellation
    ) async throws -> HelperOccupancyScope {
        try HelperOccupancyRequestValidator.validateBSDName(bsdName)
        guard let identityBefore = registryIdentity(for: bsdName) else {
            throw HelperOccupancyError.targetUnavailable
        }

        let runner = HelperTopologyCommandRunner()
        guard let mediaInfo = try await runner.propertyList(
            arguments: ["info", "-plist", bsdName],
            deadline: deadline,
            cancellation: cancellation
        ) else { throw HelperOccupancyError.targetUnavailable }
        try HelperOccupancyRequestValidator.validate(
            HelperDiskMedia(
                whole: mediaInfo["Whole"] as? Bool == true,
                external: mediaInfo["Internal"] as? Bool == false,
                ejectable: mediaInfo["Ejectable"] as? Bool == true
            )
        )

        let topology = try await LiveHelperDiskTopologySource.topology(
            bsdName,
            deadline: deadline,
            cancellation: cancellation,
            runner: runner
        )
        guard let topology else { throw HelperOccupancyError.targetUnavailable }
        guard !cancellation.isCancelled, ContinuousClock.now < deadline else {
            throw CancellationError()
        }
        guard let identityAfter = registryIdentity(for: bsdName),
              identityBefore == identityAfter else {
            throw HelperOccupancyError.unsafeTarget
        }
        return try await HelperDiskTopologyResolver(load: { _ in topology }).resolve(wholeBSDName: bsdName)
    }

    static func registryIdentity(for bsdName: String) -> UInt64? {
        guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName) else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        var identity: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &identity) == KERN_SUCCESS else { return nil }
        return identity
    }
}
