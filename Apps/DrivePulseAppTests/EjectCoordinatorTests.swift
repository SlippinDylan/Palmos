import XCTest

import DrivePulseCore

@testable import DrivePulseApp

@MainActor
final class EjectCoordinatorTests: XCTestCase {
    func testNormalPathUsesFreshResolveBarrierRevalidationAndNormalEject() async throws {
        let fixture = Fixture()
        let refreshed = fixture.resolved(scopePath: "/Volumes/Fresh")
        await fixture.resolver.setRevalidations([.success(refreshed)])

        fixture.coordinator.begin(deviceID: fixture.target.deviceID, displayName: "T7", topologyGeneration: 9)

        try await waitUntil { fixture.coordinator.state == .succeeded(fixture.target) }
        let events = await fixture.events.snapshot()
        XCTAssertEqual(events, ["resolve", "acquire", "drain", "revalidate", "normal:disk4", "release"])
    }

    func testPreparationTimeoutNeverCallsEjectAndReleasesBarrier() async throws {
        let fixture = Fixture(barrierError: .timedOut)

        fixture.coordinator.begin(deviceID: fixture.target.deviceID, displayName: "T7", topologyGeneration: 9)

        try await waitUntil { fixture.coordinator.state.failure?.category == .timedOut }
        let normalBSDNames = await fixture.ejecter.normalCalls()
        let releaseCount = await fixture.barrier.releases()
        XCTAssertEqual(normalBSDNames, [])
        XCTAssertEqual(releaseCount, 1)
    }

    func testBarrierAcquisitionTimeoutFailsWithoutDispatchingEject() async throws {
        let fixture = Fixture(quiescerError: .timedOut)

        fixture.coordinator.begin(deviceID: fixture.target.deviceID, displayName: "T7", topologyGeneration: 9)

        try await waitUntil { fixture.coordinator.state.failure?.category == .timedOut }
        let normalBSDNames = await fixture.ejecter.normalCalls()
        XCTAssertEqual(normalBSDNames, [])
    }

    func testBusyFailureKeepsBarrierScansAndPersistsRecovery() async throws {
        let holder = OccupancyHolder(pid: 42, executableName: "Finder", displayName: nil, type: .openFileOrDirectory)
        let fixture = Fixture(normalResults: [.failure(Fixture.failure(.busy))], holders: [holder])

        fixture.coordinator.begin(deviceID: fixture.target.deviceID, displayName: "T7", topologyGeneration: 9)

        try await waitUntil { fixture.coordinator.state.recovery?.holders == [holder] }
        let releaseCount = await fixture.barrier.releases()
        let scopes = await fixture.scanner.scannedScopes()
        XCTAssertEqual(releaseCount, 0)
        XCTAssertEqual(scopes, [fixture.scope])
    }

    func testNonBusyFailureReleasesBarrierAndNeverOffersForce() async throws {
        let fixture = Fixture(normalResults: [.failure(Fixture.failure(.notPermitted))])

        fixture.coordinator.begin(deviceID: fixture.target.deviceID, displayName: "T7", topologyGeneration: 9)

        try await waitUntil { fixture.coordinator.state.failure?.category == .notPermitted }
        let releaseCount = await fixture.barrier.releases()
        XCTAssertEqual(releaseCount, 1)
        fixture.coordinator.requestForce()
        XCTAssertEqual(fixture.coordinator.state.failure?.category, .notPermitted)
        let forceBSDNames = await fixture.ejecter.forceCalls()
        XCTAssertEqual(forceBSDNames, [])
    }

    func testCancelClearsRecoveryAndReleasesBarrier() async throws {
        let fixture = Fixture(normalResults: [.failure(Fixture.failure(.busy))])
        fixture.coordinator.begin(deviceID: fixture.target.deviceID, displayName: "T7", topologyGeneration: 9)
        try await waitUntil { fixture.coordinator.state.recovery != nil }

        fixture.coordinator.cancel()

        try await waitUntil {
            guard fixture.coordinator.state == .idle else { return false }
            return await fixture.barrier.releases() == 1
        }
    }

    func testRetryRevalidatesAndUsesRefreshedScopeForBusyDiagnosis() async throws {
        let fixture = Fixture(normalResults: [
            .failure(Fixture.failure(.busy)),
            .failure(Fixture.failure(.busy))
        ])
        let retryScope = fixture.scope(path: "/Volumes/Retry")
        await fixture.resolver.setRevalidations([
            .success(fixture.resolved()),
            .success(.init(target: fixture.target, scope: retryScope))
        ])
        fixture.coordinator.begin(deviceID: fixture.target.deviceID, displayName: "T7", topologyGeneration: 9)
        try await waitUntil { (await fixture.scanner.scannedScopes()).count == 1 }

        fixture.coordinator.retry()

        try await waitUntil { (await fixture.scanner.scannedScopes()).count == 2 }
        let scopes = await fixture.scanner.scannedScopes()
        let normalBSDNames = await fixture.ejecter.normalCalls()
        let releaseCount = await fixture.barrier.releases()
        XCTAssertEqual(scopes.last, retryScope)
        XCTAssertEqual(normalBSDNames, ["disk4", "disk4"])
        XCTAssertEqual(releaseCount, 0)
    }

