import XCTest
@testable import DrivePulseApp
import DrivePulseCore
import SwiftUI

final class SMARTServiceClientTests: XCTestCase {
    func testCompatibilityFromEncodedHandshakeUsesSerializedContractFields() throws {
        let client = SMARTServiceClient()
        let payload = HelperHandshake(
            helperVersion: "9.9.9",
            contractMajor: 1,
            contractMinor: 1
        )
        let encodedPayload = try DrivePulseXPCMessages.encode(payload)

        let result = try client.evaluateHandshake(from: encodedPayload)

        XCTAssertEqual(result, .degraded)
    }

    func testEncodeReadRequestRoundTripsThroughSharedMessageCodec() throws {
        let client = SMARTServiceClient()
        let request = SMARTReadRequest(
            physicalDeviceBSDName: "disk42",
            deviceProtocol: "USB",
            deviceModel: "Field SSD"
        )

        let encodedRequest = try client.encodeReadRequest(request)
        let decodedRequest = try DrivePulseXPCMessages.decode(
            SMARTReadRequest.self,
            from: encodedRequest
        )

        XCTAssertEqual(decodedRequest, request)
    }

    func testRefreshSMARTMapsMissingHelperConnectionToHelperNotInstalled() async {
        let client = SMARTServiceClient(
            isHelperInstalled: { false },
            fetchHelperHandshake: {
                throw NSError(
                    domain: NSCocoaErrorDomain,
                    code: 4099,
                    userInfo: [NSLocalizedDescriptionKey: "connection invalid"]
                )
            },
            readSMARTData: { _ in
                XCTFail("SMART read should not be attempted when handshake fails")
                return Data()
            }
        )

        let result = await client.refreshSMART(for: makeClientDevice(id: "disk42"))

        XCTAssertEqual(result, .helperNotInstalled)
    }

    func testRefreshSMARTDoesNotTreatInstalledHelperConnectionFailureAsMissingHelper() async {
        let client = SMARTServiceClient(
            isHelperInstalled: { true },
            fetchHelperHandshake: {
                throw NSError(
                    domain: NSCocoaErrorDomain,
                    code: 4099,
                    userInfo: [NSLocalizedDescriptionKey: "connection invalid"]
                )
            },
            readSMARTData: { _ in
                XCTFail("SMART read should not be attempted when handshake fails")
                return Data()
            }
        )

        let result = await client.refreshSMART(for: makeClientDevice(id: "disk4100"))

        XCTAssertEqual(result, .failed("connection invalid"))
    }

    func testRefreshSMARTDoesNotTreatArbitraryConnectionStringAsMissingHelper() async {
        let client = SMARTServiceClient(
            isHelperInstalled: { false },
            fetchHelperHandshake: {
                throw NSError(
                    domain: "DrivePulseTests",
                    code: 77,
                    userInfo: [NSLocalizedDescriptionKey: "connection invalid"]
                )
            },
            readSMARTData: { _ in
                XCTFail("SMART read should not be attempted when handshake fails")
                return Data()
            }
        )

        let result = await client.refreshSMART(for: makeClientDevice(id: "disk77"))

        XCTAssertEqual(result, .failed("connection invalid"))
    }

    func testRefreshSMARTMapsPermissionErrorFromRead() async throws {
        let handshake = try DrivePulseXPCMessages.encode(
            HelperHandshake(
                helperVersion: "1.0.0",
                contractMajor: XPCContractVersion.currentMajor,
                contractMinor: XPCContractVersion.currentMinor
            )
        )
        let client = SMARTServiceClient(
            fetchHelperHandshake: { handshake },
            readSMARTData: { _ in
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
            }
        )

        let result = await client.refreshSMART(for: makeClientDevice(id: "disk24"))

        XCTAssertEqual(result, .permissionRequired)
    }

    func testRefreshSMARTMapsUnsupportedDeviceMessageToDeviceUnavailable() async throws {
        let handshake = try DrivePulseXPCMessages.encode(
            HelperHandshake(
                helperVersion: "1.0.0",
                contractMajor: XPCContractVersion.currentMajor,
                contractMinor: XPCContractVersion.currentMinor
            )
        )
        let client = SMARTServiceClient(
            fetchHelperHandshake: { handshake },
            readSMARTData: { _ in
                throw NSError(
                    domain: "DrivePulseTests",
                    code: 7,
                    userInfo: [NSLocalizedDescriptionKey: "Unsupported SMART device name: disk7"]
                )
            }
        )

        let result = await client.refreshSMART(for: makeClientDevice(id: "disk7"))

        XCTAssertEqual(result, .deviceUnavailable)
    }

