import XCTest

import PalmosCore

@testable import PalmosApp

@MainActor
final class EjectCoordinatorTests: XCTestCase {
    func testBeginImmediatelyPublishesVisiblePreparationBeforeResolveCompletes() async throws {
        let resolveGate = AsyncGate()
        let fixture = Fixture(resolveGate: resolveGate)

        fixture.coordinator.begin(
            deviceID: fixture.target.deviceID,
            displayName: fixture.target.displayName,
            topologyGeneration: 9
        )

        guard case .preparing(let request) = fixture.coordinator.state else {
            return XCTFail("Initial eject must publish preparation before live resolution completes")
        }
        XCTAssertEqual(request.deviceID, fixture.target.deviceID)
        XCTAssertEqual(request.displayName, fixture.target.displayName)

        await resolveGate.open()
        try await waitUntil { fixture.coordinator.state == .succeeded(fixture.target) }
    }

    func testInitialResolutionFailuresRemainVisibleAndStructured() async throws {
        for resolutionError in [
            EjectTargetResolutionError.deviceNotFound,
            .unsafeMedia,
            .incompleteMediaIdentity,
            .targetChanged
        ] {
            let fixture = Fixture(resolveResult: .failure(resolutionError))

            fixture.coordinator.begin(
                deviceID: fixture.target.deviceID,
                displayName: fixture.target.displayName,
                topologyGeneration: 9
            )

            try await waitUntil {
                if case .resolutionFailed = fixture.coordinator.state { return true }
                return false
            }
            guard case .resolutionFailed(let request, let failure) = fixture.coordinator.state else {
                return XCTFail("Expected a visible resolution failure")
            }
            XCTAssertEqual(request.deviceID, fixture.target.deviceID)
            XCTAssertEqual(request.displayName, fixture.target.displayName)
            XCTAssertEqual(failure.stage, .preparing)
            XCTAssertNotEqual(failure.category, .busy)
        }
    }

    func testNormalPathUsesFreshResolveBarrierRevalidationAndNormalEject() async throws {
        let fixture = Fixture()
        let refreshed = fixture.resolved(
            scopePath: "/Volumes/Fresh",
            logicalWholeDiskBSDName: "disk8"
        )
        await fixture.resolver.setRevalidations([.success(refreshed)])

        fixture.coordinator.begin(deviceID: fixture.target.deviceID, displayName: "T7", topologyGeneration: 9)

        try await waitUntil { fixture.coordinator.state == .succeeded(fixture.target) }
        let events = await fixture.events.snapshot()
        let plans = await fixture.ejecter.normalPlans()
        XCTAssertEqual(events, ["resolve", "acquire", "drain", "revalidate", "normal:disk4", "release"])
        XCTAssertEqual(plans, [refreshed.operationPlan])
    }