    func testForceRequestOnlyChangesConfirmationState() async throws {
        let fixture = Fixture(normalResults: [.failure(Fixture.failure(.busy))])
        fixture.coordinator.begin(deviceID: fixture.target.deviceID, displayName: "T7", topologyGeneration: 9)
        try await waitUntil { fixture.coordinator.state.recovery != nil }

        fixture.coordinator.requestForce()

        XCTAssertNotNil(fixture.coordinator.state.forceConfirmation)
        let forceBSDNames = await fixture.ejecter.forceCalls()
        let releaseCount = await fixture.barrier.releases()
        XCTAssertEqual(forceBSDNames, [])
        XCTAssertEqual(releaseCount, 0)
    }

    func testConfirmedForceRevalidatesThenForcesAndReleasesOnSuccess() async throws {
        let fixture = Fixture(normalResults: [.failure(Fixture.failure(.busy))])
        let refreshedScope = fixture.scope(path: "/Volumes/Force")
        await fixture.resolver.setRevalidations([
            .success(fixture.resolved()),
            .success(.init(target: fixture.target, scope: refreshedScope))
        ])
        fixture.coordinator.begin(deviceID: fixture.target.deviceID, displayName: "T7", topologyGeneration: 9)
        try await waitUntil { fixture.coordinator.state.recovery != nil }
        fixture.coordinator.requestForce()

        fixture.coordinator.confirmForce()

        try await waitUntil { fixture.coordinator.state == .succeeded(fixture.target) }
        let forceBSDNames = await fixture.ejecter.forceCalls()
        let revalidatedTargets = await fixture.resolver.revalidationCalls()
        let releaseCount = await fixture.barrier.releases()
        XCTAssertEqual(forceBSDNames, ["disk4"])
        XCTAssertEqual(revalidatedTargets.count, 2)
        XCTAssertEqual(releaseCount, 1)
    }

    func testForceFailureIsTerminalAndNeverSucceeds() async throws {
        let forceFailure = Fixture.failure(.io, stage: .forceUnmounting)
        let fixture = Fixture(
            normalResults: [.failure(Fixture.failure(.busy))],
            forceResults: [.failure(forceFailure)]
        )
        fixture.coordinator.begin(deviceID: fixture.target.deviceID, displayName: "T7", topologyGeneration: 9)
        try await waitUntil { fixture.coordinator.state.recovery != nil }
        fixture.coordinator.requestForce()
        fixture.coordinator.confirmForce()

        try await waitUntil { fixture.coordinator.state.failure == forceFailure }
        let releaseCount = await fixture.barrier.releases()
        XCTAssertEqual(releaseCount, 1)
    }

    func testSelectionChangesCannotRetargetCapturedWorkflow() async throws {
        let fixture = Fixture(normalResults: [.failure(Fixture.failure(.busy)), .success(())])
        fixture.coordinator.begin(deviceID: fixture.target.deviceID, displayName: "T7", topologyGeneration: 9)
        try await waitUntil { fixture.coordinator.state.recovery != nil }

        var appState = DrivePulseAppState(devices: [], selectedDeviceID: nil)
        appState.selectDevice(DeviceID(rawValue: "serial:other"))
        fixture.coordinator.retry()

        try await waitUntil { fixture.coordinator.state == .succeeded(fixture.target) }
        let revalidatedTargets = await fixture.resolver.revalidationCalls()
        let normalBSDNames = await fixture.ejecter.normalCalls()
        XCTAssertEqual(revalidatedTargets.last, fixture.target)
        XCTAssertEqual(normalBSDNames.last, "disk4")
    }

    func testReassignmentDuringRecoveryEndsAsDisappearedWithoutReplacementAction() async throws {
        let fixture = Fixture(normalResults: [.failure(Fixture.failure(.busy))])
        await fixture.resolver.setRevalidations([
            .success(fixture.resolved()),
            .failure(EjectTargetResolutionError.targetChanged)
        ])
        fixture.coordinator.begin(deviceID: fixture.target.deviceID, displayName: "T7", topologyGeneration: 9)
        try await waitUntil { fixture.coordinator.state.recovery != nil }

        fixture.coordinator.retry()

        try await waitUntil { fixture.coordinator.state == .disappeared(fixture.target) }
        let normalBSDNames = await fixture.ejecter.normalCalls()
        let forceBSDNames = await fixture.ejecter.forceCalls()
        let releaseCount = await fixture.barrier.releases()
        XCTAssertEqual(normalBSDNames, ["disk4"])
        XCTAssertEqual(forceBSDNames, [])
        XCTAssertEqual(releaseCount, 1)
    }