    func testRefreshSMARTMapsTransportHintFailureToTransportUnsupported() async throws {
        let handshake = try DrivePulseXPCMessages.encode(
            HelperHandshake(
                helperVersion: "1.0.0",
                contractMajor: XPCContractVersion.currentMajor,
                contractMinor: XPCContractVersion.currentMinor
            )
        )
        let client = SMARTServiceClient(
            fetchHelperHandshake: { handshake },
            readSMARTData: { _ in
                throw NSError(
                    domain: "DrivePulseTests",
                    code: 9,
                    userInfo: [NSLocalizedDescriptionKey: "smartctl failed with exit code 2 using transport hint nvme: Unknown USB bridge"]
                )
            }
        )

        let result = await client.refreshSMART(for: makeClientDevice(id: "disk9"))

        XCTAssertEqual(result, .transportUnsupported)
    }

    func testRefreshSMARTMapsMissingSMARTCapabilityToUnsupported() async throws {
        let handshake = try DrivePulseXPCMessages.encode(
            HelperHandshake(
                helperVersion: "1.0.0",
                contractMajor: XPCContractVersion.currentMajor,
                contractMinor: XPCContractVersion.currentMinor
            )
        )
        let client = SMARTServiceClient(
            fetchHelperHandshake: { handshake },
            readSMARTData: { _ in
                throw NSError(
                    domain: "DrivePulseTests",
                    code: 11,
                    userInfo: [NSLocalizedDescriptionKey: "SMART support is unavailable for this device"]
                )
            }
        )

        let result = await client.refreshSMART(for: makeClientDevice(id: "disk11"))

        XCTAssertEqual(result, .unsupported)
    }

    private func makeClientDevice(id rawID: String) -> ExternalDevice {
        ExternalDevice(
            id: DeviceID(rawValue: rawID),
            displayName: "Device \(rawID)",
            transportName: "USB",
            smartSnapshot: .notRequested,
            sessionMetrics: .empty(historyLimit: 0),
            physicalStoreBSDName: rawID,
            apfsContainerBSDName: nil,
            volumes: []
        )
    }
}

@MainActor
final class SMARTPresentationTests: XCTestCase {
    func testRefreshUsesLoadingSnapshotWhileRefreshIsInFlightIncludingRetry() async throws {
        let device = makeDevice(id: "disk6", smartSnapshot: .notRequested)
        let discovery = StubSMARTPresentationDeviceDiscovery(results: [[device]])
        let smartService = ControlledSMARTService()
        let controller = makeController(
            smartService: smartService,
            helperInstaller: StubHelperInstaller(),
            deviceDiscovery: discovery
        )

        await discovery.resolveNextDiscovery()
        await waitUntilSelectedDevice(controller, equals: device.id)

        controller.refreshSelectedDeviceSMART()
        await smartService.waitUntilRefreshStarts(count: 1)

        let firstRefreshDetails = try XCTUnwrap(controller.state.selectedSMARTDetails)
        XCTAssertEqual(firstRefreshDetails.snapshot, .loading)
        XCTAssertTrue(firstRefreshDetails.isRefreshing)
        XCTAssertEqual(controller.state.selectedDevice?.smartSnapshot, .loading)

        await smartService.finishCurrentRefresh(with: .failed("Read failed"))
        await waitUntilSMARTPresentationSettles(controller)
        XCTAssertEqual(controller.state.selectedSMARTDetails?.snapshot, .failed("Read failed"))

        controller.refreshSelectedDeviceSMART()
        await smartService.waitUntilRefreshStarts(count: 2)

        let retryDetails = try XCTUnwrap(controller.state.selectedSMARTDetails)
        XCTAssertEqual(retryDetails.snapshot, .loading)
        XCTAssertTrue(retryDetails.isRefreshing)
        XCTAssertEqual(controller.state.selectedDevice?.smartSnapshot, .loading)
    }

    func testSelectedDeviceShowsHelperNotInstalledStateBeforeInstall() async throws {
        let device = makeDevice(id: "disk42", smartSnapshot: .notRequested)
        let discovery = StubSMARTPresentationDeviceDiscovery(results: [[device]])
        let helperInstaller = StubHelperInstaller()
        let controller = makeController(
            smartService: StubSMARTService(
                refreshResult: .helperNotInstalled
            ),
            helperInstaller: helperInstaller,
            deviceDiscovery: discovery
        )

        await discovery.resolveNextDiscovery()
        await waitUntilSelectedDevice(controller, equals: device.id)

        controller.refreshSelectedDeviceSMART()
        await waitUntilSMARTPresentationSettles(controller)

        let details = try XCTUnwrap(controller.state.selectedSMARTDetails)
        XCTAssertEqual(details.snapshot, .helperNotInstalled)
        XCTAssertEqual(details.primaryAction, .installHelper)

        controller.performSMARTPrimaryAction()

        XCTAssertTrue(controller.state.presentation.showHelperInstallPrompt)
        let installCallCount = await helperInstaller.installCallCount
        XCTAssertEqual(installCallCount, 0)
    }