    func testAdapterTargetInvalidationMapsToDeviceDisappeared() async throws {
        let fixture = Fixture(normalResults: [.targetInvalidated(stage: .ejecting)])

        fixture.coordinator.begin(
            deviceID: fixture.target.deviceID,
            displayName: fixture.target.displayName,
            topologyGeneration: 9
        )

        try await waitUntil { fixture.coordinator.state == .disappeared(fixture.target) }
        let releases = await fixture.barrier.releases()
        XCTAssertEqual(releases, 1)
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

    func testUnobservableSMARTCompletionFailsExplicitlyWithoutEject() async throws {
        let fixture = Fixture(barrierError: .legacySMARTCompletionUnobservable)

        fixture.coordinator.begin(
            deviceID: fixture.target.deviceID,
            displayName: "T7",
            topologyGeneration: 9
        )

        try await waitUntil {
            fixture.coordinator.state.failure?.category == .smartCompletionUnobservable
        }
        let normalCalls = await fixture.ejecter.normalCalls()
        let releases = await fixture.barrier.releases()
        XCTAssertEqual(normalCalls, [])
        XCTAssertEqual(releases, 1)
    }

    func testBarrierAcquisitionTimeoutFailsWithoutDispatchingEject() async throws {
        let fixture = Fixture(quiescerError: .timedOut)

        fixture.coordinator.begin(deviceID: fixture.target.deviceID, displayName: "T7", topologyGeneration: 9)

        try await waitUntil { fixture.coordinator.state.failure?.category == .timedOut }
        let normalBSDNames = await fixture.ejecter.normalCalls()
        XCTAssertEqual(normalBSDNames, [])
    }

    func testTopologyAdvanceDuringResolveSelfValidatesLatestGenerationAndContinues() async throws {
        let resolveGate = AsyncGate()
        let fixture = Fixture(resolveGate: resolveGate)
        await fixture.resolver.setRevalidations([.success(fixture.resolved(scopePath: "/Volumes/Latest"))])
        fixture.coordinator.begin(deviceID: fixture.target.deviceID, displayName: "T7", topologyGeneration: 9)
        try await waitUntil { (await fixture.events.snapshot()).contains("resolve") }

        fixture.coordinator.deviceTopologyDidChange(generation: 10)
        await resolveGate.open()

        try await waitUntil { fixture.coordinator.state == .succeeded(fixture.target) }
        let normalCalls = await fixture.ejecter.normalCalls()
        let revalidationCalls = await fixture.resolver.revalidationCalls()
        XCTAssertEqual(normalCalls, ["disk4"])
        XCTAssertEqual(revalidationCalls.count, 1)
    }

    func testReassignmentDuringBarrierAcquisitionEndsNeutrallyWithoutEject() async throws {
        let acquireGate = AsyncGate()
        let fixture = Fixture(quiescerAcquireGate: acquireGate)
        await fixture.resolver.setRevalidations([.failure(EjectTargetResolutionError.targetChanged)])
        fixture.coordinator.begin(deviceID: fixture.target.deviceID, displayName: "T7", topologyGeneration: 9)
        try await waitUntil { (await fixture.events.snapshot()).contains("acquire") }

        fixture.coordinator.deviceTopologyDidChange(generation: 10)
        await acquireGate.open()

        try await waitUntil { fixture.coordinator.state == .disappeared(fixture.target) }
        let normalCalls = await fixture.ejecter.normalCalls()
        let forceCalls = await fixture.ejecter.forceCalls()
        XCTAssertEqual(normalCalls, [])
        XCTAssertEqual(forceCalls, [])
    }

    func testBusyFailureScansBeforeReleasingBarrierAndPublishingRecovery() async throws {
        let holder = OccupancyHolder(pid: 42, executableName: "Finder", displayName: nil, type: .openFileOrDirectory)
        let releaseGate = AsyncGate()
        let fixture = Fixture(
            normalResults: [.failure(Fixture.failure(.busy))],
            holders: [holder],
            releaseGate: releaseGate
        )

        fixture.coordinator.begin(deviceID: fixture.target.deviceID, displayName: "T7", topologyGeneration: 9)

        try await waitUntil { await fixture.barrier.releases() == 1 }
        XCTAssertNil(fixture.coordinator.state.recovery)
        await releaseGate.open()
        try await waitUntil { fixture.coordinator.state.recovery?.holders == [holder] }
        let releaseCount = await fixture.barrier.releases()
        let scopes = await fixture.scanner.scannedScopes()
        XCTAssertEqual(releaseCount, 1)
        XCTAssertEqual(scopes, [fixture.scope])
    }

    func testBusyFailureWithDissentingHolderSkipsOccupancyScan() async throws {
        let holder = OccupancyHolder(
            pid: 501,
            executableName: "Finder",
            displayName: "Finder",
            type: .unknown
        )
        let failure = EjectFailure(
            stage: .unmounting,
            category: .busy,
            rawStatus: EBUSY,
            systemMessage: "Volume is in use",
            physicalBSDName: "disk4",
            holders: [holder]
        )
        let fixture = Fixture(normalResults: [.failure(failure)])

        fixture.coordinator.begin(deviceID: fixture.target.deviceID, displayName: "T7", topologyGeneration: 9)

        try await waitUntil { fixture.coordinator.state.recovery != nil }
        XCTAssertEqual(fixture.coordinator.state.recovery?.holders, [holder])
        XCTAssertEqual(fixture.coordinator.state.recovery?.failure.holders, [holder])
        let scannedScopes = await fixture.scanner.scannedScopes()
        XCTAssertEqual(scannedScopes, [])
    }

    func testEjectingStageBusyFailureEntersRecovery() async throws {
        let failure = Fixture.failure(.busy, stage: .ejecting)
        let fixture = Fixture(normalResults: [.failure(failure)])

        fixture.coordinator.begin(deviceID: fixture.target.deviceID, displayName: "T7", topologyGeneration: 9)

        try await waitUntil { fixture.coordinator.state.recovery?.failure == failure }
        fixture.coordinator.requestForce()
        XCTAssertNotNil(fixture.coordinator.state.forceConfirmation)
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
        XCTAssertEqual(releaseCount, 2)
    }

    func testRetryRetainsRecoveryWhileNormalEjectIsInFlight() async throws {
        let retryGate = AsyncGate()
        let holder = OccupancyHolder(
            pid: 42,
            executableName: "Finder",
            displayName: nil,
            type: .openFileOrDirectory
        )
        let fixture = Fixture(
            normalResults: [.failure(Fixture.failure(.busy)), .success(())],
            holders: [holder],
            normalGates: [nil, retryGate]
        )
        fixture.coordinator.begin(
            deviceID: fixture.target.deviceID,
            displayName: "T7",
            topologyGeneration: 9
        )
        try await waitUntil { fixture.coordinator.state.recovery?.holders == [holder] }

        fixture.coordinator.retry()

        try await waitUntil { (await fixture.ejecter.normalCalls()).count == 2 }
        XCTAssertEqual(fixture.coordinator.retainedRecovery?.holders, [holder])
        guard case .working(_, .unmounting) = fixture.coordinator.state else {
            return XCTFail("Expected retry to remain visibly in flight")
        }

        await retryGate.open()
        try await waitUntil { fixture.coordinator.state == .succeeded(fixture.target) }
        XCTAssertNil(fixture.coordinator.retainedRecovery)
    }

    func testRetryImmediatelyEntersWorkingStateDuringRevalidation() async throws {
        let revalidationGate = AsyncGate()
        let fixture = Fixture(
            normalResults: [.failure(Fixture.failure(.busy)), .success(())]
        )
        fixture.coordinator.begin(
            deviceID: fixture.target.deviceID,
            displayName: "T7",
            topologyGeneration: 9
        )
        try await waitUntil { fixture.coordinator.state.recovery != nil }
        await fixture.resolver.setRevalidationGates([revalidationGate])

        fixture.coordinator.retry()
        fixture.coordinator.retry()

        guard case .working(_, .preparing) = fixture.coordinator.state else {
            return XCTFail("Retry must show progress before revalidation completes")
        }
        try await waitUntil { (await fixture.resolver.revalidationCalls()).count == 2 }
        let retryRevalidations = await fixture.resolver.revalidationCalls()
        XCTAssertEqual(retryRevalidations.count, 2)
        await revalidationGate.open()
        try await waitUntil { fixture.coordinator.state == .succeeded(fixture.target) }
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
        XCTAssertEqual(releaseCount, 1)
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
        XCTAssertEqual(releaseCount, 2)
    }

    func testConfirmedForceRetainsRecoveryWhileForceEjectIsInFlight() async throws {
        let forceGate = AsyncGate()
        let holder = OccupancyHolder(
            pid: 42,
            executableName: "Finder",
            displayName: nil,
            type: .openFileOrDirectory
        )
        let fixture = Fixture(
            normalResults: [.failure(Fixture.failure(.busy))],
            holders: [holder],
            forceGate: forceGate
        )
        fixture.coordinator.begin(
            deviceID: fixture.target.deviceID,
            displayName: "T7",
            topologyGeneration: 9
        )
        try await waitUntil { fixture.coordinator.state.recovery?.holders == [holder] }
        fixture.coordinator.requestForce()

        fixture.coordinator.confirmForce()

        try await waitUntil { (await fixture.ejecter.forceCalls()).count == 1 }
        XCTAssertEqual(fixture.coordinator.retainedRecovery?.holders, [holder])
        guard case .working(_, .forceUnmounting) = fixture.coordinator.state else {
            return XCTFail("Expected force eject to remain visibly in flight")
        }

        await forceGate.open()
        try await waitUntil { fixture.coordinator.state == .succeeded(fixture.target) }
        XCTAssertNil(fixture.coordinator.retainedRecovery)
    }

    func testConfirmedForceImmediatelyEntersWorkingStateDuringRevalidation() async throws {
        let revalidationGate = AsyncGate()
        let fixture = Fixture(normalResults: [.failure(Fixture.failure(.busy))])
        fixture.coordinator.begin(
            deviceID: fixture.target.deviceID,
            displayName: "T7",
            topologyGeneration: 9
        )
        try await waitUntil { fixture.coordinator.state.recovery != nil }
        fixture.coordinator.requestForce()
        await fixture.resolver.setRevalidationGates([revalidationGate])

        fixture.coordinator.confirmForce()
        fixture.coordinator.confirmForce()

        guard case .working(_, .preparing) = fixture.coordinator.state else {
            return XCTFail("Force eject must show progress before revalidation completes")
        }
        try await waitUntil { (await fixture.resolver.revalidationCalls()).count == 2 }
        let forceRevalidations = await fixture.resolver.revalidationCalls()
        XCTAssertEqual(forceRevalidations.count, 2)
        await revalidationGate.open()
        try await waitUntil { fixture.coordinator.state == .succeeded(fixture.target) }
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
        XCTAssertEqual(releaseCount, 2)
    }

    func testSelectionChangesCannotRetargetCapturedWorkflow() async throws {
        let fixture = Fixture(normalResults: [.failure(Fixture.failure(.busy)), .success(())])
        fixture.coordinator.begin(deviceID: fixture.target.deviceID, displayName: "T7", topologyGeneration: 9)
        try await waitUntil { fixture.coordinator.state.recovery != nil }

        var appState = PalmosAppState(devices: [], selectedDeviceID: nil)
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
        XCTAssertEqual(releaseCount, 2)
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

    func testRecoveryTopologyRevalidationFromMountedToUnmountedEndsIdle() async throws {
        let fixture = Fixture(normalResults: [.failure(Fixture.failure(.busy))])
        await fixture.resolver.setRevalidations([
            .success(fixture.resolved()),
            .success(fixture.resolvedWithNoMounts())
        ])
        fixture.coordinator.begin(deviceID: fixture.target.deviceID, displayName: "T7", topologyGeneration: 9)
        try await waitUntil { fixture.coordinator.state.recovery != nil }

        fixture.coordinator.deviceTopologyDidChange(generation: 10)

        try await waitUntil { fixture.coordinator.state == .externallyUnmounted(fixture.target) }
        XCTAssertNil(fixture.coordinator.retainedRecovery)
    }

    func testUnmountObservedDuringOccupancyScanPreventsStaleRecoveryPublication() async throws {
        let scanGate = AsyncGate()
        let fixture = Fixture(
            normalResults: [.failure(Fixture.failure(.busy))],
            scanGate: scanGate
        )
        await fixture.resolver.setRevalidations([
            .success(fixture.resolved()),
            .success(fixture.resolvedWithNoMounts())
        ])
        fixture.coordinator.begin(
            deviceID: fixture.target.deviceID,
            displayName: "T7",
            topologyGeneration: 9
        )
        try await waitUntil { (await fixture.scanner.scannedScopes()).count == 1 }

        fixture.coordinator.deviceTopologyDidChange(generation: 10)
        try await waitUntil { (await fixture.resolver.revalidationCalls()).count == 2 }
        await scanGate.open()

        try await waitUntil { fixture.coordinator.state == .externallyUnmounted(fixture.target) }
        XCTAssertNil(fixture.coordinator.retainedRecovery)
    }

    func testForceConfirmationTopologyRevalidationFromMountedToUnmountedEndsIdle() async throws {
        let fixture = Fixture(normalResults: [.failure(Fixture.failure(.busy))])
        await fixture.resolver.setRevalidations([
            .success(fixture.resolved()),
            .success(fixture.resolvedWithNoMounts())
        ])
        fixture.coordinator.begin(deviceID: fixture.target.deviceID, displayName: "T7", topologyGeneration: 9)
        try await waitUntil { fixture.coordinator.state.recovery != nil }
        fixture.coordinator.requestForce()

        fixture.coordinator.deviceTopologyDidChange(generation: 10)

        try await waitUntil { fixture.coordinator.state == .externallyUnmounted(fixture.target) }
        XCTAssertNil(fixture.coordinator.retainedRecovery)
    }

    func testRecoveryTopologyRevalidationWithMountedScopeKeepsRecoveryVisible() async throws {
        let fixture = Fixture(normalResults: [.failure(Fixture.failure(.busy))])
        await fixture.resolver.setRevalidations([
            .success(fixture.resolved()),
            .success(fixture.resolved(scopePath: "/Volumes/Renamed"))
        ])
        fixture.coordinator.begin(deviceID: fixture.target.deviceID, displayName: "T7", topologyGeneration: 9)
        try await waitUntil { fixture.coordinator.state.recovery != nil }

        fixture.coordinator.deviceTopologyDidChange(generation: 10)

        try await waitUntil { (await fixture.resolver.revalidationCalls()).count == 2 }
        XCTAssertNotNil(fixture.coordinator.state.recovery)
    }

    func testValidTopologyChangeDuringBarrierDrainDoesNotCancelNormalFlow() async throws {
        let drainGate = AsyncGate()
        let fixture = Fixture(barrierWaitGate: drainGate)
        await fixture.resolver.setRevalidations([.success(fixture.resolved()), .success(fixture.resolved())])
        fixture.coordinator.begin(deviceID: fixture.target.deviceID, displayName: "T7", topologyGeneration: 9)
        try await waitUntil { (await fixture.events.snapshot()).contains("drain") }

        fixture.coordinator.deviceTopologyDidChange(generation: 10)
        try await waitUntil { (await fixture.resolver.revalidationCalls()).count == 1 }
        await drainGate.open()

        try await waitUntil { fixture.coordinator.state == .succeeded(fixture.target) }
        let normalCalls = await fixture.ejecter.normalCalls()
        XCTAssertEqual(normalCalls, ["disk4"])
    }

    func testTopologyChangeIgnoresNonNewGenerations() async throws {
        let scanGate = AsyncGate()
        let fixture = Fixture(normalResults: [.failure(Fixture.failure(.busy))], scanGate: scanGate)
        await fixture.resolver.setRevalidations([.success(fixture.resolved()), .success(fixture.resolved())])
        fixture.coordinator.begin(deviceID: fixture.target.deviceID, displayName: "T7", topologyGeneration: 9)
        try await waitUntil { (await fixture.scanner.scannedScopes()).count == 1 }

        fixture.coordinator.deviceTopologyDidChange(generation: 9)
        fixture.coordinator.deviceTopologyDidChange(generation: 8)
        try await Task.sleep(for: .milliseconds(20))
        let callsBeforeNewGeneration = await fixture.resolver.revalidationCalls()
        XCTAssertEqual(callsBeforeNewGeneration.count, 1)

        fixture.coordinator.deviceTopologyDidChange(generation: 10)
        try await waitUntil { (await fixture.resolver.revalidationCalls()).count == 2 }
        await scanGate.open()
        try await waitUntil { fixture.coordinator.state.recovery != nil }
    }

    func testValidTopologyChangeDuringNormalEjectDoesNotCancelOperation() async throws {
        let normalGate = AsyncGate()
        let fixture = Fixture(normalGate: normalGate)
        await fixture.resolver.setRevalidations([.success(fixture.resolved()), .success(fixture.resolved())])
        fixture.coordinator.begin(deviceID: fixture.target.deviceID, displayName: "T7", topologyGeneration: 9)
        try await waitUntil { (await fixture.ejecter.normalCalls()).count == 1 }

        fixture.coordinator.deviceTopologyDidChange(generation: 10)
        try await waitUntil { (await fixture.resolver.revalidationCalls()).count == 2 }
        await normalGate.open()

        try await waitUntil { fixture.coordinator.state == .succeeded(fixture.target) }
    }

    func testValidTopologyChangeDuringForceEjectDoesNotCancelOperation() async throws {
        let forceGate = AsyncGate()
        let fixture = Fixture(normalResults: [.failure(Fixture.failure(.busy))], forceGate: forceGate)
        await fixture.resolver.setRevalidations([
            .success(fixture.resolved()),
            .success(fixture.resolved()),
            .success(fixture.resolved())
        ])
        fixture.coordinator.begin(deviceID: fixture.target.deviceID, displayName: "T7", topologyGeneration: 9)
        try await waitUntil { fixture.coordinator.state.recovery != nil }
        fixture.coordinator.requestForce()
        fixture.coordinator.confirmForce()
        try await waitUntil { (await fixture.ejecter.forceCalls()).count == 1 }

        fixture.coordinator.deviceTopologyDidChange(generation: 10)
        try await waitUntil { (await fixture.resolver.revalidationCalls()).count == 3 }
        await forceGate.open()

        try await waitUntil { fixture.coordinator.state == .succeeded(fixture.target) }
    }

    func testValidTopologyChangeDuringOccupancyScanDoesNotCancelRecovery() async throws {
        let scanGate = AsyncGate()
        let fixture = Fixture(normalResults: [.failure(Fixture.failure(.busy))], scanGate: scanGate)
        await fixture.resolver.setRevalidations([.success(fixture.resolved()), .success(fixture.resolved())])
        fixture.coordinator.begin(deviceID: fixture.target.deviceID, displayName: "T7", topologyGeneration: 9)
        try await waitUntil { (await fixture.scanner.scannedScopes()).count == 1 }

        fixture.coordinator.deviceTopologyDidChange(generation: 10)
        try await waitUntil { (await fixture.resolver.revalidationCalls()).count == 2 }
        await scanGate.open()

        try await waitUntil { fixture.coordinator.state.recovery != nil }
        let releases = await fixture.barrier.releases()
        XCTAssertEqual(releases, 1)
    }

    func testInvalidTopologyDuringNormalEjectEndsNeutrallyWithoutReplacementAction() async throws {
        let normalGate = AsyncGate()
        let fixture = Fixture(normalGate: normalGate)
        await fixture.resolver.setRevalidations([
            .success(fixture.resolved()),
            .failure(EjectTargetResolutionError.targetChanged)
        ])
        fixture.coordinator.begin(deviceID: fixture.target.deviceID, displayName: "T7", topologyGeneration: 9)
        try await waitUntil { (await fixture.ejecter.normalCalls()).count == 1 }

        fixture.coordinator.deviceTopologyDidChange(generation: 10)

        try await waitUntil { fixture.coordinator.state == .disappeared(fixture.target) }
        await normalGate.open()
        try await Task.sleep(for: .milliseconds(20))
        let normalCalls = await fixture.ejecter.normalCalls()
        let forceCalls = await fixture.ejecter.forceCalls()
        XCTAssertEqual(fixture.coordinator.state, .disappeared(fixture.target))
        XCTAssertEqual(normalCalls, ["disk4"])
        XCTAssertEqual(forceCalls, [])
    }

    func testNormalRevalidationDoesNotDispatchWhenTopologyAdvancesWhileItIsSuspended() async throws {
        let staleRevalidationGate = AsyncGate()
        let topologyGate = AsyncGate()
        let fixture = Fixture()
        await fixture.resolver.setRevalidations([
            .success(fixture.resolved()),
            .failure(EjectTargetResolutionError.targetChanged)
        ])
        await fixture.resolver.setRevalidationGates([staleRevalidationGate, topologyGate])
        fixture.coordinator.begin(deviceID: fixture.target.deviceID, displayName: "T7", topologyGeneration: 9)
        try await waitUntil { (await fixture.resolver.revalidationCalls()).count == 1 }

        fixture.coordinator.deviceTopologyDidChange(generation: 10)
        try await waitUntil { (await fixture.resolver.revalidationCalls()).count == 2 }
        await staleRevalidationGate.open()
        try await Task.sleep(for: .milliseconds(20))

        let callsBeforeCurrentValidation = await fixture.ejecter.normalCalls()
        XCTAssertEqual(callsBeforeCurrentValidation, [])
        await topologyGate.open()
        try await waitUntil { fixture.coordinator.state == .disappeared(fixture.target) }
        let finalNormalCalls = await fixture.ejecter.normalCalls()
        XCTAssertEqual(finalNormalCalls.count, 0)
    }

    func testForceRevalidationDoesNotDispatchWhenTopologyAdvancesWhileItIsSuspended() async throws {
        let initialGate = AsyncGate()
        let staleRevalidationGate = AsyncGate()
        let topologyGate = AsyncGate()
        await initialGate.open()
        let fixture = Fixture(normalResults: [.failure(Fixture.failure(.busy))])
        await fixture.resolver.setRevalidations([
            .success(fixture.resolved()),
            .success(fixture.resolved()),
            .failure(EjectTargetResolutionError.targetChanged)
        ])
        await fixture.resolver.setRevalidationGates([initialGate, staleRevalidationGate, topologyGate])
        fixture.coordinator.begin(deviceID: fixture.target.deviceID, displayName: "T7", topologyGeneration: 9)
        try await waitUntil { fixture.coordinator.state.recovery != nil }
        fixture.coordinator.requestForce()
        fixture.coordinator.confirmForce()
        try await waitUntil { (await fixture.resolver.revalidationCalls()).count == 2 }

        fixture.coordinator.deviceTopologyDidChange(generation: 10)
        try await waitUntil { (await fixture.resolver.revalidationCalls()).count == 3 }
        await staleRevalidationGate.open()
        try await Task.sleep(for: .milliseconds(20))

        let callsBeforeCurrentValidation = await fixture.ejecter.forceCalls()
        XCTAssertEqual(callsBeforeCurrentValidation, [])
        await topologyGate.open()
        try await waitUntil { fixture.coordinator.state == .disappeared(fixture.target) }
        let finalForceCalls = await fixture.ejecter.forceCalls()
        XCTAssertEqual(finalForceCalls.count, 0)
    }

    func testInvalidTopologyDuringBarrierDrainEndsNeutrallyWithoutDispatchingEject() async throws {
        let drainGate = AsyncGate()
        let fixture = Fixture(barrierWaitGate: drainGate)
        await fixture.resolver.setRevalidations([.failure(EjectTargetResolutionError.deviceNotFound)])
        fixture.coordinator.begin(deviceID: fixture.target.deviceID, displayName: "T7", topologyGeneration: 9)
        try await waitUntil { (await fixture.events.snapshot()).contains("drain") }

        fixture.coordinator.deviceTopologyDidChange(generation: 10)

        try await waitUntil { fixture.coordinator.state == .disappeared(fixture.target) }
        await drainGate.open()
        try await Task.sleep(for: .milliseconds(20))
        let normalCalls = await fixture.ejecter.normalCalls()
        XCTAssertEqual(fixture.coordinator.state, .disappeared(fixture.target))
        XCTAssertEqual(normalCalls, [])
    }

    func testInvalidTopologyDuringForceEjectEndsNeutrallyWithoutSecondAction() async throws {
        let forceGate = AsyncGate()
        let fixture = Fixture(normalResults: [.failure(Fixture.failure(.busy))], forceGate: forceGate)
        await fixture.resolver.setRevalidations([
            .success(fixture.resolved()),
            .success(fixture.resolved()),
            .failure(EjectTargetResolutionError.targetChanged)
        ])
        fixture.coordinator.begin(deviceID: fixture.target.deviceID, displayName: "T7", topologyGeneration: 9)
        try await waitUntil { fixture.coordinator.state.recovery != nil }
        fixture.coordinator.requestForce()
        fixture.coordinator.confirmForce()
        try await waitUntil { (await fixture.ejecter.forceCalls()).count == 1 }

        fixture.coordinator.deviceTopologyDidChange(generation: 10)

        try await waitUntil { fixture.coordinator.state == .disappeared(fixture.target) }
        await forceGate.open()
        try await Task.sleep(for: .milliseconds(20))
        let normalCalls = await fixture.ejecter.normalCalls()
        let forceCalls = await fixture.ejecter.forceCalls()
        XCTAssertEqual(fixture.coordinator.state, .disappeared(fixture.target))
        XCTAssertEqual(normalCalls, ["disk4"])
        XCTAssertEqual(forceCalls, ["disk4"])
    }

    func testInvalidTopologyDuringOccupancyScanEndsNeutrallyWithoutRecoveryOverwrite() async throws {
        let scanGate = AsyncGate()
        let fixture = Fixture(normalResults: [.failure(Fixture.failure(.busy))], scanGate: scanGate)
        await fixture.resolver.setRevalidations([
            .success(fixture.resolved()),
            .failure(EjectTargetResolutionError.deviceNotFound)
        ])
        fixture.coordinator.begin(deviceID: fixture.target.deviceID, displayName: "T7", topologyGeneration: 9)
        try await waitUntil { (await fixture.scanner.scannedScopes()).count == 1 }

        fixture.coordinator.deviceTopologyDidChange(generation: 10)

        try await waitUntil { fixture.coordinator.state == .disappeared(fixture.target) }
        await scanGate.open()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(fixture.coordinator.state, .disappeared(fixture.target))
    }

    func testCancelDuringSuspendedSuccessReleasePreventsStaleTerminalOverwrite() async throws {
        let releaseGate = AsyncGate()
        let fixture = Fixture(
            normalResults: [.success(()), .failure(Fixture.failure(.busy))],
            releaseGate: releaseGate
        )
        fixture.coordinator.begin(deviceID: fixture.target.deviceID, displayName: "T7", topologyGeneration: 9)
        try await waitUntil { await fixture.barrier.releases() == 1 }

        fixture.coordinator.cancel()
        XCTAssertNotEqual(fixture.coordinator.state, .idle)
        await releaseGate.open()
        try await waitUntil { fixture.coordinator.state == .idle }
        fixture.coordinator.begin(deviceID: fixture.target.deviceID, displayName: "T7", topologyGeneration: 10)
        try await waitUntil { fixture.coordinator.state.recovery != nil }
        try await Task.sleep(for: .milliseconds(20))

        let releases = await fixture.barrier.releases()
        XCTAssertNotNil(fixture.coordinator.state.recovery)
        XCTAssertEqual(releases, 2)
        fixture.coordinator.cancel()
    }

    func testCancelDuringSuspendedFailureReleasePreventsStaleTerminalOverwrite() async throws {
        let releaseGate = AsyncGate()
        let fixture = Fixture(normalResults: [.failure(Fixture.failure(.io))], releaseGate: releaseGate)
        fixture.coordinator.begin(deviceID: fixture.target.deviceID, displayName: "T7", topologyGeneration: 9)
        try await waitUntil { await fixture.barrier.releases() == 1 }

        fixture.coordinator.cancel()
        await releaseGate.open()
        try await waitUntil { fixture.coordinator.state == .idle }
        try await Task.sleep(for: .milliseconds(20))

        let releases = await fixture.barrier.releases()
        XCTAssertEqual(fixture.coordinator.state, .idle)
        XCTAssertEqual(releases, 1)
    }

    func testCancellationAfterRecoveryDisappearanceDoesNotOverwriteTerminalState() async throws {
        let fixture = Fixture(normalResults: [.failure(Fixture.failure(.busy))])
        await fixture.resolver.setRevalidations([
            .success(fixture.resolved()),
            .failure(EjectTargetResolutionError.deviceNotFound)
        ])
        fixture.coordinator.begin(deviceID: fixture.target.deviceID, displayName: "T7", topologyGeneration: 9)
        try await waitUntil { fixture.coordinator.state.recovery != nil }
        fixture.coordinator.deviceTopologyDidChange(generation: 10)
        try await waitUntil { fixture.coordinator.state == .disappeared(fixture.target) }
        fixture.coordinator.cancel()
        try await Task.sleep(for: .milliseconds(20))

        let releases = await fixture.barrier.releases()
        XCTAssertEqual(fixture.coordinator.state, .disappeared(fixture.target))
        XCTAssertEqual(releases, 1)
    }

    func testSecondBeginIsIgnoredUntilFirstWorkflowReleases() async throws {
        let fixture = Fixture(normalResults: [.failure(Fixture.failure(.busy)), .success(()), .success(())])
        XCTAssertTrue(fixture.coordinator.begin(
            deviceID: fixture.target.deviceID,
            displayName: "T7",
            topologyGeneration: 9
        ))
        try await waitUntil { fixture.coordinator.state.recovery != nil }

        XCTAssertFalse(fixture.coordinator.begin(
            deviceID: DeviceID(rawValue: "serial:other"),
            displayName: "Other",
            topologyGeneration: 10
        ))
        let initialResolveCalls = await fixture.resolver.resolveCalls()
        XCTAssertEqual(initialResolveCalls, [fixture.target.deviceID])

        fixture.coordinator.retry()
        try await waitUntil { fixture.coordinator.state == .succeeded(fixture.target) }
        XCTAssertTrue(fixture.coordinator.begin(
            deviceID: DeviceID(rawValue: "serial:other"),
            displayName: "Other",
            topologyGeneration: 10
        ))
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
        normalResults: [DiskEjectOutcome] = [.success(())],
        forceResults: [DiskEjectOutcome] = [.success(())],
        holders: [OccupancyHolder] = [],
        barrierWaitGate: AsyncGate? = nil,
        normalGate: AsyncGate? = nil,
        forceGate: AsyncGate? = nil,
        normalGates: [AsyncGate?] = [],
        scanGate: AsyncGate? = nil,
        releaseGate: AsyncGate? = nil,
        resolveGate: AsyncGate? = nil,
        quiescerAcquireGate: AsyncGate? = nil,
        resolveResult: Result<ResolvedEjectTarget, Error>? = nil
    ) {
        let target = self.target
        let scope = OccupancyTargetScope(
            physicalBSDName: "disk4",
            deviceNodes: ["/dev/disk4"],
            mountURLs: [URL(fileURLWithPath: "/Volumes/T7")]
        )
        resolver = ResolverSpy(
            resolved: .init(target: target, scope: scope),
            resolveResult: resolveResult,
            resolveGate: resolveGate,
            events: events
        )
        barrier = BarrierSpy(
            waitError: barrierError,
            waitGate: barrierWaitGate,
            releaseGate: releaseGate,
            events: events
        )
        quiescer = QuiescerSpy(
            barrier: barrier,
            error: quiescerError,
            acquireGate: quiescerAcquireGate,
            events: events
        )
        ejecter = EjecterSpy(
            normalResults: normalResults,
            forceResults: forceResults,
            normalGate: normalGate,
            forceGate: forceGate,
            normalGates: normalGates,
            events: events
        )
        scanner = ScannerSpy(
            result: .init(holders: holders, isComplete: true),
            gate: scanGate,
            events: events
        )
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

    func resolved(
        scopePath: String = "/Volumes/T7",
        logicalWholeDiskBSDName: String? = nil
    ) -> ResolvedEjectTarget {
        let logicalTargets = logicalWholeDiskBSDName.map {
            [DiskArbitrationWholeDiskIdentity(bsdName: $0, mediaRegistryEntryID: 8_001)]
        } ?? []
        return .init(
            target: target,
            scope: scope(path: scopePath),
            operationPlan: DiskEjectOperationPlan(
                physicalTarget: target.physicalIdentity,
                logicalWholeDiskTargets: logicalTargets
            )
        )
    }

    func resolvedWithNoMounts() -> ResolvedEjectTarget {
        .init(
            target: target,
            scope: .init(
                physicalBSDName: "disk4",
                deviceNodes: ["/dev/disk4"],
                mountURLs: []
            )
        )
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
    private let resolveResult: Result<ResolvedEjectTarget, Error>?
    private let resolveGate: AsyncGate?
    private let events: EventLog
    private var revalidations: [Result<ResolvedEjectTarget, Error>] = []
    private var revalidationGates: [AsyncGate] = []
    private(set) var resolveDeviceIDs: [DeviceID] = []
    private(set) var revalidatedTargets: [EjectWorkflowTarget] = []

    init(
        resolved: ResolvedEjectTarget,
        resolveResult: Result<ResolvedEjectTarget, Error>?,
        resolveGate: AsyncGate?,
        events: EventLog
    ) {
        self.resolved = resolved
        self.resolveResult = resolveResult
        self.resolveGate = resolveGate
        self.events = events
    }

    func setRevalidations(_ values: [Result<ResolvedEjectTarget, Error>]) { revalidations = values }
    func setRevalidationGates(_ values: [AsyncGate]) { revalidationGates = values }
    func resolveCalls() -> [DeviceID] { resolveDeviceIDs }
    func revalidationCalls() -> [EjectWorkflowTarget] { revalidatedTargets }

    func resolve(deviceID: DeviceID, displayName: String, topologyGeneration: Int) async throws -> ResolvedEjectTarget {
        resolveDeviceIDs.append(deviceID)
        await events.append("resolve")
        await resolveGate?.wait()
        return try (resolveResult ?? .success(resolved)).get()
    }

    func revalidate(_ target: EjectWorkflowTarget) async throws -> ResolvedEjectTarget {
        revalidatedTargets.append(target)
        await events.append("revalidate")
        let gate = revalidationGates.isEmpty ? nil : revalidationGates.removeFirst()
        let result = revalidations.isEmpty ? .success(resolved) : revalidations.removeFirst()
        await gate?.wait()
        return try result.get()
    }
}

private actor BarrierSpy: EjectBarrier {
    private let waitError: DeviceIOQuiescenceError?
    private let waitGate: AsyncGate?
    private let releaseGate: AsyncGate?
    private let events: EventLog
    private(set) var releaseCount = 0

    init(
        waitError: DeviceIOQuiescenceError?,
        waitGate: AsyncGate?,
        releaseGate: AsyncGate?,
        events: EventLog
    ) {
        self.waitError = waitError
        self.waitGate = waitGate
        self.releaseGate = releaseGate
        self.events = events
    }

    func waitUntilReady() async throws {
        await events.append("drain")
        await waitGate?.wait()
        if let waitError { throw waitError }
    }

    func release() async {
        releaseCount += 1
        await events.append("release")
        await releaseGate?.wait()
    }

    func releases() -> Int { releaseCount }
}

private actor QuiescerSpy: DeviceIOQuiescing {
    private let barrier: BarrierSpy
    private let error: DeviceIOQuiescenceError?
    private let acquireGate: AsyncGate?
    private let events: EventLog

    init(
        barrier: BarrierSpy,
        error: DeviceIOQuiescenceError?,
        acquireGate: AsyncGate?,
        events: EventLog
    ) {
        self.barrier = barrier
        self.error = error
        self.acquireGate = acquireGate
        self.events = events
    }

    func acquireBarrier(
        for target: EjectWorkflowTarget,
        timeout: Duration
    ) async throws(DeviceIOQuiescenceError) -> any EjectBarrier {
        await events.append("acquire")
        await acquireGate?.wait()
        if let error { throw error }
        return barrier
    }
}

private actor EjecterSpy: DiskEjecting {
    private var normalResults: [DiskEjectOutcome]
    private var forceResults: [DiskEjectOutcome]
    private let events: EventLog
    private let normalGate: AsyncGate?
    private let forceGate: AsyncGate?
    private var normalGates: [AsyncGate?]
    private(set) var normalBSDNames: [String] = []
    private(set) var plans: [DiskEjectOperationPlan] = []
    private(set) var forceBSDNames: [String] = []

    init(
        normalResults: [DiskEjectOutcome],
        forceResults: [DiskEjectOutcome],
        normalGate: AsyncGate?,
        forceGate: AsyncGate?,
        normalGates: [AsyncGate?],
        events: EventLog
    ) {
        self.normalResults = normalResults
        self.forceResults = forceResults
        self.normalGate = normalGate
        self.forceGate = forceGate
        self.normalGates = normalGates
        self.events = events
    }

    func performNormalEject(plan: DiskEjectOperationPlan) async -> DiskEjectOutcome {
        let target = plan.physicalTarget
        normalBSDNames.append(target.bsdName)
        plans.append(plan)
        await events.append("normal:\(target.bsdName)")
        let gate = normalGates.isEmpty ? normalGate : normalGates.removeFirst()
        await gate?.wait()
        return normalResults.removeFirst()
    }

    func performConfirmedForceEject(plan: DiskEjectOperationPlan) async -> DiskEjectOutcome {
        let target = plan.physicalTarget
        forceBSDNames.append(target.bsdName)
        await events.append("force:\(target.bsdName)")
        await forceGate?.wait()
        return forceResults.removeFirst()
    }

    func normalCalls() -> [String] { normalBSDNames }
    func normalPlans() -> [DiskEjectOperationPlan] { plans }
    func forceCalls() -> [String] { forceBSDNames }
}

private actor ScannerSpy: OccupancyScanning {
    private let result: OccupancyScanResult
    private let gate: AsyncGate?
    private let events: EventLog
    private(set) var scopes: [OccupancyTargetScope] = []

    init(result: OccupancyScanResult, gate: AsyncGate?, events: EventLog) {
        self.result = result
        self.gate = gate
        self.events = events
    }

    func scan(workflowID: UUID, scope: OccupancyTargetScope) async -> OccupancyScanResult {
        scopes.append(scope)
        await events.append("scan")
        await gate?.wait()
        return result
    }

    func scannedScopes() -> [OccupancyTargetScope] { scopes }
}

private actor AsyncGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard isOpen == false else { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }
}