    func testTopologyChangeRevalidatesAndDisappearanceEndsNeutrally() async throws {
        let fixture = Fixture(normalResults: [.failure(Fixture.failure(.busy))])
        await fixture.resolver.setRevalidations([
            .success(fixture.resolved()),
            .failure(EjectTargetResolutionError.deviceNotFound)
        ])
        fixture.coordinator.begin(deviceID: fixture.target.deviceID, displayName: "T7", topologyGeneration: 9)
        try await waitUntil { fixture.coordinator.state.recovery != nil }

        fixture.coordinator.deviceTopologyDidChange(generation: 10)

        try await waitUntil { fixture.coordinator.state == .disappeared(fixture.target) }
        let releaseCount = await fixture.barrier.releases()
        XCTAssertEqual(releaseCount, 1)
    }

    func testSecondBeginIsIgnoredUntilFirstWorkflowReleases() async throws {
        let fixture = Fixture(normalResults: [.failure(Fixture.failure(.busy)), .success(()), .success(())])
        fixture.coordinator.begin(deviceID: fixture.target.deviceID, displayName: "T7", topologyGeneration: 9)
        try await waitUntil { fixture.coordinator.state.recovery != nil }

        fixture.coordinator.begin(
            deviceID: DeviceID(rawValue: "serial:other"),
            displayName: "Other",
            topologyGeneration: 10
        )
        let initialResolveCalls = await fixture.resolver.resolveCalls()
        XCTAssertEqual(initialResolveCalls, [fixture.target.deviceID])

        fixture.coordinator.retry()
        try await waitUntil { fixture.coordinator.state == .succeeded(fixture.target) }
        fixture.coordinator.begin(
            deviceID: DeviceID(rawValue: "serial:other"),
            displayName: "Other",
            topologyGeneration: 10
        )
        try await waitUntil { (await fixture.resolver.resolveCalls()).count == 2 }
        fixture.coordinator.cancel()
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @MainActor () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while await condition() == false {
            if clock.now >= deadline { XCTFail("Timed out waiting for coordinator state"); return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private extension EjectWorkflowState {
    var recovery: EjectRecoveryState? {
        guard case .awaitingRecovery(let recovery) = self else { return nil }
        return recovery
    }

    var forceConfirmation: EjectRecoveryState? {
        guard case .awaitingForceConfirmation(let recovery) = self else { return nil }
        return recovery
    }

    var failure: EjectFailure? {
        guard case .failed(_, let failure) = self else { return nil }
        return failure
    }
}

@MainActor
private final class Fixture {
    let target = EjectWorkflowTarget(
        deviceID: DeviceID(rawValue: "serial:t7"),
        physicalBSDName: "disk4",
        mediaRegistryEntryID: 4_001,
        displayName: "T7",
        topologyGeneration: 9
    )
    let events = EventLog()
    let resolver: ResolverSpy
    let barrier: BarrierSpy
    let quiescer: QuiescerSpy
    let ejecter: EjecterSpy
    let scanner: ScannerSpy
    let coordinator: EjectCoordinator

    var scope: OccupancyTargetScope { scope(path: "/Volumes/T7") }

    init(
        barrierError: DeviceIOQuiescenceError? = nil,
        quiescerError: DeviceIOQuiescenceError? = nil,
        normalResults: [Result<Void, EjectFailure>] = [.success(())],
        forceResults: [Result<Void, EjectFailure>] = [.success(())],
        holders: [OccupancyHolder] = []
    ) {
        let target = self.target
        let scope = OccupancyTargetScope(
            physicalBSDName: "disk4",
            deviceNodes: ["/dev/disk4"],
            mountURLs: [URL(fileURLWithPath: "/Volumes/T7")]
        )
        resolver = ResolverSpy(resolved: .init(target: target, scope: scope), events: events)
        barrier = BarrierSpy(waitError: barrierError, events: events)
        quiescer = QuiescerSpy(barrier: barrier, error: quiescerError, events: events)
        ejecter = EjecterSpy(normalResults: normalResults, forceResults: forceResults, events: events)
        scanner = ScannerSpy(result: .init(holders: holders, isComplete: true), events: events)
        coordinator = EjectCoordinator(
            resolver: resolver,
            quiescer: quiescer,
            ejecter: ejecter,
            occupancyScanner: scanner,
            preparationTimeout: .seconds(1)
        )
    }

    func scope(path: String) -> OccupancyTargetScope {
        .init(physicalBSDName: "disk4", deviceNodes: ["/dev/disk4"], mountURLs: [URL(fileURLWithPath: path)])
    }

    func resolved(scopePath: String = "/Volumes/T7") -> ResolvedEjectTarget {
        .init(target: target, scope: scope(path: scopePath))
    }

    static func failure(
        _ category: EjectFailureCategory,
        stage: EjectOperationStage = .unmounting
    ) -> EjectFailure {
        .init(stage: stage, category: category, rawStatus: nil, systemMessage: nil, physicalBSDName: "disk4", holders: [])
    }
}

private actor EventLog {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
    func snapshot() -> [String] { values }
}

private actor ResolverSpy: EjectTargetResolving {
    private let resolved: ResolvedEjectTarget
    private let events: EventLog
    private var revalidations: [Result<ResolvedEjectTarget, Error>] = []
    private(set) var resolveDeviceIDs: [DeviceID] = []
    private(set) var revalidatedTargets: [EjectWorkflowTarget] = []

    init(resolved: ResolvedEjectTarget, events: EventLog) {
        self.resolved = resolved
        self.events = events
    }

    func setRevalidations(_ values: [Result<ResolvedEjectTarget, Error>]) { revalidations = values }
    func resolveCalls() -> [DeviceID] { resolveDeviceIDs }
    func revalidationCalls() -> [EjectWorkflowTarget] { revalidatedTargets }

    func resolve(deviceID: DeviceID, displayName: String, topologyGeneration: Int) async throws -> ResolvedEjectTarget {
        resolveDeviceIDs.append(deviceID)
        await events.append("resolve")
        return resolved
    }

    func revalidate(_ target: EjectWorkflowTarget) async throws -> ResolvedEjectTarget {
        revalidatedTargets.append(target)
        await events.append("revalidate")
        guard revalidations.isEmpty == false else { return resolved }
        return try revalidations.removeFirst().get()
    }
}

private actor BarrierSpy: EjectBarrier {
    private let waitError: DeviceIOQuiescenceError?
    private let events: EventLog
    private(set) var releaseCount = 0

    init(waitError: DeviceIOQuiescenceError?, events: EventLog) {
        self.waitError = waitError
        self.events = events
    }

    func waitUntilReady() async throws {
        await events.append("drain")
        if let waitError { throw waitError }
    }

    func release() async {
        releaseCount += 1
        await events.append("release")
    }

    func releases() -> Int { releaseCount }
}

private actor QuiescerSpy: DeviceIOQuiescing {
    private let barrier: BarrierSpy
    private let error: DeviceIOQuiescenceError?
    private let events: EventLog

    init(barrier: BarrierSpy, error: DeviceIOQuiescenceError?, events: EventLog) {
        self.barrier = barrier
        self.error = error
        self.events = events
    }

    func acquireBarrier(
        for target: EjectWorkflowTarget,
        timeout: Duration
    ) async throws(DeviceIOQuiescenceError) -> any EjectBarrier {
        await events.append("acquire")
        if let error { throw error }
        return barrier
    }
}

private actor EjecterSpy: DiskEjecting {
    private var normalResults: [Result<Void, EjectFailure>]
    private var forceResults: [Result<Void, EjectFailure>]
    private let events: EventLog
    private(set) var normalBSDNames: [String] = []
    private(set) var forceBSDNames: [String] = []

    init(normalResults: [Result<Void, EjectFailure>], forceResults: [Result<Void, EjectFailure>], events: EventLog) {
        self.normalResults = normalResults
        self.forceResults = forceResults
        self.events = events
    }

    func performNormalEject(bsdName: String) async -> Result<Void, EjectFailure> {
        normalBSDNames.append(bsdName)
        await events.append("normal:\(bsdName)")
        return normalResults.removeFirst()
    }

    func performConfirmedForceEject(bsdName: String) async -> Result<Void, EjectFailure> {
        forceBSDNames.append(bsdName)
        await events.append("force:\(bsdName)")
        return forceResults.removeFirst()
    }

    func normalCalls() -> [String] { normalBSDNames }
    func forceCalls() -> [String] { forceBSDNames }
}

private actor ScannerSpy: OccupancyScanning {
    private let result: OccupancyScanResult
    private let events: EventLog
    private(set) var scopes: [OccupancyTargetScope] = []

    init(result: OccupancyScanResult, events: EventLog) {
        self.result = result
        self.events = events
    }

    func scan(workflowID: UUID, scope: OccupancyTargetScope) async -> OccupancyScanResult {
        scopes.append(scope)
        await events.append("scan")
        return result
    }

    func scannedScopes() -> [OccupancyTargetScope] { scopes }
}