    func testMinorCompatibilityMismatchDoesNotForceUpdate() async throws {
        let smartData = SmartData(
            overallHealth: "PASSED",
            primaryTemperature: 41,
            highestTemperature: 44,
            sensorTemperatures: ["Composite": 41]
        )
        let discovery = StubSMARTPresentationDeviceDiscovery(
            results: [[makeDevice(id: "disk8", smartSnapshot: .notRequested)]]
        )
        let controller = makeController(
            smartService: StubSMARTService(
                refreshResult: .available(
                    smartData,
                    compatibility: .degraded
                )
            ),
            helperInstaller: StubHelperInstaller(),
            deviceDiscovery: discovery
        )

        await discovery.resolveNextDiscovery()
        await waitUntilSelectedDevice(controller, equals: DeviceID(rawValue: "disk8"))

        controller.refreshSelectedDeviceSMART()
        await waitUntilSMARTPresentationSettles(controller)

        let details = try XCTUnwrap(controller.state.selectedSMARTDetails)
        XCTAssertEqual(details.snapshot, .available(smartData))
        XCTAssertEqual(details.compatibility, .degraded)
        XCTAssertEqual(details.primaryAction, .refresh)
    }

    func testInstallHelperRetriesRefreshAndPublishesAvailableSMARTDetails() async throws {
        let smartData = SmartData(
            overallHealth: "PASSED",
            primaryTemperature: 38,
            highestTemperature: 40,
            sensorTemperatures: ["Composite": 38]
        )
        let discovery = StubSMARTPresentationDeviceDiscovery(
            results: [[makeDevice(id: "disk11", smartSnapshot: .notRequested)]]
        )
        let smartService = SequencedSMARTService(
            refreshResults: [
                .helperNotInstalled,
                .available(smartData, compatibility: .compatible)
            ]
        )
        let helperInstaller = StubHelperInstaller()
        let controller = makeController(
            smartService: smartService,
            helperInstaller: helperInstaller,
            deviceDiscovery: discovery
        )

        await discovery.resolveNextDiscovery()
        await waitUntilSelectedDevice(controller, equals: DeviceID(rawValue: "disk11"))
        await waitUntilSMARTSnapshot(
            controller,
            for: DeviceID(rawValue: "disk11"),
            equals: .helperNotInstalled
        )
        XCTAssertEqual(controller.state.selectedSMARTDetails?.primaryAction, .installHelper)

        controller.installSMARTHelper()
        await waitUntilSMARTSnapshot(
            controller,
            for: DeviceID(rawValue: "disk11"),
            equals: .available(smartData)
        )

        let details = try XCTUnwrap(controller.state.selectedSMARTDetails)
        XCTAssertEqual(details.snapshot, .available(smartData))
        XCTAssertEqual(details.compatibility, .compatible)
        XCTAssertEqual(details.primaryAction, .refresh)
        let installCallCount = await helperInstaller.installCallCount
        XCTAssertEqual(installCallCount, 1)
        let refreshedDevice = try XCTUnwrap(controller.state.selectedDevice)
        XCTAssertEqual(refreshedDevice.smartSnapshot, .available(smartData))
    }

    func testUpdateRequiredPresentsUpdateAction() async throws {
        let discovery = StubSMARTPresentationDeviceDiscovery(
            results: [[makeDevice(id: "disk13", smartSnapshot: .notRequested)]]
        )
        let helperInstaller = StubHelperInstaller()
        let controller = makeController(
            smartService: StubSMARTService(refreshResult: .updateRequired),
            helperInstaller: helperInstaller,
            deviceDiscovery: discovery
        )

        await discovery.resolveNextDiscovery()
        await waitUntilSelectedDevice(controller, equals: DeviceID(rawValue: "disk13"))

        controller.refreshSelectedDeviceSMART()
        await waitUntilSMARTPresentationSettles(controller)

        let details = try XCTUnwrap(controller.state.selectedSMARTDetails)
        XCTAssertEqual(details.snapshot, .updateRequired)
        XCTAssertEqual(details.primaryAction, .updateHelper)

        controller.performSMARTPrimaryAction()

        XCTAssertTrue(controller.state.presentation.showHelperUpdatePrompt)
        let installCallCount = await helperInstaller.installCallCount
        XCTAssertEqual(installCallCount, 0)
    }

    func testChangingSelectionDismissesPendingHelperPrompt() async throws {
        let firstDevice = makeDevice(id: "disk14", smartSnapshot: .notRequested)
        let secondDevice = makeDevice(id: "disk15", smartSnapshot: .notRequested)
        let discovery = StubSMARTPresentationDeviceDiscovery(results: [[firstDevice, secondDevice]])
        let controller = makeController(
            smartService: StubSMARTService(refreshResult: .helperNotInstalled),
            helperInstaller: StubHelperInstaller(),
            deviceDiscovery: discovery
        )

        await discovery.resolveNextDiscovery()
        await waitUntilSelectedDevice(controller, equals: firstDevice.id)

        controller.refreshSelectedDeviceSMART()
        await waitUntilSMARTPresentationSettles(controller)
        controller.performSMARTPrimaryAction()

        XCTAssertTrue(controller.state.presentation.showHelperInstallPrompt)

        controller.selectDevice(secondDevice.id)
        await waitUntilSelectedDevice(controller, equals: secondDevice.id)

        XCTAssertFalse(controller.state.presentation.showHelperInstallPrompt)
        XCTAssertFalse(controller.state.presentation.showHelperUpdatePrompt)
    }

    func testRediscoverySelectionChangeDismissesPendingHelperPrompt() async throws {
        let firstDevice = makeDevice(id: "disk16", smartSnapshot: .notRequested)
        let secondDevice = makeDevice(id: "disk17", smartSnapshot: .notRequested)
        let discovery = StubSMARTPresentationDeviceDiscovery(
            results: [
                [firstDevice, secondDevice],
                [secondDevice]
            ]
        )
        let controller = makeController(
            smartService: StubSMARTService(refreshResult: .helperNotInstalled),
            helperInstaller: StubHelperInstaller(),
            deviceDiscovery: discovery
        )

        await discovery.resolveNextDiscovery()
        await waitUntilSelectedDevice(controller, equals: firstDevice.id)

        controller.refreshSelectedDeviceSMART()
        await waitUntilSMARTPresentationSettles(controller)
        controller.performSMARTPrimaryAction()

        XCTAssertTrue(controller.state.presentation.showHelperInstallPrompt)
        XCTAssertEqual(controller.state.presentation.promptDeviceID, firstDevice.id)

        controller.refresh()
        await discovery.resolveNextDiscovery()
        await waitUntilSelectedDevice(controller, equals: secondDevice.id)

        XCTAssertFalse(controller.state.presentation.showHelperInstallPrompt)
        XCTAssertFalse(controller.state.presentation.showHelperUpdatePrompt)
        XCTAssertNil(controller.state.presentation.promptDeviceID)
    }

    func testRefreshResultStaysWithInitiatingDeviceAfterSelectionChanges() async throws {
        let firstDevice = makeDevice(id: "disk20", smartSnapshot: .notRequested)
        let secondDevice = makeDevice(id: "disk21", smartSnapshot: .unsupported)
        let discovery = StubSMARTPresentationDeviceDiscovery(results: [[firstDevice, secondDevice]])
        let smartService = ControlledSMARTService()
        let controller = makeController(
            smartService: smartService,
            helperInstaller: StubHelperInstaller(),
            deviceDiscovery: discovery
        )
        let smartData = SmartData(
            overallHealth: "PASSED",
            primaryTemperature: 35,
            highestTemperature: 39,
            sensorTemperatures: ["Composite": 35]
        )

        await discovery.resolveNextDiscovery()
        await waitUntilSelectedDevice(controller, equals: firstDevice.id)
        await smartService.waitUntilRefreshStarts(count: 1)

        controller.selectDevice(secondDevice.id)
        await waitUntilSelectedDevice(controller, equals: secondDevice.id)

        await smartService.finishCurrentRefresh(
            with: .available(smartData, compatibility: .compatible)
        )
        await Task.yield()

        XCTAssertEqual(controller.state.selectedDeviceID, secondDevice.id)
        XCTAssertEqual(controller.state.selectedSMARTDetails?.snapshot, .unsupported)

        controller.selectDevice(firstDevice.id)
        await waitUntilSelectedDevice(controller, equals: firstDevice.id)

        let details = try XCTUnwrap(controller.state.selectedSMARTDetails)
        XCTAssertEqual(details.snapshot, .available(smartData))
        XCTAssertEqual(details.compatibility, .compatible)
    }

    func testObservationUpdateDuringRefreshKeepsSelectedDeviceSnapshotLoading() async throws {
        let initialDevice = makeDevice(id: "disk24", smartSnapshot: .notRequested)
        let observedDevice = makeDevice(id: "disk24", smartSnapshot: .notRequested)
        let discovery = StubSMARTPresentationDeviceDiscovery(results: [[initialDevice]])
        let smartService = ControlledSMARTService()
        let controller = makeController(
            smartService: smartService,
            helperInstaller: StubHelperInstaller(),
            deviceDiscovery: discovery
        )

        await discovery.resolveNextDiscovery()
        await waitUntilSelectedDevice(controller, equals: initialDevice.id)

        controller.refreshSelectedDeviceSMART()
        await smartService.waitUntilRefreshStarts(count: 1)

        await discovery.sendObservedDevices([observedDevice])
        await Task.yield()

        let details = try XCTUnwrap(controller.state.selectedSMARTDetails)
        XCTAssertEqual(details.snapshot, .loading)
        XCTAssertTrue(details.isRefreshing)
        XCTAssertEqual(controller.state.selectedDevice?.smartSnapshot, .loading)
    }

    func testStartingRefreshClearsLastErrorWhileRetryIsInFlight() async throws {
        let device = makeDevice(id: "disk25", smartSnapshot: .notRequested)
        let discovery = StubSMARTPresentationDeviceDiscovery(results: [[device]])
        let smartService = ControlledSMARTService()
        let controller = makeController(
            smartService: smartService,
            helperInstaller: StubHelperInstaller(),
            deviceDiscovery: discovery
        )

        await discovery.resolveNextDiscovery()
        await waitUntilSelectedDevice(controller, equals: device.id)

        controller.refreshSelectedDeviceSMART()
        await smartService.waitUntilRefreshStarts(count: 1)
        await smartService.finishCurrentRefresh(with: .failed("Read failed"))
        await waitUntilSMARTPresentationSettles(controller)

        XCTAssertEqual(controller.state.selectedSMARTDetails?.lastError, "Read failed")

        controller.refreshSelectedDeviceSMART()
        await smartService.waitUntilRefreshStarts(count: 2)

        let retryDetails = try XCTUnwrap(controller.state.selectedSMARTDetails)
        XCTAssertTrue(retryDetails.isRefreshing)
        XCTAssertNil(retryDetails.lastError)
    }

    func testStartingHelperInstallClearsLastErrorWhileRetryIsInFlight() async throws {
        let device = makeDevice(id: "disk26", smartSnapshot: .notRequested)
        let discovery = StubSMARTPresentationDeviceDiscovery(results: [[device]])
        let helperInstaller = ControlledHelperInstaller(
            outcomes: [
                .failure("Install failed"),
                .pending
            ]
        )
        let controller = makeController(
            smartService: StubSMARTService(refreshResult: .helperNotInstalled),
            helperInstaller: helperInstaller,
            deviceDiscovery: discovery
        )

        await discovery.resolveNextDiscovery()
        await waitUntilSelectedDevice(controller, equals: device.id)

        controller.refreshSelectedDeviceSMART()
        await waitUntilSMARTPresentationSettles(controller)

        controller.installSMARTHelper()
        await helperInstaller.waitUntilInstallStarts(count: 1)
        await waitUntilSMARTPresentationSettles(controller)

        XCTAssertEqual(controller.state.selectedSMARTDetails?.lastError, "Install failed")

        controller.installSMARTHelper()
        await helperInstaller.waitUntilInstallStarts(count: 2)

        let retryDetails = try XCTUnwrap(controller.state.selectedSMARTDetails)
        XCTAssertTrue(retryDetails.isRefreshing)
        XCTAssertTrue(retryDetails.isInstalling)
        XCTAssertNil(retryDetails.lastError)
    }

    func testRediscoveryPreservesFetchedSMARTSnapshotAndCompatibilityForSameDevice() async throws {
        let firstPassDevice = makeDevice(id: "disk30", smartSnapshot: .notRequested)
        let rediscoveredDevice = makeDevice(id: "disk30", smartSnapshot: .notRequested)
        let discovery = StubSMARTPresentationDeviceDiscovery(results: [[firstPassDevice], [rediscoveredDevice]])
        let smartData = SmartData(
            overallHealth: "PASSED",
            primaryTemperature: 42,
            highestTemperature: 45,
            sensorTemperatures: ["Composite": 42]
        )
        let controller = makeController(
            smartService: StubSMARTService(
                refreshResult: .available(smartData, compatibility: .degraded)
            ),
            helperInstaller: StubHelperInstaller(),
            deviceDiscovery: discovery
        )

        await discovery.resolveNextDiscovery()
        await waitUntilSelectedDevice(controller, equals: firstPassDevice.id)

        controller.refreshSelectedDeviceSMART()
        await waitUntilSMARTPresentationSettles(controller)
        XCTAssertEqual(controller.state.selectedSMARTDetails?.compatibility, .degraded)

        controller.refresh()
        await discovery.resolveNextDiscovery()
        await waitUntilSelectedDevice(controller, equals: firstPassDevice.id)

        let details = try XCTUnwrap(controller.state.selectedSMARTDetails)
        XCTAssertEqual(details.snapshot, .available(smartData))
        XCTAssertEqual(details.compatibility, .degraded)
        let selectedDevice = try XCTUnwrap(controller.state.selectedDevice)
        XCTAssertEqual(selectedDevice.smartSnapshot, .available(smartData))
    }

    func testInitialConcurrentSMARTRefreshesStayBoundToTheirDevices() async throws {
        let firstDevice = makeDevice(id: "disk40", smartSnapshot: .notRequested)
        let secondDevice = makeDevice(id: "disk41", smartSnapshot: .notRequested)
        let discovery = StubSMARTPresentationDeviceDiscovery(results: [[firstDevice, secondDevice]])
        let smartService = MultiDeviceControlledSMARTService()
        let controller = makeController(
            smartService: smartService,
            helperInstaller: StubHelperInstaller(),
            deviceDiscovery: discovery
        )
        let firstData = SmartData(overallHealth: "PASSED", primaryTemperature: 36)
        let secondData = SmartData(overallHealth: "PASSED", primaryTemperature: 41)

        await discovery.resolveNextDiscovery()
        await smartService.waitUntilRefreshStarts(for: "disk40")
        await smartService.waitUntilRefreshStarts(for: "disk41")

        await smartService.finishRefresh(
            for: "disk41",
            with: .available(secondData, compatibility: .compatible)
        )
        await Task.yield()

        let deviceAfterSecondFinish = try XCTUnwrap(
            controller.state.devices.first(where: { $0.id == secondDevice.id })
        )
        XCTAssertEqual(deviceAfterSecondFinish.smartSnapshot, .available(secondData))
        XCTAssertEqual(
            controller.state.devices.first(where: { $0.id == firstDevice.id })?.smartSnapshot,
            .loading
        )

        await smartService.finishRefresh(
            for: "disk40",
            with: .available(firstData, compatibility: .degraded)
        )
        await Task.yield()

        let firstDetails = controller.state.smartDetails(for: firstDevice.id)
        let secondDetails = controller.state.smartDetails(for: secondDevice.id)
        XCTAssertEqual(firstDetails?.snapshot, .available(firstData))
        XCTAssertEqual(firstDetails?.compatibility, .degraded)
        XCTAssertEqual(secondDetails?.snapshot, .available(secondData))
        XCTAssertEqual(secondDetails?.compatibility, .compatible)
    }

    func testDetailsDescriptionUsesConfiguredTemperatureUnit() throws {
        let smartData = SmartData(
            overallHealth: "PASSED",
            primaryTemperature: 37,
            highestTemperature: 40,
            sensorTemperatures: ["Composite": 37]
        )
        let smartDetails = SMARTPresentationDetails(
            snapshot: .available(smartData),
            compatibility: nil,
            isRefreshing: false,
            isInstalling: false,
            lastError: nil
        )
        let settings = makeAppSettings(temperatureUnit: .fahrenheit)
        let view = DetailsSectionView(
            device: nil,
            smartDetails: smartDetails,
            settings: settings,
            onSMARTAction: { _ in }
        )

        XCTAssertEqual(view.description(for: smartDetails), "Highest Temperature: 104 °F")
    }

    func testTransportUnsupportedUsesAdditionalSupportDescription() throws {
        let smartDetails = SMARTPresentationDetails(
            snapshot: .transportUnsupported,
            compatibility: nil,
            isRefreshing: false,
            isInstalling: false,
            lastError: nil
        )
        let view = DetailsSectionView(
            device: nil,
            smartDetails: smartDetails,
            settings: makeAppSettings(temperatureUnit: .celsius),
            onSMARTAction: { _ in }
        )

        XCTAssertEqual(
            view.description(for: smartDetails),
            "This enclosure path needs additional transport support."
        )
        XCTAssertEqual(
            view.title(for: smartDetails),
            "Additional transport support required"
        )
    }

    func testDegradedCompatibilityStillUsesHighestTemperatureDescription() throws {
        let smartData = SmartData(
            overallHealth: "PASSED",
            primaryTemperature: 39,
            highestTemperature: 43,
            sensorTemperatures: ["Composite": 39]
        )
        let smartDetails = SMARTPresentationDetails(
            snapshot: .available(smartData),
            compatibility: .degraded,
            isRefreshing: false,
            isInstalling: false,
            lastError: nil
        )
        let view = DetailsSectionView(
            device: nil,
            smartDetails: smartDetails,
            settings: makeAppSettings(temperatureUnit: .celsius),
            onSMARTAction: { _ in }
        )

        XCTAssertEqual(view.description(for: smartDetails), "Highest Temperature: 43 °C")
    }

    private func makeDevice(id rawID: String, smartSnapshot: SmartSnapshot) -> ExternalDevice {
        ExternalDevice(
            id: DeviceID(rawValue: rawID),
            displayName: "Device \(rawID)",
            transportName: "USB",
            smartSnapshot: smartSnapshot,
            sessionMetrics: .empty(historyLimit: 0),
            physicalStoreBSDName: rawID,
            apfsContainerBSDName: nil,
            volumes: []
        )
    }

    private func makeController(
        smartService: any SMARTServiceProviding,
        helperInstaller: any HelperInstalling,
        deviceDiscovery: any ExternalDeviceDiscovering
    ) -> DrivePulseAppController {
        DrivePulseAppController(
            smartService: smartService,
            helperInstaller: helperInstaller,
            deviceDiscovery: deviceDiscovery,
            systemProfilerProvider: StubSMARTSystemProfilerProvider(),
            diskUtilAPFSProvider: StubSMARTDiskUtilAPFSProvider()
        )
    }

    private func waitUntilSelectedDevice(
        _ controller: DrivePulseAppController,
        equals id: DeviceID
    ) async {
        while controller.state.selectedDeviceID != id {
            await Task.yield()
        }
    }

    private func waitUntilSMARTPresentationSettles(_ controller: DrivePulseAppController) async {
        while controller.state.selectedSMARTDetails?.isRefreshing == true {
            await Task.yield()
        }
    }

    private func waitUntilSMARTSnapshot(
        _ controller: DrivePulseAppController,
        for deviceID: DeviceID,
        equals expectedSnapshot: SmartSnapshot
    ) async {
        while controller.state.smartDetails(for: deviceID)?.snapshot != expectedSnapshot {
            await Task.yield()
        }
    }
}

private actor StubSMARTService: SMARTServiceProviding {
    let refreshResult: SMARTServiceRefreshResult

    init(refreshResult: SMARTServiceRefreshResult) {
        self.refreshResult = refreshResult
    }

    func refreshSMART(for device: ExternalDevice) async -> SMARTServiceRefreshResult {
        _ = device
        return refreshResult
    }
}

private actor SequencedSMARTService: SMARTServiceProviding {
    private let refreshResults: [SMARTServiceRefreshResult]
    private var invocationCount = 0

    init(refreshResults: [SMARTServiceRefreshResult]) {
        self.refreshResults = refreshResults
    }

    func refreshSMART(for device: ExternalDevice) async -> SMARTServiceRefreshResult {
        _ = device
        let index = min(invocationCount, refreshResults.count - 1)
        invocationCount += 1
        return refreshResults[index]
    }
}

private actor ControlledSMARTService: SMARTServiceProviding {
    private var pendingContinuation: CheckedContinuation<SMARTServiceRefreshResult, Never>?
    private var refreshStartCount = 0

    func refreshSMART(for device: ExternalDevice) async -> SMARTServiceRefreshResult {
        _ = device
        refreshStartCount += 1
        return await withCheckedContinuation { continuation in
            pendingContinuation = continuation
        }
    }

    func waitUntilRefreshStarts(count expectedCount: Int) async {
        while refreshStartCount < expectedCount {
            await Task.yield()
        }
    }

    func finishCurrentRefresh(with result: SMARTServiceRefreshResult) async {
        while pendingContinuation == nil {
            await Task.yield()
        }

        let continuation = pendingContinuation
        pendingContinuation = nil
        continuation?.resume(returning: result)
    }
}

private actor MultiDeviceControlledSMARTService: SMARTServiceProviding {
    private var pendingContinuations: [String: CheckedContinuation<SMARTServiceRefreshResult, Never>] = [:]
    private var refreshStartCounts: [String: Int] = [:]

    func refreshSMART(for device: ExternalDevice) async -> SMARTServiceRefreshResult {
        refreshStartCounts[device.physicalStoreBSDName, default: 0] += 1
        return await withCheckedContinuation { continuation in
            pendingContinuations[device.physicalStoreBSDName] = continuation
        }
    }

    func waitUntilRefreshStarts(for bsdName: String, count expectedCount: Int = 1) async {
        while refreshStartCounts[bsdName, default: 0] < expectedCount {
            await Task.yield()
        }
    }

    func finishRefresh(for bsdName: String, with result: SMARTServiceRefreshResult) async {
        while pendingContinuations[bsdName] == nil {
            await Task.yield()
        }

        let continuation = pendingContinuations.removeValue(forKey: bsdName)
        continuation?.resume(returning: result)
    }
}

private final class StubSMARTSystemProfilerProvider: SystemProfilerProviding, @unchecked Sendable {
    func fetchIfNeeded() async {}
    func refresh() async {}
    func nvmeInfo(forBSDName bsdName: String, modelName: String?) -> NVMeInfo? { nil }
    func pciInfo(forNVMeSerialNumber serial: String?) -> PCIInfo? { nil }
    func thunderboltInfo() -> ThunderboltInfo? { nil }
}

private final class StubSMARTDiskUtilAPFSProvider: DiskUtilAPFSProviding, @unchecked Sendable {
    func refresh() async {}
    func containerInfo(forContainerBSDName bsdName: String) async -> APFSContainerInfo? { nil }
    func physicalPartitions(forDiskBSDName bsdName: String) async -> [PhysicalPartitionInfo] { [] }
}

private actor StubHelperInstaller: HelperInstalling {
    private(set) var installCallCount = 0

    func install() async throws {
        installCallCount += 1
    }
}

private actor ControlledHelperInstaller: HelperInstalling {
    enum Outcome {
        case failure(String)
        case pending
    }

    private let outcomes: [Outcome]
    private var invocationCount = 0
    private var pendingContinuation: CheckedContinuation<Void, Error>?

    init(outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    func install() async throws {
        let index = min(invocationCount, outcomes.count - 1)
        let outcome = outcomes[index]
        invocationCount += 1

        switch outcome {
        case let .failure(message):
            throw NSError(
                domain: "DrivePulseTests",
                code: invocationCount,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        case .pending:
            try await withCheckedThrowingContinuation { continuation in
                pendingContinuation = continuation
            }
        }
    }

    func waitUntilInstallStarts(count expectedCount: Int) async {
        while invocationCount < expectedCount {
            await Task.yield()
        }
    }
}

private final class StubSMARTPresentationDeviceDiscovery: ExternalDeviceDiscovering, @unchecked Sendable {
    private let state: State

    init(results: [[ExternalDevice]]) {
        self.state = State(results: results)
    }

    func discoverDevices() async -> [ExternalDevice] {
        await state.discoverDevices()
    }

    func observeDevices(
        _ onUpdate: @escaping @MainActor @Sendable ([ExternalDevice]) -> Void
    ) -> any ExternalDeviceDiscoveryObservation {
        Task {
            await state.setObservation(onUpdate)
        }
        return StubSMARTPresentationDeviceObservation()
    }

    func resolveNextDiscovery() async {
        await state.resolveNextDiscovery()
    }

    func sendObservedDevices(_ devices: [ExternalDevice]) async {
        await state.sendObservedDevices(devices)
    }

    private actor State {
        private let results: [[ExternalDevice]]
        private var invocationCount = 0
        private var pendingContinuations: [CheckedContinuation<Void, Never>] = []
        private var observation: (@MainActor @Sendable ([ExternalDevice]) -> Void)?

        init(results: [[ExternalDevice]]) {
            self.results = results
        }

        func discoverDevices() async -> [ExternalDevice] {
            await withCheckedContinuation { continuation in
                pendingContinuations.append(continuation)
            }

            defer { invocationCount += 1 }

            let index = min(invocationCount, results.count - 1)
            return results[index]
        }

        func resolveNextDiscovery() async {
            while pendingContinuations.isEmpty {
                await Task.yield()
            }

            let continuation = pendingContinuations.removeFirst()
            continuation.resume()
        }

        func setObservation(_ observation: @escaping @MainActor @Sendable ([ExternalDevice]) -> Void) {
            self.observation = observation
        }

        func sendObservedDevices(_ devices: [ExternalDevice]) async {
            while observation == nil {
                await Task.yield()
            }

            await observation?(devices)
        }
    }
}

private struct StubSMARTPresentationDeviceObservation: ExternalDeviceDiscoveryObservation {
    func cancel() {}
}

private func makeAppSettings(temperatureUnit: TemperatureUnit) -> AppSettings {
    let suiteName = "DrivePulseTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defaults.set(temperatureUnit.rawValue, forKey: AppSettings.temperatureUnitDefaultsKey)
    return AppSettings(defaults: defaults)
}
