import XCTest
@testable import DrivePulseApp

import DiskArbitration
import Foundation
import DrivePulseCore

@MainActor
final class DrivePulseAppControllerTests: XCTestCase {
    func testControllerBootstrapsStateFromDiscoveryAsynchronously() async {
        let discoveredDevices = [
            makeDevice(id: "disk21", volumes: ["disk21s1"])
        ]
        let discovery = StubExternalDeviceDiscovery(results: [discoveredDevices])

        let controller = DrivePulseAppController(deviceDiscovery: discovery)

        XCTAssertEqual(controller.state.devices, [])
        let initialInvocationCount = await discovery.invocationCountSnapshot()
        XCTAssertEqual(initialInvocationCount, 0)

        await discovery.resolveNextDiscovery()
        await waitUntilStateDevices(
            controller,
            equals: discoveredDevices
        )

        XCTAssertEqual(controller.state.devices, discoveredDevices)
        XCTAssertEqual(controller.state.selectedDeviceID, DeviceID(rawValue: "disk21"))
        let bootstrapInvocationCount = await discovery.invocationCountSnapshot()
        XCTAssertEqual(bootstrapInvocationCount, 1)
    }

    func testRefreshRequeriesDiscoveryAndReplacesDevicesAsynchronously() async {
        let initialDevices = [
            makeDevice(id: "disk21", volumes: ["disk21s1"])
        ]
        let refreshedDevices = [
            makeDevice(id: "disk42", volumes: []),
            makeDevice(id: "disk84", volumes: ["disk84s2"])
        ]
        let discovery = StubExternalDeviceDiscovery(results: [initialDevices, refreshedDevices])
        let controller = DrivePulseAppController(deviceDiscovery: discovery)

        await discovery.resolveNextDiscovery()
        await waitUntilStateDevices(
            controller,
            equals: initialDevices
        )

        controller.refresh()

        XCTAssertEqual(controller.state.devices, initialDevices)

        await discovery.resolveNextDiscovery()
        await waitUntilStateDevices(
            controller,
            equals: refreshedDevices
        )

        XCTAssertEqual(controller.state.devices, refreshedDevices)
        XCTAssertEqual(controller.state.selectedDeviceID, DeviceID(rawValue: "disk42"))
        let refreshInvocationCount = await discovery.invocationCountSnapshot()
        XCTAssertEqual(refreshInvocationCount, 2)
    }

    func testControllerSubscribesToDiscoveryStreamAndAppliesUpdates() {
        let initialDevices = [
            makeDevice(id: "disk21", volumes: ["disk21s1"])
        ]
        let discovery = StubExternalDeviceDiscovery(results: [initialDevices])
        let controller = DrivePulseAppController(
            deviceDiscovery: discovery,
            systemProfilerProvider: StubSystemProfilerProvider(),
            diskUtilAPFSProvider: StubDiskUtilAPFSProvider()
        )
        let updatedDevices = [
            makeDevice(id: "disk84", volumes: []),
            makeDevice(id: "disk126", volumes: ["disk126s1"])
        ]

        discovery.emit(updatedDevices)

        XCTAssertEqual(discovery.subscriptionCount, 1)
        let expectation = expectation(description: "observed devices applied")
        Task { @MainActor in
            await self.waitUntilStateDevices(controller, equals: updatedDevices)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(controller.state.selectedDeviceID, DeviceID(rawValue: "disk84"))
    }

    func testObserverUpdatePreventsPendingDiscoveryResultFromOverwritingNewerDevices() async {
        let bootstrapDevices = [
            makeDevice(id: "disk21", volumes: ["disk21s1"])
        ]
        let observedDevices = [
            makeDevice(id: "disk84", volumes: []),
            makeDevice(id: "disk126", volumes: ["disk126s1"])
        ]
        let discovery = StubExternalDeviceDiscovery(results: [bootstrapDevices])
        let controller = DrivePulseAppController(
            deviceDiscovery: discovery,
            systemProfilerProvider: StubSystemProfilerProvider(),
            diskUtilAPFSProvider: StubDiskUtilAPFSProvider()
        )

        await discovery.waitUntilNextDiscoveryIsPending()

        discovery.emit(observedDevices)
        await waitUntilStateDevices(controller, equals: observedDevices)

        await discovery.resolveNextDiscovery()
        await Task.yield()

        XCTAssertEqual(controller.state.devices, observedDevices)
        XCTAssertEqual(controller.state.selectedDeviceID, DeviceID(rawValue: "disk84"))
    }

    func testControllerFetchesSystemProfilerOnceDuringBootstrapAndRefreshesProvidersOnObservedUpdate() async throws {
        let bootstrapDevice = makeDevice(id: "disk21", volumes: [])
        let observedDevice = makeDevice(
            id: "disk84",
            volumes: ["disk84s2s1"],
            transportName: "Thunderbolt",
            physicalStoreBSDName: "disk84",
            apfsContainerBSDName: "disk84s2"
        )
        let discovery = StubExternalDeviceDiscovery(results: [[bootstrapDevice]])
        let systemProfilerProvider = StubSystemProfilerProvider(
            refreshedNVMeInfoByBSDName: [
                "disk84": NVMeInfo(
                    controller: "Controller B",
                    model: "Model B",
                    serialNumber: "SERIAL-B",
                    firmwareVersion: "FW-B"
                )
            ],
            refreshedPCIInfoBySerialNumber: [
                "SERIAL-B": PCIInfo(
                    slot: "Slot-B",
                    vendorID: "0x1234",
                    deviceID: "0x5678"
                )
            ],
            refreshedThunderboltInfo: ThunderboltInfo(
                vendorName: "Acme",
                deviceName: "TB Enclosure"
            )
        )
        let diskUtilProvider = StubDiskUtilAPFSProvider(
            refreshedContainerInfoByBSDName: [
                "disk84s2": APFSContainerInfo(
                    bsdName: "disk84s2",
                    totalCapacityBytes: 2_000,
                    capacityInUseBytes: 1_500,
                    capacityNotAllocatedBytes: 500,
                    volumes: [
                        APFSVolumeDetails(
                            volumeName: "Observed",
                            bsdName: "disk84s2s1",
                            mountPoint: "/Volumes/Observed",
                            capacityConsumedBytes: 1_500
                        )
                    ]
                )
            ],
            physicalPartitionsByDiskBSDName: [
                "disk84": [
                    PhysicalPartitionInfo(
                        bsdName: "disk84s2",
                        partitionType: "Apple_APFS"
                    )
                ]
            ]
        )
        let controller = DrivePulseAppController(
            deviceDiscovery: discovery,
            systemProfilerProvider: systemProfilerProvider,
            diskUtilAPFSProvider: diskUtilProvider
        )

        await discovery.resolveNextDiscovery()
        await waitUntilStateDevices(controller, equals: [bootstrapDevice])
        await waitUntil {
            systemProfilerProvider.fetchIfNeededCallCount == 1 &&
            diskUtilProvider.refreshCallCount == 1
        }

        XCTAssertEqual(systemProfilerProvider.fetchIfNeededCallCount, 1)
        XCTAssertEqual(systemProfilerProvider.refreshCallCount, 0)
        XCTAssertEqual(diskUtilProvider.refreshCallCount, 1)

        discovery.emit([observedDevice])

        await waitUntilStateDevices(controller) { devices in
            guard let device = devices.first else { return false }
            return device.id == observedDevice.id
                && device.nvmeInfo?.serialNumber == "SERIAL-B"
                && device.pciInfo?.slot == "Slot-B"
                && device.thunderboltInfo?.deviceName == "TB Enclosure"
                && device.apfsContainerDetails?.capacityInUseBytes == 1_500
                && device.physicalPartitions == [
                    PhysicalPartitionInfo(
                        bsdName: "disk84s2",
                        partitionType: "Apple_APFS"
                    )
                ]
        }

        let appliedDevice = try XCTUnwrap(controller.state.selectedDevice)
        XCTAssertEqual(appliedDevice.id, observedDevice.id)
        XCTAssertEqual(systemProfilerProvider.fetchIfNeededCallCount, 1)
        XCTAssertEqual(systemProfilerProvider.refreshCallCount, 1)
        XCTAssertEqual(diskUtilProvider.refreshCallCount, 2)
    }

    func testObservedSparseSnapshotDoesNotDiscardRicherBootstrapDeviceContext() async throws {
        let bootstrapDevice = makeDevice(
            id: "disk84",
            volumes: ["disk84s2s1"],
            transportName: "Thunderbolt",
            physicalStoreBSDName: "disk84",
            apfsContainerBSDName: "disk84s2"
        )
        let sparseObservedDevice = makeDevice(
            id: "disk84",
            volumes: [],
            transportName: "External",
            physicalStoreBSDName: "disk84",
            apfsContainerBSDName: nil
        )
        let discovery = StubExternalDeviceDiscovery(results: [[bootstrapDevice]])
        let systemProfilerProvider = StubSystemProfilerProvider(
            refreshedNVMeInfoByBSDName: [
                "disk84": NVMeInfo(
                    controller: "Controller B",
                    model: "Model B",
                    serialNumber: "SERIAL-B",
                    firmwareVersion: "FW-B"
                )
            ],
            refreshedPCIInfoBySerialNumber: [
                "SERIAL-B": PCIInfo(
                    slot: "Slot-B",
                    vendorID: "0x1234",
                    deviceID: "0x5678"
                )
            ],
            refreshedThunderboltInfo: ThunderboltInfo(
                vendorName: "Acme",
                deviceName: "TB Enclosure"
            )
        )
        let diskUtilProvider = DelayedStubDiskUtilAPFSProvider(
            refreshDelayNanoseconds: 200_000_000,
            refreshedContainerInfoByBSDName: [
                "disk84s2": APFSContainerInfo(
                    bsdName: "disk84s2",
                    totalCapacityBytes: 2_000,
                    capacityInUseBytes: 1_500,
                    capacityNotAllocatedBytes: 500,
                    volumes: [
                        APFSVolumeDetails(
                            volumeName: "Observed",
                            bsdName: "disk84s2s1",
                            mountPoint: "/Volumes/Observed",
                            capacityConsumedBytes: 1_500
                        )
                    ]
                )
            ],
            physicalPartitionsByDiskBSDName: [
                "disk84": [
                    PhysicalPartitionInfo(
                        bsdName: "disk84s2",
                        partitionType: "Apple_APFS"
                    )
                ]
            ]
        )
        let controller = DrivePulseAppController(
            deviceDiscovery: discovery,
            systemProfilerProvider: systemProfilerProvider,
            diskUtilAPFSProvider: diskUtilProvider
        )

        await discovery.resolveNextDiscovery()
        await waitUntilStateDevices(controller, equals: [bootstrapDevice])

        discovery.emit([sparseObservedDevice])

        await waitUntilStateDevices(controller) { devices in
            guard let device = devices.first else { return false }
            return device.id == bootstrapDevice.id
                && device.transportName == "Thunderbolt"
                && device.apfsContainerBSDName == "disk84s2"
                && device.volumes == [MountedVolume(bsdName: "disk84s2s1")]
                && device.apfsContainerDetails?.capacityInUseBytes == 1_500
                && device.thunderboltInfo?.deviceName == "TB Enclosure"
                && device.pciInfo?.slot == "Slot-B"
                && device.physicalPartitions == [
                    PhysicalPartitionInfo(
                        bsdName: "disk84s2",
                        partitionType: "Apple_APFS"
                    )
                ]
        }
    }

    func testControllerRetriesAPFSEnrichmentAfterInitialDiskUtilFailure() async throws {
        let bootstrapDevice = makeDevice(
            id: "disk21",
            volumes: ["disk21s2s1"],
            physicalStoreBSDName: "disk21",
            apfsContainerBSDName: "disk21s2"
        )
        let discovery = StubExternalDeviceDiscovery(results: [[bootstrapDevice]])
        let diskUtilProvider = RetryingStubDiskUtilAPFSProvider(
            refreshResults: [
                [:],
                [
                    "disk21s2": APFSContainerInfo(
                        bsdName: "disk21s2",
                        totalCapacityBytes: 2_000,
                        capacityInUseBytes: 1_500,
                        capacityNotAllocatedBytes: 500,
                        volumes: [
                            APFSVolumeDetails(
                                volumeName: "Macintosh HD",
                                bsdName: "disk21s2s1",
                                mountPoint: "/Volumes/Macintosh HD",
                                capacityConsumedBytes: 1_500,
                                volumeUUID: "volume-uuid"
                            )
                        ]
                    )
                ]
            ],
            physicalPartitionsByDiskBSDName: [
                "disk21": [
                    PhysicalPartitionInfo(
                        bsdName: "disk21s2",
                        partitionType: "Apple_APFS"
                    )
                ]
            ]
        )
        let controller = DrivePulseAppController(
            deviceDiscovery: discovery,
            systemProfilerProvider: DelayedSystemProfilerProvider(fetchDelayNanoseconds: 1_000_000_000),
            diskUtilAPFSProvider: diskUtilProvider
        )

        await discovery.resolveNextDiscovery()
        await waitUntilStateDevices(controller, equals: [bootstrapDevice])

        await waitUntilStateDevices(controller) { devices in
            guard let device = devices.first else { return false }
            return device.id == bootstrapDevice.id
                && device.apfsContainerDetails?.capacityInUseBytes == 1_500
                && device.apfsContainerDetails?.capacityNotAllocatedBytes == 500
                && device.apfsContainerDetails?.volumes.first?.volumeUUID == "volume-uuid"
        }
        XCTAssertGreaterThanOrEqual(diskUtilProvider.refreshCallCount, 2)
    }

    func testControllerRefreshesMountedVolumeCapacityBeforeAPFSEnrichmentCompletes() async throws {
        let capacityRefresher = VolumeCapacityRefresher(
            capacityReader: { bsdName, _ in
                .init(bsdName: bsdName, totalBytes: 100, availableBytes: 40, consumedBytes: 60)
            }
        )
        let device = ExternalDevice(
            id: DeviceID(rawValue: "disk4"),
            displayName: "Test",
            transportName: "USB",
            physicalStoreBSDName: "disk4",
            apfsContainerBSDName: "disk10",
            volumes: [MountedVolume(bsdName: "disk4s1", mountPoint: "/Volumes/Test")]
        )
        let controller = DrivePulseAppController(
            state: DrivePulseAppState(devices: [device], selectedDeviceID: device.id),
            deviceDiscovery: StubExternalDeviceDiscovery(results: [[device]]),
            diskUtilAPFSProvider: StubDiskUtilAPFSProvider(),
            volumeCapacityRefresher: capacityRefresher
        )

        capacityRefresher.start(
            mountPoints: ["disk4s1": "/Volumes/Test"],
            physicalBSDNames: ["disk4s1": "disk4"]
        )
        await waitUntil {
            controller.state.devices.first?.volumes.first?.capacityConsumedBytes == 60
        }
        capacityRefresher.stop()

        XCTAssertEqual(controller.state.devices.first?.volumes.first?.capacityAvailableBytes, 40)
    }

    func testCapacityRefresherRunsReaderOffMainThreadAndSupersedesImmediateRefresh() async throws {
        let firstStarted = expectation(description: "first started")
        let releaseFirst = DispatchSemaphore(value: 0)
        let updates = ControllerTestLockedArray<[VolumeCapacityRefresher.CapacityUpdate]>()
        let readerCalls = ControllerTestLockedArray<Int>()
        let mainThreadReads = ControllerTestLockedArray<Bool>()
        let refresher = VolumeCapacityRefresher(capacityReader: { bsdName, _ -> VolumeCapacityRefresher.CapacityUpdate? in
            let call = readerCalls.values.count + 1
            readerCalls.append(call)
            mainThreadReads.append(Thread.isMainThread)
            if call == 1 {
                firstStarted.fulfill()
                releaseFirst.wait()
            }
            return .init(
                bsdName: bsdName,
                totalBytes: call == 1 ? 100 : 200,
                availableBytes: 40,
                consumedBytes: call == 1 ? 60 : 160
            )
        })
        refresher.onUpdate = { updates.append($0) }

        refresher.start(mountPoints: ["disk4s1": "/Volumes/Test"])
        await fulfillment(of: [firstStarted], timeout: 1)
        refresher.start(mountPoints: ["disk4s1": "/Volumes/Test"])
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(readerCalls.values, [1])
        releaseFirst.signal()
        await waitUntil { updates.values.last?.first?.totalBytes == 200 }
        refresher.stop()

        XCTAssertEqual(mainThreadReads.values, [false, false])
        XCTAssertEqual(updates.values.count, 1)
        XCTAssertEqual(updates.values.first?.first?.totalBytes, 200)
    }

    func testControllerRetriesAPFSEnrichmentWhenVolumeDetailsAreIncomplete() async throws {
        let bootstrapDevice = makeDevice(
            id: "disk21",
            volumes: ["disk21s2s1"],
            physicalStoreBSDName: "disk21",
            apfsContainerBSDName: "disk21s2"
        )
        let discovery = StubExternalDeviceDiscovery(results: [[bootstrapDevice]])
        let diskUtilProvider = RetryingStubDiskUtilAPFSProvider(
            refreshResults: [
                [
                    "disk21s2": APFSContainerInfo(
                        bsdName: "disk21s2",
                        totalCapacityBytes: 2_000,
                        capacityInUseBytes: 1_500,
                        capacityNotAllocatedBytes: 500,
                        volumes: [
                            APFSVolumeDetails(
                                volumeName: "Macintosh HD",
                                bsdName: "disk21s2s1",
                                capacityConsumedBytes: 1_500,
                                volumeUUID: "volume-uuid",
                                isVolumeDetailComplete: false
                            )
                        ]
                    )
                ],
                [
                    "disk21s2": APFSContainerInfo(
                        bsdName: "disk21s2",
                        totalCapacityBytes: 2_000,
                        capacityInUseBytes: 1_500,
                        capacityNotAllocatedBytes: 500,
                        volumes: [
                            APFSVolumeDetails(
                                volumeName: "Macintosh HD",
                                bsdName: "disk21s2s1",
                                mountPoint: "/Volumes/Macintosh HD",
                                sealed: false,
                                writable: true,
                                volumeUUID: "volume-uuid",
                                isVolumeDetailComplete: true
                            )
                        ]
                    )
                ]
            ]
        )
        let controller = DrivePulseAppController(
            deviceDiscovery: discovery,
            systemProfilerProvider: DelayedSystemProfilerProvider(fetchDelayNanoseconds: 1_000_000_000),
            diskUtilAPFSProvider: diskUtilProvider
        )

        await discovery.resolveNextDiscovery()
        await waitUntilStateDevices(controller, equals: [bootstrapDevice])

        await waitUntilStateDevices(controller) { devices in
            guard let device = devices.first else { return false }
            return device.apfsContainerDetails?.volumes.first?.isVolumeDetailComplete == true
                && device.apfsContainerDetails?.volumes.first?.sealed == false
                && device.apfsContainerDetails?.volumes.first?.writable == true
        }
        XCTAssertGreaterThanOrEqual(diskUtilProvider.refreshCallCount, 2)
    }

    func testObservedControllerTransportDoesNotOverrideKnownThunderboltTransport() async throws {
        let bootstrapDevice = makeDevice(
            id: "disk84",
            volumes: ["disk84s2s1"],
            transportName: "Thunderbolt",
            physicalStoreBSDName: "disk84",
            apfsContainerBSDName: "disk84s2"
        )
        let observedDevice = makeDevice(
            id: "disk84",
            volumes: ["disk84s2s1"],
            transportName: "IONVMeController",
            physicalStoreBSDName: "disk84",
            apfsContainerBSDName: "disk84s2"
        )
        let discovery = StubExternalDeviceDiscovery(results: [[bootstrapDevice]])
        let controller = DrivePulseAppController(
            deviceDiscovery: discovery,
            systemProfilerProvider: StubSystemProfilerProvider(),
            diskUtilAPFSProvider: StubDiskUtilAPFSProvider()
        )

        await discovery.resolveNextDiscovery()
        await waitUntilStateDevices(controller, equals: [bootstrapDevice])

        discovery.emit([observedDevice])

        await waitUntilStateDevices(controller) { devices in
            devices.first?.transportName == "Thunderbolt"
        }
    }

    func testRepeatedObservedUpdatesDoNotRestartSystemProfilerEnrichmentForSameDevice() async throws {
        let bootstrapDevice = makeDevice(
            id: "disk84",
            volumes: ["disk84s2s1"],
            transportName: "Thunderbolt",
            physicalStoreBSDName: "disk84",
            apfsContainerBSDName: "disk84s2"
        )
        let observedDevice = makeDevice(
            id: "disk84",
            volumes: ["disk84s2s1"],
            transportName: "Thunderbolt",
            physicalStoreBSDName: "disk84",
            apfsContainerBSDName: "disk84s2"
        )
        let discovery = StubExternalDeviceDiscovery(results: [[bootstrapDevice]])
        let systemProfilerProvider = DelayedRefreshingStubSystemProfilerProvider(
            refreshDelayNanoseconds: 500_000_000,
            refreshedNVMeInfoByBSDName: [
                "disk84": NVMeInfo(
                    controller: "Controller B",
                    model: "Model B",
                    serialNumber: "SERIAL-B",
                    firmwareVersion: "FW-B"
                )
            ],
            refreshedPCIInfoBySerialNumber: [
                "SERIAL-B": PCIInfo(
                    slot: "Thunderbolt@67,0,0",
                    vendorID: "0x144d",
                    deviceID: "0xa808"
                )
            ],
            refreshedThunderboltInfo: ThunderboltInfo(
                vendorName: "ACASIS",
                deviceName: "TB406Pro",
                uid: "0x8086DA2A0D19ED00"
            )
        )
        let controller = DrivePulseAppController(
            deviceDiscovery: discovery,
            systemProfilerProvider: systemProfilerProvider,
            diskUtilAPFSProvider: StubDiskUtilAPFSProvider()
        )

        await discovery.resolveNextDiscovery()
        await waitUntilStateDevices(controller, equals: [bootstrapDevice])

        discovery.emit([observedDevice])
        await systemProfilerProvider.waitUntilRefreshCallCount(is: 1)

        try? await Task.sleep(nanoseconds: 300_000_000)
        discovery.emit([observedDevice])
        try? await Task.sleep(nanoseconds: 300_000_000)

        let selectedDevice = try XCTUnwrap(controller.state.selectedDevice)
        XCTAssertEqual(selectedDevice.nvmeInfo?.serialNumber, "SERIAL-B")
        XCTAssertEqual(selectedDevice.pciInfo?.vendorID, "0x144d")
        XCTAssertEqual(selectedDevice.thunderboltInfo?.uid, "0x8086DA2A0D19ED00")
    }

    func testControllerDoesNotAssignSharedThunderboltInfoToMultipleThunderboltDevices() async {
        let firstDevice = makeDevice(
            id: "disk21",
            volumes: [],
            transportName: "Thunderbolt"
        )
        let secondDevice = makeDevice(
            id: "disk42",
            volumes: [],
            transportName: "Thunderbolt"
        )
        let discovery = StubExternalDeviceDiscovery(results: [[firstDevice, secondDevice]])
        let controller = DrivePulseAppController(
            deviceDiscovery: discovery,
            systemProfilerProvider: StubSystemProfilerProvider(
                refreshedThunderboltInfo: ThunderboltInfo(
                    vendorName: "Acme",
                    deviceName: "Shared Enclosure"
                )
            ),
            diskUtilAPFSProvider: StubDiskUtilAPFSProvider()
        )

        discovery.emit([firstDevice, secondDevice])

        await waitUntilStateDevices(controller, where: { $0.count == 2 })
        XCTAssertEqual(controller.state.devices.map(\.thunderboltInfo), [nil, nil])
    }

    func testCapacityUpdatesRefreshContainerCapacityWithoutOverwritingVolumeConsumed() async throws {
        let refresher = VolumeCapacityRefresher()
        let device = makeDevice(
            id: "disk21",
            volumes: ["disk21s2s1"],
            apfsContainerBSDName: "disk21s2",
            apfsContainerDetails: APFSContainerInfo(
                bsdName: "disk21s2",
                totalCapacityBytes: 100,
                capacityInUseBytes: 60,
                capacityNotAllocatedBytes: 40,
                volumes: [
                    APFSVolumeDetails(
                        volumeName: "Macintosh HD",
                        bsdName: "disk21s2s1",
                        mountPoint: "/Volumes/Macintosh HD",
                        capacityConsumedBytes: 60
                    )
                ]
            )
        )
        let controller = DrivePulseAppController(
            state: DrivePulseAppState(
                devices: [device],
                selectedDeviceID: device.id
            ),
            deviceDiscovery: StubExternalDeviceDiscovery(results: [[device]]),
            volumeCapacityRefresher: refresher
        )

        refresher.onUpdate?([
            VolumeCapacityRefresher.CapacityUpdate(
                bsdName: "disk21s2s1",
                totalBytes: 200,
                availableBytes: 50,
                consumedBytes: 150
            )
        ])

        await waitUntilStateDevices(controller) { devices in
            devices.first?.apfsContainerDetails?.capacityInUseBytes == 150
        }

        let updatedDevice: ExternalDevice = try XCTUnwrap(controller.state.selectedDevice)
        let container: APFSContainerInfo = try XCTUnwrap(updatedDevice.apfsContainerDetails)
        XCTAssertEqual(container.totalCapacityBytes, 200)
        XCTAssertEqual(container.capacityInUseBytes, 150)
        XCTAssertEqual(container.capacityNotAllocatedBytes, 50)
        XCTAssertEqual(container.volumes.first?.capacityConsumedBytes, 60)
    }

    func testControllerWritesNonZeroSessionMetricsAfterSamplingDelta() throws {
        let initialDevice = makeDevice(id: "disk21", volumes: ["disk21s1"])
        let sampler = StubDiskSampler(samplesByBSDName: [
            "disk21": [
                DiskIOCounters(readBytes: 1_000, writeBytes: 2_000),
                DiskIOCounters(readBytes: 2_500, writeBytes: 2_750)
            ]
        ])
        let controller = DrivePulseAppController(
            state: DrivePulseAppState(
                devices: [initialDevice],
                selectedDeviceID: initialDevice.id
            ),
            diskSampler: sampler,
            deviceDiscovery: StubExternalDeviceDiscovery(results: [[initialDevice]])
        )

        controller.sampleDeviceThroughput(at: Date(timeIntervalSince1970: 1_000))
        controller.sampleDeviceThroughput(at: Date(timeIntervalSince1970: 1_001))

        let sampledDevice = try XCTUnwrap(controller.state.selectedDevice)
        XCTAssertGreaterThan(
            sampledDevice.sessionMetrics.currentReadBytesPerSecond,
            0,
            "Expected periodic sampling to publish a non-zero read throughput for the selected device."
        )
        XCTAssertGreaterThan(
            sampledDevice.sessionMetrics.currentWriteBytesPerSecond,
            0,
            "Expected periodic sampling to publish a non-zero write throughput for the selected device."
        )
    }

    func testRefreshPreservesExistingSessionMetricsWhenRediscoveryReturnsSameDeviceID() async throws {
        let sampledMetrics = DeviceSessionMetrics(
            currentReadBytesPerSecond: 512,
            currentWriteBytesPerSecond: 256,
            cumulativeReadBytes: 4_096,
            cumulativeWriteBytes: 2_048,
            readHistory: [
                SpeedPoint(
                    timestamp: Date(timeIntervalSince1970: 1_000),
                    bytesPerSecond: 512
                )
            ],
            writeHistory: [
                SpeedPoint(
                    timestamp: Date(timeIntervalSince1970: 1_000),
                    bytesPerSecond: 256
                )
            ]
        )
        let initialDevice = makeDevice(
            id: "disk21",
            volumes: ["disk21s1"],
            sessionMetrics: sampledMetrics
        )
        let rediscoveredDevice = makeDevice(id: "disk21", volumes: ["disk21s1"])
        let discovery = StubExternalDeviceDiscovery(results: [[rediscoveredDevice]])
        let controller = DrivePulseAppController(
            state: DrivePulseAppState(
                devices: [initialDevice],
                selectedDeviceID: initialDevice.id
            ),
            deviceDiscovery: discovery
        )

        controller.refresh()
        await discovery.resolveNextDiscovery()
        await waitUntilSelectedDeviceDisplayName(
            controller,
            equals: rediscoveredDevice.displayName
        )

        let selectedDevice = try XCTUnwrap(controller.state.selectedDevice)
        XCTAssertEqual(selectedDevice.id, initialDevice.id)
        XCTAssertEqual(selectedDevice.sessionMetrics, sampledMetrics)
    }

    func testControllerCancelsDiscoveryObservationOnDeinit() {
        let discovery = StubExternalDeviceDiscovery(results: [[makeDevice(id: "disk21", volumes: [])]])
        var controller: DrivePulseAppController? = DrivePulseAppController(deviceDiscovery: discovery)

        XCTAssertEqual(discovery.cancellationCount, 0)

        controller = nil

        XCTAssertNil(controller)
        XCTAssertEqual(discovery.cancellationCount, 1)
    }

    func testEjectRoutesSelectedIdentityAndTopologyGenerationToCoordinator() async throws {
        let device = makeDevice(id: "disk21", volumes: [])
        let discovery = StubExternalDeviceDiscovery(results: [[device]])
        let resolver = RecordingEjectTargetResolver(device: device)
        let ejecter = BlockingDiskEjecter()
        let coordinator = makeEjectCoordinator(resolver: resolver, ejecter: ejecter)
        let actionPerformer = StubSystemActionPerformer()
        let controller = DrivePulseAppController(
            state: DrivePulseAppState(devices: [device], selectedDeviceID: device.id),
            systemActions: actionPerformer,
            deviceDiscovery: discovery,
            ejectCoordinator: coordinator
        )
        let action = try XCTUnwrap(controller.selectedFooterActions.first(where: { $0.kind == .eject }))

        discovery.emit([device])
        await waitUntilStateDevices(controller, equals: [device])
        controller.perform(action)

        await ejecter.waitUntilNormalEjectStarts()
        let requests = await resolver.resolveRequestsSnapshot()
        XCTAssertEqual(
            requests,
            [.init(deviceID: device.id, displayName: device.displayName, topologyGeneration: 1)]
        )
        let performedActions = await actionPerformer.performedActionsSnapshot()
        XCTAssertTrue(performedActions.isEmpty)
        XCTAssertNil(controller.actionFeedback)

        await ejecter.finishNormalEject()
    }

    func testObservedTopologyChangesAreForwardedDuringActiveEjectWorkflow() async throws {
        let device = makeDevice(id: "disk21", volumes: [])
        let discovery = StubExternalDeviceDiscovery(results: [[device]])
        let resolver = RecordingEjectTargetResolver(device: device)
        let ejecter = BlockingDiskEjecter()
        let coordinator = makeEjectCoordinator(resolver: resolver, ejecter: ejecter)
        let controller = DrivePulseAppController(
            state: DrivePulseAppState(devices: [device], selectedDeviceID: device.id),
            deviceDiscovery: discovery,
            ejectCoordinator: coordinator
        )
        let action = try XCTUnwrap(controller.selectedFooterActions.first(where: { $0.kind == .eject }))

        controller.perform(action)
        await ejecter.waitUntilNormalEjectStarts()
        let revalidationsBeforeUpdate = await resolver.revalidationCountSnapshot()

        discovery.emit([device])
        await waitUntil { await resolver.revalidationCountSnapshot() > revalidationsBeforeUpdate }

        await ejecter.finishNormalEject()
    }

    func testActiveEjectWorkflowDisablesActionsAfterSelectingAnotherDiskButKeepsThroughputSampling() async throws {
        let firstDevice = makeDevice(id: "disk21", volumes: [])
        let secondDevice = makeDevice(id: "disk42", volumes: [])
        let resolver = RecordingEjectTargetResolver(device: firstDevice)
        let ejecter = BlockingDiskEjecter()
        let coordinator = makeEjectCoordinator(resolver: resolver, ejecter: ejecter)
        let sampler = StubDiskSampler(samplesByBSDName: [
            "disk42": [
                DiskIOCounters(readBytes: 100, writeBytes: 200),
                DiskIOCounters(readBytes: 400, writeBytes: 700)
            ]
        ])
        let controller = DrivePulseAppController(
            state: DrivePulseAppState(
                devices: [firstDevice, secondDevice],
                selectedDeviceID: firstDevice.id
            ),
            diskSampler: sampler,
            deviceDiscovery: StubExternalDeviceDiscovery(results: [[firstDevice, secondDevice]]),
            ejectCoordinator: coordinator
        )
        let action = try XCTUnwrap(controller.selectedFooterActions.first(where: { $0.kind == .eject }))

        controller.perform(action)
        await ejecter.waitUntilNormalEjectStarts()
        controller.selectDevice(secondDevice.id)

        XCTAssertTrue(controller.isPerformingSystemAction)
        controller.sampleDeviceThroughput(at: Date(timeIntervalSince1970: 1))
        controller.sampleDeviceThroughput(at: Date(timeIntervalSince1970: 2))
        let metrics = try XCTUnwrap(controller.state.device(id: secondDevice.id)?.sessionMetrics)
        XCTAssertEqual(metrics.currentReadBytesPerSecond, 300)
        XCTAssertEqual(metrics.currentWriteBytesPerSecond, 500)

        await ejecter.finishNormalEject()
    }

    func testBusyRecoveryDoesNotBecomeTransientActionFeedbackOrClearAfterFailureDuration() async throws {
        let device = makeDevice(id: "disk21", volumes: [])
        let resolver = RecordingEjectTargetResolver(device: device)
        let failure = EjectFailure(
            stage: .unmounting,
            category: .busy,
            rawStatus: nil,
            systemMessage: "busy",
            physicalBSDName: "disk21",
            holders: []
        )
        let coordinator = makeEjectCoordinator(
            resolver: resolver,
            ejecter: ImmediateDiskEjecter(normalResult: .failure(failure)),
            occupancyScanner: FixedOccupancyScanner()
        )
        let controller = DrivePulseAppController(
            state: DrivePulseAppState(devices: [device], selectedDeviceID: device.id),
            deviceDiscovery: StubExternalDeviceDiscovery(results: [[device]]),
            ejectCoordinator: coordinator,
            actionFailureFeedbackDuration: 0.01
        )
        let action = try XCTUnwrap(controller.selectedFooterActions.first(where: { $0.kind == .eject }))

        controller.perform(action)
        await waitUntil {
            if case .awaitingRecovery = coordinator.state { return true }
            return false
        }
        try await Task.sleep(for: .milliseconds(50))

        if case .awaitingRecovery = coordinator.state {
            // Expected persistent recovery state.
        } else {
            XCTFail("Expected busy recovery to remain until an explicit intent.")
        }
        XCTAssertNil(controller.actionFeedback)
    }

    func testSuccessfulEjectPublishesSafeRemovalFeedbackAndAutoDismisses() async throws {
        let device = makeDevice(id: "disk21", volumes: [])
        let coordinator = makeEjectCoordinator(
            resolver: RecordingEjectTargetResolver(device: device),
            ejecter: ImmediateDiskEjecter(normalResult: .success(()))
        )
        let controller = DrivePulseAppController(
            state: DrivePulseAppState(devices: [device], selectedDeviceID: device.id),
            deviceDiscovery: StubExternalDeviceDiscovery(results: [[device]]),
            ejectCoordinator: coordinator,
            actionSuccessFeedbackDuration: 0.01
        )
        let action = try XCTUnwrap(controller.selectedFooterActions.first(where: { $0.kind == .eject }))

        controller.perform(action)
        await waitUntil { controller.actionFeedback != nil }
        guard case .succeeded(let target) = coordinator.state else {
            return XCTFail("Expected successful eject state")
        }
        XCTAssertEqual(
            controller.actionFeedback,
            EjectLocalization.successFeedback(target: target)
        )
        await waitUntilEventually(timeout: 1) { controller.actionFeedback == nil }
    }

    func testDisappearancePublishesNeutralFeedbackAndAutoDismisses() async throws {
        let device = makeDevice(id: "disk21", volumes: [])
        let coordinator = makeEjectCoordinator(
            resolver: DisappearingEjectTargetResolver(device: device),
            ejecter: ImmediateDiskEjecter(normalResult: .success(()))
        )
        let controller = DrivePulseAppController(
            state: DrivePulseAppState(devices: [device], selectedDeviceID: device.id),
            deviceDiscovery: StubExternalDeviceDiscovery(results: [[device]]),
            ejectCoordinator: coordinator,
            actionFailureFeedbackDuration: 0.01
        )
        let action = try XCTUnwrap(controller.selectedFooterActions.first(where: { $0.kind == .eject }))

        controller.perform(action)
        await waitUntil { controller.actionFeedback != nil }
        let feedback = try XCTUnwrap(controller.actionFeedback)
        guard case .disappeared(let target) = coordinator.state else {
            return XCTFail("Expected neutral disappearance state")
        }
        XCTAssertEqual(
            feedback,
            EjectLocalization.disappearanceFeedback(target: target)
        )
        XCTAssertNotEqual(feedback, EjectLocalization.successFeedback(target: target))
        await waitUntilEventually(timeout: 1) { controller.actionFeedback == nil }
    }

    func testAppCompositionSharesTrackerAcrossEjectAndDrivePulseOwnedIO() async throws {
        let disk4 = makeDevice(id: "disk4", volumes: ["disk4s1"])
        let disk5 = makeDevice(id: "disk5", volumes: [])
        let tracker = DeviceIOTracker()
        let probe = AppCompositionIOProbe()
        let handshake = try DrivePulseXPCMessages.encode(HelperHandshake(
            helperVersion: "1.0.0",
            contractMajor: XPCContractVersion.currentMajor,
            contractMinor: XPCContractVersion.currentMinor
        ))
        let smartService = SMARTServiceClient(
            fetchHelperHandshake: { handshake },
            readSMARTData: { data in
                await probe.recordSMARTRead()
                return Data("{}".utf8)
            },
            scanDiskOccupancy: { requestData in
                let request = try DrivePulseXPCMessages.decodeOccupancyRequest(from: requestData)
                await probe.recordOccupancyScan()
                return try DrivePulseXPCMessages.encodeOccupancyResponse(.init(
                    workflowID: request.workflowID,
                    holders: [],
                    isComplete: true
                ))
            },
            deviceIOTracker: tracker
        )
        let systemProfiler = LiveSystemProfilerProvider(
            dataTypeRunner: { dataType in
                await probe.recordSystemProfiler(dataType)
                return nil
            },
            deviceIOTracker: tracker
        )
        let diskUtil = LiveDiskUtilAPFSProvider(
            commandRunner: { _, arguments in
                await probe.recordDiskUtil(arguments)
                return nil
            },
            deviceIOTracker: tracker,
            physicalBSDNameResolver: { $0 }
        )
        let capacityProbe = LockedCapacityProbe()
        let capacityRefresher = VolumeCapacityRefresher(
            deviceIOTracker: tracker,
            capacityReader: { bsdName, _ in
                capacityProbe.record(bsdName)
                return .init(
                    bsdName: bsdName,
                    totalBytes: 100,
                    availableBytes: 40,
                    consumedBytes: 60
                )
            }
        )
        let resolver = RecordingEjectTargetResolver(device: disk4)
        let busyFailure = EjectFailure(
            stage: .unmounting,
            category: .busy,
            rawStatus: nil,
            systemMessage: "busy",
            physicalBSDName: "disk4",
            holders: []
        )
        let ejecter = BlockingDiskEjecter(result: .failure(busyFailure))
        let sampler = StubDiskSampler(samplesByBSDName: [
            "disk5": [
                DiskIOCounters(readBytes: 10, writeBytes: 20),
                DiskIOCounters(readBytes: 110, writeBytes: 220)
            ]
        ])
        let controller = DrivePulseApp.makeController(
            state: DrivePulseAppState(devices: [disk4, disk5], selectedDeviceID: disk4.id),
            deviceIOTracker: tracker,
            smartService: smartService,
            diskSampler: sampler,
            deviceDiscovery: StubExternalDeviceDiscovery(results: [[disk4, disk5]]),
            systemProfilerProvider: systemProfiler,
            diskUtilAPFSProvider: diskUtil,
            volumeCapacityRefresher: capacityRefresher,
            ejectTargetResolver: resolver,
            diskEjecter: ejecter,
            appOccupancyScanner: EmptyAppOccupancyScanner()
        )

        XCTAssertTrue(smartService.usesDeviceIOTracker(tracker))
        XCTAssertTrue(systemProfiler.usesDeviceIOTracker(tracker))
        XCTAssertTrue(diskUtil.usesDeviceIOTracker(tracker))
        XCTAssertTrue(capacityRefresher.usesDeviceIOTracker(tracker))
        XCTAssertTrue(controller.deviceIOQuiescer.tracker === tracker)

        let ejectAction = try XCTUnwrap(
            controller.selectedFooterActions.first(where: { $0.kind == .eject })
        )
        controller.perform(ejectAction)
        await ejecter.waitUntilNormalEjectStarts()

        _ = await smartService.refreshSMART(for: disk4)
        await diskUtil.refresh(targets: [
            APFSTopologyTarget(physicalBSDName: "disk4", containerBSDName: nil)
        ])
        await systemProfiler.refresh()
        capacityRefresher.start(
            mountPoints: ["disk4s1": "/Volumes/Test"],
            physicalBSDNames: ["disk4s1": "disk4"]
        )
        await Task.yield()

        let pausedSMARTReadCount = await probe.smartReadCount()
        let pausedSystemProfilerCallCount = await probe.systemProfilerCallCount()
        let pausedDisk4DiskUtilCallCount = await probe.diskUtilCallCount(for: "disk4")
        XCTAssertEqual(pausedSMARTReadCount, 0)
        XCTAssertEqual(pausedSystemProfilerCallCount, 3)
        XCTAssertEqual(pausedDisk4DiskUtilCallCount, 0)
        XCTAssertEqual(capacityProbe.count(for: "disk4s1"), 0)

        await diskUtil.refresh(targets: [
            APFSTopologyTarget(physicalBSDName: "disk5", containerBSDName: nil)
        ])
        let disk5DiskUtilCallCount = await probe.diskUtilCallCount(for: "disk5")
        XCTAssertGreaterThan(disk5DiskUtilCallCount, 0)

        controller.sampleDeviceThroughput(at: Date(timeIntervalSince1970: 1))
        controller.sampleDeviceThroughput(at: Date(timeIntervalSince1970: 2))
        let disk5Metrics = try XCTUnwrap(controller.state.device(id: disk5.id)?.sessionMetrics)
        XCTAssertEqual(disk5Metrics.currentReadBytesPerSecond, 100)
        XCTAssertEqual(disk5Metrics.currentWriteBytesPerSecond, 200)

        await ejecter.finishNormalEject()
        await waitUntil { await probe.occupancyScanCount() == 1 }
        controller.cancelEject()
        await waitUntil { controller.ejectCoordinator.state == .idle }

        _ = await smartService.refreshSMART(for: disk4)
        await diskUtil.refresh(targets: [
            APFSTopologyTarget(physicalBSDName: "disk4", containerBSDName: nil)
        ])
        await systemProfiler.refresh()
        capacityRefresher.updateMountPoints(
            ["disk4s1": "/Volumes/Test"],
            physicalBSDNames: ["disk4s1": "disk4"]
        )
        capacityRefresher.start(
            mountPoints: ["disk4s1": "/Volumes/Test"],
            physicalBSDNames: ["disk4s1": "disk4"]
        )
        await waitUntil { capacityProbe.count(for: "disk4s1") > 0 }
        capacityRefresher.stop()

        let resumedSMARTReadCount = await probe.smartReadCount()
        let resumedSystemProfilerCallCount = await probe.systemProfilerCallCount()
        let resumedDisk4DiskUtilCallCount = await probe.diskUtilCallCount(for: "disk4")
        XCTAssertEqual(resumedSMARTReadCount, 1)
        XCTAssertEqual(resumedSystemProfilerCallCount, 6)
        XCTAssertGreaterThan(resumedDisk4DiskUtilCallCount, 0)

        let leakCheckBarrier = try await controller.deviceIOQuiescer.acquireBarrier(
            for: EjectWorkflowTarget(
                deviceID: disk4.id,
                physicalBSDName: "disk4",
                mediaRegistryEntryID: 42,
                displayName: disk4.displayName,
                topologyGeneration: 0
            ),
            timeout: Duration.milliseconds(100)
        )
        try await leakCheckBarrier.waitUntilReady()
        await leakCheckBarrier.release()
    }

    func testPerformRunsActionAsynchronouslyAndPublishesFailureFeedback() async {
        let actionPerformer = StubSystemActionPerformer()
        let controller = DrivePulseAppController(
            systemActions: actionPerformer,
            deviceDiscovery: StubExternalDeviceDiscovery(results: [[makeDevice(id: "disk21", volumes: [])]])
        )
        let action = SystemAction(
            kind: .openInFinder,
            intent: .revealInFinder(volumeBSDName: "disk21s1")
        )

        controller.perform(action)

        XCTAssertNil(controller.actionFeedback)
        await actionPerformer.waitUntilStarted()
        let performedActions = await actionPerformer.performedActionsSnapshot()
        XCTAssertEqual(performedActions, [action])

        await actionPerformer.finish(
            with: TestActionError.failed(message: "Action couldn't be completed.")
        )

        let feedbackExpectation = expectation(description: "feedback updated")
        Task { @MainActor in
            while controller.actionFeedback == nil {
                await Task.yield()
            }

            feedbackExpectation.fulfill()
        }

        await fulfillment(of: [feedbackExpectation], timeout: 1.0)
        XCTAssertEqual(controller.actionFeedback, "Action couldn't be completed.")
    }

    func testPerformPublishesSuccessFeedbackAndClearsItAfterCompletion() async {
        let actionPerformer = StubSystemActionPerformer()
        let controller = DrivePulseAppController(
            systemActions: actionPerformer,
            deviceDiscovery: StubExternalDeviceDiscovery(results: [[makeDevice(id: "disk21", volumes: [])]]),
            actionSuccessFeedbackDuration: 2.5
        )
        let action = SystemAction(
            kind: .openDiskUtility,
            intent: .openDiskUtility(bsdName: "disk21")
        )

        controller.perform(action)

        await actionPerformer.waitUntilStarted()
        await actionPerformer.finish()

        await waitUntilActionCompletes(controller)
        XCTAssertEqual(controller.actionFeedback, action.successFeedbackMessage)
        await waitUntilEventually(timeout: 5.0) { controller.actionFeedback == nil }
    }

    func testQuitActionPublishesFeedbackBeforeInvokingQuitHandler() async {
        let quitRecorder = MainActorQuitRecorder()
        let controller = DrivePulseAppController(
            systemActions: StubSystemActionPerformer(),
            deviceDiscovery: StubExternalDeviceDiscovery(results: [[makeDevice(id: "disk21", volumes: [])]]),
            quitFeedbackDuration: 4.0,
            quitHandler: {
                quitRecorder.recordInvocation()
            }
        )
        let action = SystemAction(kind: .quit, intent: .quit)

        controller.perform(action)

        XCTAssertEqual(controller.actionFeedback, action.successFeedbackMessage)
        XCTAssertEqual(quitRecorder.invocationCount, 0)
        XCTAssertTrue(controller.isPerformingSystemAction)

        await waitUntilEventually(timeout: 5.0) { quitRecorder.invocationCount == 1 }
        XCTAssertEqual(quitRecorder.invocationCount, 1)
        XCTAssertFalse(controller.isPerformingSystemAction)
    }

    func testPerformIgnoresSecondActionWhileAnotherActionIsInFlight() async {
        let actionPerformer = StubSystemActionPerformer()
        let controller = DrivePulseAppController(
            systemActions: actionPerformer,
            deviceDiscovery: StubExternalDeviceDiscovery(results: [[makeDevice(id: "disk21", volumes: [])]])
        )
        let firstAction = SystemAction(
            kind: .openDiskUtility,
            intent: .openDiskUtility(bsdName: "disk21")
        )
        let secondAction = SystemAction(
            kind: .openInFinder,
            intent: .revealInFinder(volumeBSDName: "disk21s1")
        )

        controller.perform(firstAction)
        await actionPerformer.waitUntilStarted()
        XCTAssertTrue(controller.isPerformingSystemAction)

        controller.perform(secondAction)

        let performedActions = await actionPerformer.performedActionsSnapshot()
        XCTAssertEqual(performedActions, [firstAction])

        await actionPerformer.finish()
        await waitUntilActionCompletes(controller)
        XCTAssertFalse(controller.isPerformingSystemAction)
    }

    func testDiscoveryObservationCancelStopsMonitoringWhenLastObserverIsRemoved() {
        let monitoringSession = StubDiskArbitrationMonitoringSession()
        let discovery = LiveExternalDeviceDiscovery(monitoringSession: monitoringSession)

        let observation = discovery.observeDevices { _ in }

        XCTAssertEqual(monitoringSession.activateCallCount, 1)
        XCTAssertEqual(monitoringSession.deactivateCallCount, 0)

        observation.cancel()

        XCTAssertEqual(monitoringSession.deactivateCallCount, 1)
    }

    func testDiscoveryKeepsMonitoringActiveWhileAnotherObserverExists() {
        let monitoringSession = StubDiskArbitrationMonitoringSession()
        let discovery = LiveExternalDeviceDiscovery(monitoringSession: monitoringSession)

        let firstObservation = discovery.observeDevices { _ in }
        let secondObservation = discovery.observeDevices { _ in }

        firstObservation.cancel()

        XCTAssertEqual(monitoringSession.activateCallCount, 1)
        XCTAssertEqual(monitoringSession.deactivateCallCount, 0)

        secondObservation.cancel()

        XCTAssertEqual(monitoringSession.deactivateCallCount, 1)
    }

    func testLiveSystemProfilerProviderCachesBootstrapFetchAndRefreshesCacheOnDemand() async {
        let runner = StubSystemProfilerDataTypeRunner(
            snapshots: [
                [
                    "SPNVMeDataType": [
                        [
                            "_name": "Controller A",
                            "items": [
                                [
                                    "bsd_name": "disk21",
                                    "serial_no": "SERIAL-A"
                                ]
                            ]
                        ]
                    ]
                ],
                [
                    "SPPCIDataType": [
                        [
                            "sppci_type": "NVM Controller",
                            "serial_no": "SERIAL-A",
                            "sppci_slot": "Slot-A"
                        ]
                    ]
                ],
                [
                    "SPThunderboltDataType": [
                        [
                            "items": [
                                [
                                    "vendor_name": "Acme",
                                    "device_name": "Enclosure A"
                                ]
                            ]
                        ]
                    ]
                ],
                [
                    "SPNVMeDataType": [
                        [
                            "_name": "Controller B",
                            "items": [
                                [
                                    "bsd_name": "disk21",
                                    "serial_no": "SERIAL-B"
                                ]
                            ]
                        ]
                    ]
                ],
                [
                    "SPPCIDataType": [
                        [
                            "sppci_type": "NVM Controller",
                            "serial_no": "SERIAL-B",
                            "sppci_slot": "Slot-B"
                        ]
                    ]
                ],
                [
                    "SPThunderboltDataType": [
                        [
                            "items": [
                                [
                                    "vendor_name": "Acme",
                                    "device_name": "Enclosure B"
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        )
        let provider = LiveSystemProfilerProvider(dataTypeRunner: runner.run)

        await provider.fetchIfNeeded()
        XCTAssertEqual(provider.nvmeInfo(forBSDName: "disk21", modelName: nil)?.serialNumber, "SERIAL-A")
        XCTAssertEqual(provider.pciInfo(forNVMeSerialNumber: "SERIAL-A")?.slot, "Slot-A")
        XCTAssertEqual(provider.thunderboltInfo()?.deviceName, "Enclosure A")

        await provider.fetchIfNeeded()
        let firstInvocationCount = await runner.invocationCount()
        XCTAssertEqual(firstInvocationCount, 3)

        await provider.refresh()
        XCTAssertEqual(provider.nvmeInfo(forBSDName: "disk21", modelName: nil)?.serialNumber, "SERIAL-B")
        XCTAssertEqual(provider.pciInfo(forNVMeSerialNumber: "SERIAL-B")?.slot, "Slot-B")
        XCTAssertEqual(provider.thunderboltInfo()?.deviceName, "Enclosure B")
        let secondInvocationCount = await runner.invocationCount()
        XCTAssertEqual(secondInvocationCount, 6)
    }

    func testLiveSystemProfilerProviderFetchesDataTypesConcurrently() async {
        let runner = ConcurrentSystemProfilerRunner()
        let provider = LiveSystemProfilerProvider(dataTypeRunner: runner.run)

        await provider.refresh()

        let invocationCount = await runner.invocationCount()
        let maxConcurrentInvocations = await runner.maxConcurrentInvocations()
        XCTAssertEqual(invocationCount, 3)
        XCTAssertGreaterThanOrEqual(maxConcurrentInvocations, 2)
    }

    func testLiveSystemProfilerProviderKeepsNewestCacheWhenRefreshesOverlap() async {
        let runner = OverlappingSystemProfilerRunner()
        let provider = LiveSystemProfilerProvider(dataTypeRunner: runner.run)
        let firstRefresh = Task {
            await provider.refresh()
        }

        await runner.waitUntilInvocationCount(is: 3)

        let secondRefresh = Task {
            await provider.refresh()
        }

        await runner.waitUntilInvocationCount(is: 6)
        await runner.resumeBatch(
            invocationIndices: [3, 4, 5],
            serialNumber: "SERIAL-NEW",
            slot: "Slot-New",
            thunderboltDeviceName: "Enclosure New"
        )
        await secondRefresh.value

        XCTAssertEqual(provider.nvmeInfo(forBSDName: "disk21", modelName: nil)?.serialNumber, "SERIAL-NEW")
        XCTAssertEqual(provider.pciInfo(forNVMeSerialNumber: "SERIAL-NEW")?.slot, "Slot-New")
        XCTAssertEqual(provider.thunderboltInfo()?.deviceName, "Enclosure New")

        await runner.resumeBatch(
            invocationIndices: [0, 1, 2],
            serialNumber: "SERIAL-OLD",
            slot: "Slot-Old",
            thunderboltDeviceName: "Enclosure Old"
        )
        await firstRefresh.value

        XCTAssertEqual(provider.nvmeInfo(forBSDName: "disk21", modelName: nil)?.serialNumber, "SERIAL-NEW")
        XCTAssertEqual(provider.pciInfo(forNVMeSerialNumber: "SERIAL-NEW")?.slot, "Slot-New")
        XCTAssertEqual(provider.thunderboltInfo()?.deviceName, "Enclosure New")
    }

    func testLiveSystemProfilerProviderReturnsNilWhenThunderboltCandidatesAreAmbiguous() async {
        let runner = StubSystemProfilerDataTypeRunner(
            snapshots: [
                [
                    "SPThunderboltDataType": [
                        [
                            "items": [
                                [
                                    "vendor_name": "Acme",
                                    "device_name": "Enclosure A"
                                ],
                                [
                                    "vendor_name": "Acme",
                                    "device_name": "Enclosure B"
                                ]
                            ]
                        ]
                    ]
                ],
                [
                    "SPNVMeDataType": []
                ],
                [
                    "SPPCIDataType": []
                ]
            ]
        )
        let provider = LiveSystemProfilerProvider(dataTypeRunner: runner.run)

        await provider.refresh()

        XCTAssertNil(provider.thunderboltInfo())
    }

    func testLiveSystemProfilerProviderParsesCurrentSystemProfilerKeys() async {
        let runner = StubSystemProfilerDataTypeRunner(
            snapshots: [
                [
                    "SPThunderboltDataType": [
                        [
                            "_name": "thunderboltusb4_bus_0",
                            "_items": [
                                [
                                    "_name": "TB406Pro",
                                    "device_name_key": "TB406Pro",
                                    "vendor_name_key": "ACASIS",
                                    "mode_key": "thunderbolt_three",
                                    "switch_uid_key": "0x8086DA2A0D19ED00",
                                    "switch_version_key": "67.1",
                                    "receptacle_upstream_ambiguous_tag": [
                                        "current_speed_key": "40 Gb/s",
                                        "lc_version_key": "1.45.0",
                                        "receptacle_status_key": "receptacle_connected"
                                    ]
                                ]
                            ]
                        ]
                    ]
                ],
                [
                    "SPNVMeDataType": [
                        [
                            "_name": "Generic SSD Controller",
                            "_items": [
                                [
                                    "device_model": "SAMSUNG MZVLB1T0HBLR-000L2",
                                    "device_serial": "SERIAL-B",
                                    "device_revision": "FW-B",
                                    "spnvme_linkspeed": "8.0 GT/s",
                                    "spnvme_linkwidth": "x4",
                                    "spnvme_trim_support": "Yes"
                                ]
                            ]
                        ]
                    ]
                ],
                [
                    "SPPCIDataType": [
                        [
                            "_name": "pci144d,a808",
                            "sppci_device_type": "sppci_nvme",
                            "sppci_serialnumber": "SERIAL-B",
                            "sppci_slot_name": "Thunderbolt@67,0,0",
                            "sppci_vendor-id": "0x144d",
                            "sppci_device-id": "0xa808",
                            "sppci_link-status": "Link up",
                            "sppci_link-width": "x4",
                            "sppci_link-speed": "8.0 GT/s",
                            "sppci_tunnel-compatible": "Yes"
                        ]
                    ]
                ]
            ]
        )
        let provider = LiveSystemProfilerProvider(dataTypeRunner: runner.run)

        await provider.refresh()

        let nvme = provider.nvmeInfo(
            forBSDName: "disk21",
            modelName: "SAMSUNG MZVLB1T0HBLR-000L2"
        )
        XCTAssertEqual(nvme?.serialNumber, "SERIAL-B")
        XCTAssertEqual(nvme?.firmwareVersion, "FW-B")
        XCTAssertEqual(nvme?.linkWidth, "x4")
        XCTAssertEqual(nvme?.linkSpeed, "8.0 GT/s")
        XCTAssertEqual(provider.pciInfo(forNVMeSerialNumber: "SERIAL-B")?.slot, "Thunderbolt@67,0,0")
        XCTAssertEqual(provider.pciInfo(forNVMeSerialNumber: "SERIAL-B")?.vendorID, "0x144d")
        XCTAssertEqual(provider.thunderboltInfo()?.deviceName, "TB406Pro")
        XCTAssertEqual(provider.thunderboltInfo()?.vendorName, "ACASIS")
        XCTAssertEqual(provider.thunderboltInfo()?.linkSpeed, "40 Gb/s")
    }

    func testLiveDiskUtilAPFSProviderCachesAPFSListUntilRefresh() async throws {
        let runner = StubDiskUtilCommandRunner(
            outputs: [
                try Self.makeAPFSListPlist(
                    containerBSDName: "disk21s2",
                    totalBytes: 100,
                    freeBytes: 40,
                    volumeConsumedBytes: 60
                ),
                try Self.makeAPFSListPlist(
                    containerBSDName: "disk21s2",
                    totalBytes: 300,
                    freeBytes: 50,
                    volumeConsumedBytes: 250
                )
            ]
        )
        let provider = LiveDiskUtilAPFSProvider(commandRunner: runner.run)

        let first = await provider.containerInfo(forContainerBSDName: "disk21s2")
        let second = await provider.containerInfo(forContainerBSDName: "disk21s2")

        XCTAssertEqual(first?.capacityInUseBytes, 60)
        XCTAssertEqual(second?.capacityInUseBytes, 60)
        let initialAPFSListInvocationCount = await runner.apfsListInvocationCount()
        XCTAssertEqual(initialAPFSListInvocationCount, 1)

        await provider.refresh(targets: [
            .init(physicalBSDName: "disk21", containerBSDName: "disk21s2")
        ])
        let refreshed = await provider.containerInfo(forContainerBSDName: "disk21s2")

        XCTAssertEqual(refreshed?.capacityInUseBytes, 250)
        XCTAssertEqual(refreshed?.capacityNotAllocatedBytes, 50)
        let refreshedAPFSListInvocationCount = await runner.apfsListInvocationCount()
        XCTAssertEqual(refreshedAPFSListInvocationCount, 2)
    }

    func testLiveDiskUtilAPFSProviderKeepsNewestCacheWhenRefreshesOverlap() async throws {
        let runner = OverlappingDiskUtilCommandRunner()
        let provider = LiveDiskUtilAPFSProvider(commandRunner: runner.run)
        let firstRefresh = Task {
            await provider.refresh(targets: [
                .init(physicalBSDName: "disk21", containerBSDName: "disk21s2")
            ])
        }

        await runner.waitUntilAPFSListInvocationCount(is: 1)

        let secondRefresh = Task {
            await provider.refresh(targets: [
                .init(physicalBSDName: "disk21", containerBSDName: "disk21s2")
            ])
        }

        await runner.waitUntilAPFSListInvocationCount(is: 2)
        await runner.resumeAPFSListInvocation(
            index: 1,
            data: try Self.makeAPFSListPlist(
                containerBSDName: "disk21s2",
                totalBytes: 300,
                freeBytes: 50,
                volumeConsumedBytes: 250
            )
        )
        await secondRefresh.value

        let refreshedCapacityInUse = await provider.containerInfo(
            forContainerBSDName: "disk21s2"
        )?.capacityInUseBytes
        XCTAssertEqual(refreshedCapacityInUse, 250)

        await runner.resumeAPFSListInvocation(
            index: 0,
            data: try Self.makeAPFSListPlist(
                containerBSDName: "disk21s2",
                totalBytes: 100,
                freeBytes: 40,
                volumeConsumedBytes: 60
            )
        )
        await firstRefresh.value

        let finalCapacityInUse = await provider.containerInfo(
            forContainerBSDName: "disk21s2"
        )?.capacityInUseBytes
        XCTAssertEqual(finalCapacityInUse, 250)
    }

    func testLiveDiskUtilAPFSProviderParsesCurrentAPFSVolumeKeys() async throws {
        let runner = StubDiskUtilCommandRunner(
            outputs: [
                try Self.makeCurrentAPFSListPlist(
                    containerBSDName: "disk21s2",
                    totalBytes: 100,
                    freeBytes: 40,
                    volumeCapacityInUseBytes: 60,
                    volumeUUID: "volume-uuid"
                )
            ]
        )
        let provider = LiveDiskUtilAPFSProvider(commandRunner: runner.run)

        let container = await provider.containerInfo(forContainerBSDName: "disk21s2")

        XCTAssertEqual(container?.capacityInUseBytes, 60)
        XCTAssertEqual(container?.capacityNotAllocatedBytes, 40)
        XCTAssertEqual(container?.volumes.first?.capacityConsumedBytes, 60)
        XCTAssertEqual(container?.volumes.first?.volumeUUID, "volume-uuid")
    }

    func testLiveDiskUtilAPFSProviderFallsBackToDiskInfoForMissingSealedFlag() async throws {
        let runner = StubDiskUtilCommandRunner(
            outputsByArguments: [
                ["apfs", "list", "-plist"]: [
                    try Self.makeCurrentAPFSListPlist(
                        containerBSDName: "disk21s2",
                        totalBytes: 100,
                        freeBytes: 40,
                        volumeCapacityInUseBytes: 60,
                        volumeUUID: "volume-uuid"
                    )
                ],
                ["info", "-plist", "/dev/disk21s2s1"]: [
                    try Self.makeDiskUtilVolumeInfoPlist(
                        bsdName: "disk21s2s1",
                        mountPoint: "/Volumes/Macintosh HD",
                        fileVaultEnabled: false,
                        sealed: "No",
                        writable: true,
                        volumeUUID: "volume-uuid"
                    )
                ]
            ]
        )
        let provider = LiveDiskUtilAPFSProvider(commandRunner: runner.run)

        let container = await provider.containerInfo(forContainerBSDName: "disk21s2")

        XCTAssertEqual(container?.volumes.first?.sealed, false)
        XCTAssertEqual(container?.volumes.first?.fileVaultEnabled, false)
        XCTAssertEqual(container?.volumes.first?.writable, true)
        XCTAssertEqual(container?.volumes.first?.mountPoint, "/Volumes/Macintosh HD")
        XCTAssertEqual(container?.volumes.first?.volumeUUID, "volume-uuid")
        XCTAssertEqual(container?.volumes.first?.isVolumeDetailComplete, true)
        let infoInvocationCount = await runner.diskInfoInvocationCount()
        XCTAssertEqual(infoInvocationCount, 1)
    }

    func testLiveDiskUtilAPFSProviderMarksVolumeDetailsIncompleteWhenDiskInfoFallbackFails() async throws {
        let runner = StubDiskUtilCommandRunner(
            outputsByArguments: [
                ["apfs", "list", "-plist"]: [
                    try Self.makeCurrentAPFSListPlist(
                        containerBSDName: "disk21s2",
                        totalBytes: 100,
                        freeBytes: 40,
                        volumeCapacityInUseBytes: 60,
                        volumeUUID: "volume-uuid"
                    )
                ]
            ]
        )
        let provider = LiveDiskUtilAPFSProvider(commandRunner: runner.run)

        let container = await provider.containerInfo(forContainerBSDName: "disk21s2")

        XCTAssertEqual(container?.volumes.first?.sealed, nil)
        XCTAssertEqual(container?.volumes.first?.writable, nil)
        XCTAssertEqual(container?.volumes.first?.isVolumeDetailComplete, false)
        let infoInvocationCount = await runner.diskInfoInvocationCount()
        XCTAssertEqual(infoInvocationCount, 1)
    }

    func testControllerBootstrapsAPFSDetailsWithoutWaitingForSystemProfiler() async throws {
        let bootstrapDevice = makeDevice(
            id: "disk21",
            volumes: ["disk21s2s1"],
            physicalStoreBSDName: "disk21",
            apfsContainerBSDName: "disk21s2"
        )
        let discovery = StubExternalDeviceDiscovery(results: [[bootstrapDevice]])
        let systemProfilerProvider = DelayedSystemProfilerProvider(fetchDelayNanoseconds: 1_000_000_000)
        let diskUtilProvider = StubDiskUtilAPFSProvider(
            bootstrapContainerInfoByBSDName: [
                "disk21s2": APFSContainerInfo(
                    bsdName: "disk21s2",
                    totalCapacityBytes: 2_000,
                    capacityInUseBytes: 1_500,
                    capacityNotAllocatedBytes: 500,
                    volumes: [
                        APFSVolumeDetails(
                            volumeName: "Observed",
                            bsdName: "disk21s2s1",
                            capacityConsumedBytes: 1_500,
                            volumeUUID: "volume-uuid"
                        )
                    ]
                )
            ]
        )
        let controller = DrivePulseAppController(
            deviceDiscovery: discovery,
            systemProfilerProvider: systemProfilerProvider,
            diskUtilAPFSProvider: diskUtilProvider
        )

        await discovery.resolveNextDiscovery()
        try? await Task.sleep(nanoseconds: 150_000_000)

        let selectedDevice = try XCTUnwrap(controller.state.selectedDevice)
        XCTAssertEqual(selectedDevice.apfsContainerDetails?.capacityInUseBytes, 1_500)
    }

    func testSubprocessRunnerDrainsLargeStdoutAndStderrWithoutWaitingForExitFirst() async throws {
        let processOutput = await SubprocessRunner.run(
            executable: "/bin/sh",
            arguments: [
                "-c",
                "(/usr/bin/yes x | /usr/bin/head -c 262144) & " +
                    "(/usr/bin/yes e | /usr/bin/head -c 262144) 1>&2 & wait"
            ]
        )
        let data: Data = try XCTUnwrap(processOutput)

        XCTAssertEqual(data.count, 262_144)
    }

    private func makeDevice(
        id rawID: String,
        volumes: [String],
        transportName: String = "USB",
        physicalStoreBSDName: String? = nil,
        apfsContainerBSDName: String? = nil,
        smartSnapshot: SmartSnapshot = .helperNotInstalled,
        sessionMetrics: DeviceSessionMetrics = .empty(historyLimit: 0),
        apfsContainerDetails: APFSContainerInfo? = nil,
        physicalPartitions: [PhysicalPartitionInfo] = []
    ) -> ExternalDevice {
        ExternalDevice(
            id: DeviceID(rawValue: rawID),
            displayName: "Device \(rawID)",
            transportName: transportName,
            smartSnapshot: smartSnapshot,
            sessionMetrics: sessionMetrics,
            physicalStoreBSDName: physicalStoreBSDName ?? rawID,
            apfsContainerBSDName: apfsContainerBSDName,
            volumes: volumes.map { MountedVolume(bsdName: $0) },
            apfsContainerDetails: apfsContainerDetails,
            physicalPartitions: physicalPartitions
        )
    }

    private func waitUntilStateDevices(
        _ controller: DrivePulseAppController,
        equals devices: [ExternalDevice]
    ) async {
        var iterations = 0
        while controller.state.devices != devices {
            iterations += 1
            if iterations > 10_000 {
                XCTFail("waitUntilStateDevices timed out after \(iterations) yields")
                return
            }
            await Task.yield()
        }
    }

    private func waitUntilStateDevices(
        _ controller: DrivePulseAppController,
        where predicate: @escaping ([ExternalDevice]) -> Bool
    ) async {
        var iterations = 0
        while predicate(controller.state.devices) == false {
            iterations += 1
            if iterations > 10_000 {
                XCTFail("waitUntilStateDevices timed out after \(iterations) yields")
                return
            }
            await Task.yield()
        }
    }

    private func waitUntilActionCompletes(_ controller: DrivePulseAppController) async {
        while controller.isPerformingSystemAction {
            await Task.yield()
        }
    }

    private func waitUntilSelectedDeviceDisplayName(
        _ controller: DrivePulseAppController,
        equals displayName: String
    ) async {
        while controller.state.selectedDevice?.displayName != displayName {
            await Task.yield()
        }
    }

    private func waitUntil(_ predicate: @escaping () -> Bool) async {
        var iterations = 0
        while predicate() == false {
            iterations += 1
            if iterations > 10_000 {
                XCTFail("waitUntil timed out after \(iterations) yields")
                return
            }
            await Task.yield()
        }
    }

    private func waitUntil(_ predicate: @escaping () async -> Bool) async {
        var iterations = 0
        while await predicate() == false {
            iterations += 1
            if iterations > 10_000 {
                XCTFail("waitUntil timed out after \(iterations) yields")
                return
            }
            await Task.yield()
        }
    }

    private func makeEjectCoordinator(
        resolver: any EjectTargetResolving,
        ejecter: any DiskEjecting,
        occupancyScanner: any OccupancyScanning = FixedOccupancyScanner()
    ) -> EjectCoordinator {
        EjectCoordinator(
            resolver: resolver,
            quiescer: ImmediateDeviceIOQuiescer(),
            ejecter: ejecter,
            occupancyScanner: occupancyScanner
        )
    }

    private func waitUntilEventually(
        timeout: TimeInterval = 3.0,
        _ predicate: @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while predicate() == false {
            if Date() >= deadline {
                XCTFail("waitUntilEventually timed out after \(timeout) seconds")
                return
            }

            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private static func makeAPFSListPlist(
        containerBSDName: String,
        totalBytes: Int64,
        freeBytes: Int64,
        volumeConsumedBytes: Int64
    ) throws -> Data {
        let plist: [String: Any] = [
            "Containers": [
                [
                    "ContainerReference": containerBSDName,
                    "CapacityCeiling": NSNumber(value: totalBytes),
                    "CapacityFree": NSNumber(value: freeBytes),
                    "Volumes": [
                        [
                            "Name": "Macintosh HD",
                            "DeviceIdentifier": "\(containerBSDName)s1",
                            "CapacityConsumed": NSNumber(value: volumeConsumedBytes)
                        ]
                    ]
                ]
            ]
        ]

        return try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
    }

    private static func makeCurrentAPFSListPlist(
        containerBSDName: String,
        totalBytes: Int64,
        freeBytes: Int64,
        volumeCapacityInUseBytes: Int64,
        volumeUUID: String
    ) throws -> Data {
        let plist: [String: Any] = [
            "Containers": [
                [
                    "ContainerReference": containerBSDName,
                    "APFSContainerUUID": "container-uuid",
                    "CapacityCeiling": NSNumber(value: totalBytes),
                    "CapacityFree": NSNumber(value: freeBytes),
                    "DesignatedPhysicalStore": "disk21s1",
                    "PhysicalStores": [
                        [
                            "DiskUUID": "physical-store-uuid"
                        ]
                    ],
                    "Volumes": [
                        [
                            "Name": "Macintosh HD",
                            "DeviceIdentifier": "\(containerBSDName)s1",
                            "CapacityInUse": NSNumber(value: volumeCapacityInUseBytes),
                            "APFSVolumeUUID": volumeUUID
                        ]
                    ]
                ]
            ]
        ]

        return try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
    }

    private static func makeDiskUtilVolumeInfoPlist(
        bsdName: String,
        mountPoint: String,
        fileVaultEnabled: Bool,
        sealed: String,
        writable: Bool,
        volumeUUID: String
    ) throws -> Data {
        let plist: [String: Any] = [
            "DeviceIdentifier": bsdName,
            "MountPoint": mountPoint,
            "FileVault": fileVaultEnabled,
            "Sealed": sealed,
            "Writable": writable,
            "VolumeUUID": volumeUUID
        ]

        return try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
    }
}

private final class ControllerTestLockedArray<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Element] = []

    var values: [Element] { lock.withLock { storage } }

    func append(_ element: Element) {
        lock.withLock { storage.append(element) }
    }
}

private final class StubDiskSampler: DiskSampling, @unchecked Sendable {
    private let lock = NSLock()
    private var samplesByBSDName: [String: [DiskIOCounters]]

    init(samplesByBSDName: [String: [DiskIOCounters]]) {
        self.samplesByBSDName = samplesByBSDName
    }

    func counters(forBSDName bsdName: String) -> DiskIOCounters? {
        lock.lock()
        defer { lock.unlock() }

        guard var samples = samplesByBSDName[bsdName], samples.isEmpty == false else {
            return nil
        }

        let nextSample = samples.removeFirst()
        samplesByBSDName[bsdName] = samples
        return nextSample
    }
}

private final class StubExternalDeviceDiscovery: ExternalDeviceDiscovering, @unchecked Sendable {
    private let state: State
    private(set) var subscriptionCount = 0
    private(set) var cancellationCount = 0
    private var onUpdate: (@MainActor @Sendable ([ExternalDevice]) -> Void)?

    init(results: [[ExternalDevice]]) {
        self.state = State(results: results)
    }

    func discoverDevices() async -> [ExternalDevice] {
        await state.discoverDevices()
    }

    func observeDevices(
        _ onUpdate: @escaping @MainActor @Sendable ([ExternalDevice]) -> Void
    ) -> any ExternalDeviceDiscoveryObservation {
        subscriptionCount += 1
        self.onUpdate = onUpdate
        return StubExternalDeviceDiscoveryObservation { [weak self] in
            self?.cancellationCount += 1
        }
    }

    @MainActor
    func emit(_ devices: [ExternalDevice]) {
        onUpdate?(devices)
    }

    func resolveNextDiscovery() async {
        await state.resolveNextDiscovery()
    }

    func waitUntilNextDiscoveryIsPending() async {
        await state.waitUntilNextDiscoveryIsPending()
    }

    func invocationCountSnapshot() async -> Int {
        await state.invocationCountSnapshot()
    }

    private actor State {
        private let results: [[ExternalDevice]]
        private var invocationCount = 0
        private var pendingContinuations: [CheckedContinuation<Void, Never>] = []

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

        func waitUntilNextDiscoveryIsPending() async {
            while pendingContinuations.isEmpty {
                await Task.yield()
            }
        }

        func invocationCountSnapshot() -> Int {
            invocationCount
        }
    }
}

private final class StubExternalDeviceDiscoveryObservation: ExternalDeviceDiscoveryObservation, @unchecked Sendable {
    private let onCancel: @Sendable () -> Void
    private let lock = NSLock()
    private var didCancel = false

    init(onCancel: @escaping @Sendable () -> Void) {
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

private actor StubSystemActionPerformer: SystemActionPerforming {
    private var continuation: CheckedContinuation<Void, Error>?
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private(set) var performedActions: [SystemAction] = []
    private var didStart = false

    func perform(_ action: SystemAction) async throws {
        performedActions.append(action)
        didStart = true
        startedContinuation?.resume()
        startedContinuation = nil

        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilStarted() async {
        if didStart {
            return
        }

        await withCheckedContinuation { continuation in
            startedContinuation = continuation
        }
    }

    func finish(with error: Error? = nil) {
        guard let continuation else {
            return
        }

        self.continuation = nil

        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    func performedActionsSnapshot() -> [SystemAction] {
        performedActions
    }
}

private actor RecordingEjectTargetResolver: EjectTargetResolving {
    struct ResolveRequest: Equatable {
        let deviceID: DeviceID
        let displayName: String
        let topologyGeneration: Int
    }

    private let device: ExternalDevice
    private var resolveRequests: [ResolveRequest] = []
    private var revalidationCount = 0

    init(device: ExternalDevice) {
        self.device = device
    }

    func resolve(
        deviceID: DeviceID,
        displayName: String,
        topologyGeneration: Int
    ) async throws -> ResolvedEjectTarget {
        resolveRequests.append(.init(
            deviceID: deviceID,
            displayName: displayName,
            topologyGeneration: topologyGeneration
        ))
        return resolvedTarget(
            deviceID: deviceID,
            displayName: displayName,
            topologyGeneration: topologyGeneration
        )
    }

    func revalidate(_ target: EjectWorkflowTarget) async throws -> ResolvedEjectTarget {
        revalidationCount += 1
        return resolvedTarget(
            deviceID: target.deviceID,
            displayName: target.displayName,
            topologyGeneration: target.topologyGeneration
        )
    }

    func resolveRequestsSnapshot() -> [ResolveRequest] {
        resolveRequests
    }

    func revalidationCountSnapshot() -> Int {
        revalidationCount
    }

    private func resolvedTarget(
        deviceID: DeviceID,
        displayName: String,
        topologyGeneration: Int
    ) -> ResolvedEjectTarget {
        ResolvedEjectTarget(
            target: EjectWorkflowTarget(
                deviceID: deviceID,
                physicalBSDName: device.physicalStoreBSDName,
                mediaRegistryEntryID: 42,
                displayName: displayName,
                topologyGeneration: topologyGeneration
            ),
            scope: OccupancyTargetScope(
                physicalBSDName: device.physicalStoreBSDName,
                deviceNodes: ["/dev/\(device.physicalStoreBSDName)"],
                mountURLs: []
            )
        )
    }
}

private actor DisappearingEjectTargetResolver: EjectTargetResolving {
    private let device: ExternalDevice

    init(device: ExternalDevice) {
        self.device = device
    }

    func resolve(
        deviceID: DeviceID,
        displayName: String,
        topologyGeneration: Int
    ) async throws -> ResolvedEjectTarget {
        ResolvedEjectTarget(
            target: EjectWorkflowTarget(
                deviceID: deviceID,
                physicalBSDName: device.physicalStoreBSDName,
                mediaRegistryEntryID: 42,
                displayName: displayName,
                topologyGeneration: topologyGeneration
            ),
            scope: OccupancyTargetScope(
                physicalBSDName: device.physicalStoreBSDName,
                deviceNodes: ["/dev/\(device.physicalStoreBSDName)"],
                mountURLs: []
            )
        )
    }

    func revalidate(_ target: EjectWorkflowTarget) async throws -> ResolvedEjectTarget {
        throw EjectTargetResolutionError.targetChanged
    }
}

private struct ImmediateDeviceIOQuiescer: DeviceIOQuiescing {
    func acquireBarrier(
        for target: EjectWorkflowTarget,
        timeout: Duration
    ) async throws(DeviceIOQuiescenceError) -> any EjectBarrier {
        ImmediateEjectBarrier()
    }
}

private struct ImmediateEjectBarrier: EjectBarrier {
    func waitUntilReady() async throws {}
    func release() async {}
}

private actor BlockingDiskEjecter: DiskEjecting {
    private let result: Result<Void, EjectFailure>
    private var didStart = false
    private var startContinuations: [CheckedContinuation<Void, Never>] = []
    private var finishContinuation: CheckedContinuation<Void, Never>?

    init(result: Result<Void, EjectFailure> = .success(())) {
        self.result = result
    }

    func performNormalEject(bsdName: String) async -> Result<Void, EjectFailure> {
        didStart = true
        startContinuations.forEach { $0.resume() }
        startContinuations.removeAll()
        await withCheckedContinuation { finishContinuation = $0 }
        return result
    }

    func performConfirmedForceEject(bsdName: String) async -> Result<Void, EjectFailure> {
        .success(())
    }

    func waitUntilNormalEjectStarts() async {
        if didStart { return }
        await withCheckedContinuation { startContinuations.append($0) }
    }

    func finishNormalEject() {
        finishContinuation?.resume()
        finishContinuation = nil
    }
}

private struct EmptyAppOccupancyScanner: AppOccupancyScanning {
    func scan(scope: OccupancyTargetScope, deadline: ContinuousClock.Instant) async -> OccupancyScanResult {
        OccupancyScanResult(holders: [], isComplete: false)
    }
}

private actor AppCompositionIOProbe {
    private var smartReads = 0
    private var occupancyScans = 0
    private var systemProfilerDataTypes: [String] = []
    private var diskUtilArguments: [[String]] = []

    func recordSMARTRead() { smartReads += 1 }
    func recordOccupancyScan() { occupancyScans += 1 }
    func recordSystemProfiler(_ dataType: String) { systemProfilerDataTypes.append(dataType) }
    func recordDiskUtil(_ arguments: [String]) { diskUtilArguments.append(arguments) }
    func smartReadCount() -> Int { smartReads }
    func occupancyScanCount() -> Int { occupancyScans }
    func systemProfilerCallCount() -> Int { systemProfilerDataTypes.count }
    func diskUtilCallCount(for bsdName: String) -> Int {
        diskUtilArguments.filter { $0.contains(bsdName) }.count
    }
}

private final class LockedCapacityProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    func record(_ bsdName: String) {
        lock.lock()
        counts[bsdName, default: 0] += 1
        lock.unlock()
    }

    func count(for bsdName: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[bsdName, default: 0]
    }
}

private struct ImmediateDiskEjecter: DiskEjecting {
    let normalResult: Result<Void, EjectFailure>

    func performNormalEject(bsdName: String) async -> Result<Void, EjectFailure> {
        normalResult
    }

    func performConfirmedForceEject(bsdName: String) async -> Result<Void, EjectFailure> {
        .success(())
    }
}

private struct FixedOccupancyScanner: OccupancyScanning {
    func scan(workflowID: UUID, scope: OccupancyTargetScope) async -> OccupancyScanResult {
        OccupancyScanResult(holders: [], isComplete: true)
    }
}

private final class StubSystemProfilerProvider: SystemProfilerProviding, @unchecked Sendable {
    private let queue = DispatchQueue(label: "StubSystemProfilerProvider")
    private let bootstrapNVMeInfoByBSDName: [String: NVMeInfo]
    private let refreshedNVMeInfoByBSDName: [String: NVMeInfo]
    private let bootstrapPCIInfoBySerialNumber: [String: PCIInfo]
    private let refreshedPCIInfoBySerialNumber: [String: PCIInfo]
    private let bootstrapThunderboltInfo: ThunderboltInfo?
    private let refreshedThunderboltInfo: ThunderboltInfo?
    private var fetchIfNeededCallCountValue = 0
    private var refreshCallCountValue = 0
    private var hasRefreshedValue = false

    var fetchIfNeededCallCount: Int {
        queue.sync { fetchIfNeededCallCountValue }
    }

    var refreshCallCount: Int {
        queue.sync { refreshCallCountValue }
    }

    init(
        bootstrapNVMeInfoByBSDName: [String: NVMeInfo] = [:],
        refreshedNVMeInfoByBSDName: [String: NVMeInfo] = [:],
        bootstrapPCIInfoBySerialNumber: [String: PCIInfo] = [:],
        refreshedPCIInfoBySerialNumber: [String: PCIInfo] = [:],
        bootstrapThunderboltInfo: ThunderboltInfo? = nil,
        refreshedThunderboltInfo: ThunderboltInfo? = nil
    ) {
        self.bootstrapNVMeInfoByBSDName = bootstrapNVMeInfoByBSDName
        self.refreshedNVMeInfoByBSDName = refreshedNVMeInfoByBSDName
        self.bootstrapPCIInfoBySerialNumber = bootstrapPCIInfoBySerialNumber
        self.refreshedPCIInfoBySerialNumber = refreshedPCIInfoBySerialNumber
        self.bootstrapThunderboltInfo = bootstrapThunderboltInfo
        self.refreshedThunderboltInfo = refreshedThunderboltInfo
    }

    func fetchIfNeeded() async {
        queue.sync {
            fetchIfNeededCallCountValue += 1
        }
    }

    func refresh() async {
        queue.sync {
            refreshCallCountValue += 1
            hasRefreshedValue = true
        }
    }

    func nvmeInfo(forBSDName bsdName: String, modelName: String?) -> NVMeInfo? {
        queue.sync {
            currentNVMeInfoByBSDName()[bsdName]
        }
    }

    func pciInfo(forNVMeSerialNumber serial: String?) -> PCIInfo? {
        queue.sync {
            guard let serial else { return nil }
            return currentPCIInfoBySerialNumber()[serial]
        }
    }

    func thunderboltInfo() -> ThunderboltInfo? {
        queue.sync {
            hasRefreshedValue ? refreshedThunderboltInfo : bootstrapThunderboltInfo
        }
    }

    private func currentNVMeInfoByBSDName() -> [String: NVMeInfo] {
        hasRefreshedValue ? refreshedNVMeInfoByBSDName : bootstrapNVMeInfoByBSDName
    }

    private func currentPCIInfoBySerialNumber() -> [String: PCIInfo] {
        hasRefreshedValue ? refreshedPCIInfoBySerialNumber : bootstrapPCIInfoBySerialNumber
    }
}

private final class DelayedSystemProfilerProvider: SystemProfilerProviding, @unchecked Sendable {
    private let fetchDelayNanoseconds: UInt64
    private let refreshDelayNanoseconds: UInt64

    init(fetchDelayNanoseconds: UInt64 = 0, refreshDelayNanoseconds: UInt64 = 0) {
        self.fetchDelayNanoseconds = fetchDelayNanoseconds
        self.refreshDelayNanoseconds = refreshDelayNanoseconds
    }

    func fetchIfNeeded() async {
        if fetchDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: fetchDelayNanoseconds)
        }
    }

    func refresh() async {
        if refreshDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: refreshDelayNanoseconds)
        }
    }

    func nvmeInfo(forBSDName bsdName: String, modelName: String?) -> NVMeInfo? {
        nil
    }

    func pciInfo(forNVMeSerialNumber serial: String?) -> PCIInfo? {
        nil
    }

    func thunderboltInfo() -> ThunderboltInfo? {
        nil
    }
}

private final class DelayedRefreshingStubSystemProfilerProvider: SystemProfilerProviding, @unchecked Sendable {
    private let queue = DispatchQueue(label: "DelayedRefreshingStubSystemProfilerProvider")
    private let refreshDelayNanoseconds: UInt64
    private let refreshedNVMeInfoByBSDName: [String: NVMeInfo]
    private let refreshedPCIInfoBySerialNumber: [String: PCIInfo]
    private let refreshedThunderboltInfo: ThunderboltInfo?
    private var refreshCallCountValue = 0
    private var hasRefreshedValue = false

    init(
        refreshDelayNanoseconds: UInt64,
        refreshedNVMeInfoByBSDName: [String: NVMeInfo] = [:],
        refreshedPCIInfoBySerialNumber: [String: PCIInfo] = [:],
        refreshedThunderboltInfo: ThunderboltInfo? = nil
    ) {
        self.refreshDelayNanoseconds = refreshDelayNanoseconds
        self.refreshedNVMeInfoByBSDName = refreshedNVMeInfoByBSDName
        self.refreshedPCIInfoBySerialNumber = refreshedPCIInfoBySerialNumber
        self.refreshedThunderboltInfo = refreshedThunderboltInfo
    }

    func fetchIfNeeded() async {}

    func refresh() async {
        queue.sync {
            refreshCallCountValue += 1
        }

        if refreshDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: refreshDelayNanoseconds)
        }

        queue.sync {
            hasRefreshedValue = true
        }
    }

    func nvmeInfo(forBSDName bsdName: String, modelName: String?) -> NVMeInfo? {
        queue.sync {
            guard hasRefreshedValue else { return nil }
            return refreshedNVMeInfoByBSDName[bsdName]
        }
    }

    func pciInfo(forNVMeSerialNumber serial: String?) -> PCIInfo? {
        queue.sync {
            guard hasRefreshedValue, let serial else { return nil }
            return refreshedPCIInfoBySerialNumber[serial]
        }
    }

    func thunderboltInfo() -> ThunderboltInfo? {
        queue.sync {
            guard hasRefreshedValue else { return nil }
            return refreshedThunderboltInfo
        }
    }

    func waitUntilRefreshCallCount(is expectedCount: Int) async {
        while queue.sync(execute: { refreshCallCountValue < expectedCount }) {
            await Task.yield()
        }
    }
}

private final class StubDiskUtilAPFSProvider: DiskUtilAPFSProviding, @unchecked Sendable {
    private let queue = DispatchQueue(label: "StubDiskUtilAPFSProvider")
    private let bootstrapContainerInfoByBSDName: [String: APFSContainerInfo]
    private let refreshedContainerInfoByBSDName: [String: APFSContainerInfo]
    private let physicalPartitionsByDiskBSDName: [String: [PhysicalPartitionInfo]]
    private var refreshCallCountValue = 0
    private var hasRefreshedValue = false

    var refreshCallCount: Int {
        queue.sync { refreshCallCountValue }
    }

    init(
        bootstrapContainerInfoByBSDName: [String: APFSContainerInfo] = [:],
        refreshedContainerInfoByBSDName: [String: APFSContainerInfo] = [:],
        physicalPartitionsByDiskBSDName: [String: [PhysicalPartitionInfo]] = [:]
    ) {
        self.bootstrapContainerInfoByBSDName = bootstrapContainerInfoByBSDName
        self.refreshedContainerInfoByBSDName = refreshedContainerInfoByBSDName
        self.physicalPartitionsByDiskBSDName = physicalPartitionsByDiskBSDName
    }

    func refresh() async {
        queue.sync {
            refreshCallCountValue += 1
            hasRefreshedValue = true
        }
    }

    func containerInfo(forContainerBSDName bsdName: String) async -> APFSContainerInfo? {
        queue.sync {
            let source: [String: APFSContainerInfo]
            if hasRefreshedValue, refreshedContainerInfoByBSDName.isEmpty == false {
                source = refreshedContainerInfoByBSDName
            } else {
                source = bootstrapContainerInfoByBSDName
            }
            return source[bsdName]
        }
    }

    func physicalPartitions(forDiskBSDName bsdName: String) async -> [PhysicalPartitionInfo] {
        queue.sync {
            physicalPartitionsByDiskBSDName[bsdName] ?? []
        }
    }
}

private final class DelayedStubDiskUtilAPFSProvider: DiskUtilAPFSProviding, @unchecked Sendable {
    private let refreshDelayNanoseconds: UInt64
    private let queue = DispatchQueue(label: "DelayedStubDiskUtilAPFSProvider")
    private let refreshedContainerInfoByBSDName: [String: APFSContainerInfo]
    private let physicalPartitionsByDiskBSDName: [String: [PhysicalPartitionInfo]]
    private var refreshCallCountValue = 0

    init(
        refreshDelayNanoseconds: UInt64,
        refreshedContainerInfoByBSDName: [String: APFSContainerInfo] = [:],
        physicalPartitionsByDiskBSDName: [String: [PhysicalPartitionInfo]] = [:]
    ) {
        self.refreshDelayNanoseconds = refreshDelayNanoseconds
        self.refreshedContainerInfoByBSDName = refreshedContainerInfoByBSDName
        self.physicalPartitionsByDiskBSDName = physicalPartitionsByDiskBSDName
    }

    func refresh() async {
        if refreshDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: refreshDelayNanoseconds)
        }

        queue.sync {
            refreshCallCountValue += 1
        }
    }

    func containerInfo(forContainerBSDName bsdName: String) async -> APFSContainerInfo? {
        refreshedContainerInfoByBSDName[bsdName]
    }

    func physicalPartitions(forDiskBSDName bsdName: String) async -> [PhysicalPartitionInfo] {
        physicalPartitionsByDiskBSDName[bsdName] ?? []
    }
}

private final class RetryingStubDiskUtilAPFSProvider: DiskUtilAPFSProviding, @unchecked Sendable {
    private let queue = DispatchQueue(label: "RetryingStubDiskUtilAPFSProvider")
    private let refreshResults: [[String: APFSContainerInfo]]
    private let physicalPartitionsByDiskBSDName: [String: [PhysicalPartitionInfo]]
    private var refreshCallCountValue = 0

    var refreshCallCount: Int {
        queue.sync { refreshCallCountValue }
    }

    init(
        refreshResults: [[String: APFSContainerInfo]],
        physicalPartitionsByDiskBSDName: [String: [PhysicalPartitionInfo]] = [:]
    ) {
        self.refreshResults = refreshResults
        self.physicalPartitionsByDiskBSDName = physicalPartitionsByDiskBSDName
    }

    func refresh() async {
        queue.sync {
            refreshCallCountValue += 1
        }
    }

    func containerInfo(forContainerBSDName bsdName: String) async -> APFSContainerInfo? {
        queue.sync {
            guard refreshCallCountValue > 0 else {
                return nil
            }

            let resultIndex = min(refreshCallCountValue - 1, refreshResults.count - 1)
            return refreshResults[resultIndex][bsdName]
        }
    }

    func physicalPartitions(forDiskBSDName bsdName: String) async -> [PhysicalPartitionInfo] {
        physicalPartitionsByDiskBSDName[bsdName] ?? []
    }
}

private actor StubSystemProfilerDataTypeRunner {
    private var snapshots: [[String: Any]]
    private var invocationCountValue = 0

    init(snapshots: [[String: Any]]) {
        self.snapshots = snapshots
    }

    func run(_ dataType: String) async -> Data? {
        invocationCountValue += 1
        let snapshot = snapshots.removeFirst()
        return try? JSONSerialization.data(withJSONObject: snapshot)
    }

    func invocationCount() -> Int {
        invocationCountValue
    }
}

private actor ConcurrentSystemProfilerRunner {
    private var currentConcurrentInvocations = 0
    private var maxConcurrentValue = 0
    private var invocationCountValue = 0

    func run(_ dataType: String) async -> Data? {
        invocationCountValue += 1
        currentConcurrentInvocations += 1
        maxConcurrentValue = max(maxConcurrentValue, currentConcurrentInvocations)
        defer { currentConcurrentInvocations -= 1 }

        try? await Task.sleep(nanoseconds: 50_000_000)

        let payload: [String: Any]
        switch dataType {
        case "SPNVMeDataType":
            payload = [
                "SPNVMeDataType": [
                    [
                        "_name": "Controller",
                        "items": [
                            [
                                "bsd_name": "disk21",
                                "serial_no": "SERIAL"
                            ]
                        ]
                    ]
                ]
            ]
        case "SPPCIDataType":
            payload = [
                "SPPCIDataType": [
                    [
                        "sppci_type": "NVM Controller",
                        "serial_no": "SERIAL",
                        "sppci_slot": "Slot"
                    ]
                ]
            ]
        default:
            payload = [
                "SPThunderboltDataType": [
                    [
                        "items": [
                            [
                                "vendor_name": "Acme",
                                "device_name": "Enclosure"
                            ]
                        ]
                    ]
                ]
            ]
        }

        return try? JSONSerialization.data(withJSONObject: payload)
    }

    func invocationCount() -> Int {
        invocationCountValue
    }

    func maxConcurrentInvocations() -> Int {
        maxConcurrentValue
    }
}

private actor StubDiskUtilCommandRunner {
    private var outputs: [Data]
    private var outputsByArguments: [[String]: [Data]]
    private var apfsListInvocationCountValue = 0
    private var diskInfoInvocationCountValue = 0

    init(outputs: [Data]) {
        self.outputs = outputs
        self.outputsByArguments = [:]
    }

    init(outputsByArguments: [[String]: [Data]]) {
        self.outputs = []
        self.outputsByArguments = outputsByArguments
    }

    func run(_ executable: String, _ arguments: [String]) async -> Data? {
        if arguments == ["info", "-plist", "disk21s2"] {
            return try? PropertyListSerialization.data(
                fromPropertyList: [
                    "DeviceIdentifier": "disk21s2",
                    "Content": "EF57347C-0000-11AA-AA11-00306543ECAC",
                    "APFSContainerReference": "disk21s2",
                    "APFSPhysicalStores": [["APFSPhysicalStore": "disk21s2"]]
                ], format: .xml, options: 0
            )
        }
        if arguments.count == 4, Array(arguments.prefix(3)) == ["apfs", "list", "-plist"] {
            apfsListInvocationCountValue += 1
        }

        if arguments.count == 3,
           arguments[0] == "info",
           arguments[1] == "-plist",
           arguments[2].hasPrefix("/dev/") {
            diskInfoInvocationCountValue += 1
        }

        if var routedOutputs = outputsByArguments[arguments], routedOutputs.isEmpty == false {
            let output = routedOutputs.removeFirst()
            outputsByArguments[arguments] = routedOutputs
            return output
        }

        if arguments.count == 4,
           Array(arguments.prefix(3)) == ["apfs", "list", "-plist"],
           var routedOutputs = outputsByArguments[["apfs", "list", "-plist"]],
           routedOutputs.isEmpty == false {
            let output = routedOutputs.removeFirst()
            outputsByArguments[["apfs", "list", "-plist"]] = routedOutputs
            return output
        }

        if arguments.count == 3,
           arguments[0] == "info",
           arguments[1] == "-plist",
           arguments[2].hasPrefix("/dev/") {
            return nil
        }

        guard outputs.isEmpty == false else {
            return nil
        }

        return outputs.removeFirst()
    }

    func apfsListInvocationCount() -> Int {
        apfsListInvocationCountValue
    }

    func diskInfoInvocationCount() -> Int {
        diskInfoInvocationCountValue
    }
}

private actor OverlappingSystemProfilerRunner {
    private var invocationCountValue = 0
    private var continuations: [Int: CheckedContinuation<Data?, Never>] = [:]

    func run(_ dataType: String) async -> Data? {
        let invocationIndex = invocationCountValue
        invocationCountValue += 1
        return await withCheckedContinuation { continuation in
            continuations[invocationIndex] = continuation
        }
    }

    func waitUntilInvocationCount(is expectedCount: Int) async {
        while invocationCountValue < expectedCount {
            await Task.yield()
        }
    }

    func resumeBatch(
        invocationIndices: [Int],
        serialNumber: String,
        slot: String,
        thunderboltDeviceName: String
    ) {
        for invocationIndex in invocationIndices {
            let continuation = continuations.removeValue(forKey: invocationIndex)
            continuation?.resume(returning: payload(for: invocationIndex, serialNumber: serialNumber, slot: slot, thunderboltDeviceName: thunderboltDeviceName))
        }
    }

    private func payload(
        for invocationIndex: Int,
        serialNumber: String,
        slot: String,
        thunderboltDeviceName: String
    ) -> Data? {
        let dataTypeIndex = invocationIndex % 3
        let payload: [String: Any]
        switch dataTypeIndex {
        case 0:
            payload = [
                "SPThunderboltDataType": [
                    [
                        "items": [
                            [
                                "vendor_name": "Acme",
                                "device_name": thunderboltDeviceName
                            ]
                        ]
                    ]
                ]
            ]
        case 1:
            payload = [
                "SPNVMeDataType": [
                    [
                        "_name": "Controller",
                        "items": [
                            [
                                "bsd_name": "disk21",
                                "serial_no": serialNumber
                            ]
                        ]
                    ]
                ]
            ]
        default:
            payload = [
                "SPPCIDataType": [
                    [
                        "sppci_type": "NVM Controller",
                        "serial_no": serialNumber,
                        "sppci_slot": slot
                    ]
                ]
            ]
        }

        return try? JSONSerialization.data(withJSONObject: payload)
    }
}

private actor OverlappingDiskUtilCommandRunner {
    private var apfsListInvocationCountValue = 0
    private var continuations: [Int: CheckedContinuation<Data?, Never>] = [:]

    func run(_ executable: String, _ arguments: [String]) async -> Data? {
        if arguments == ["info", "-plist", "disk21s2"] {
            return try? PropertyListSerialization.data(
                fromPropertyList: [
                    "DeviceIdentifier": "disk21s2",
                    "Content": "EF57347C-0000-11AA-AA11-00306543ECAC",
                    "APFSContainerReference": "disk21s2",
                    "APFSPhysicalStores": [["APFSPhysicalStore": "disk21s2"]]
                ], format: .xml, options: 0
            )
        }
        guard arguments.count == 4,
              Array(arguments.prefix(3)) == ["apfs", "list", "-plist"] else {
            return nil
        }

        let invocationIndex = apfsListInvocationCountValue
        apfsListInvocationCountValue += 1
        return await withCheckedContinuation { continuation in
            continuations[invocationIndex] = continuation
        }
    }

    func waitUntilAPFSListInvocationCount(is expectedCount: Int) async {
        while apfsListInvocationCountValue < expectedCount {
            await Task.yield()
        }
    }

    func resumeAPFSListInvocation(index: Int, data: Data) {
        let continuation = continuations.removeValue(forKey: index)
        continuation?.resume(returning: data)
    }
}

private enum TestActionError: LocalizedError {
    case failed(message: String)

    var errorDescription: String? {
        switch self {
        case .failed(let message):
            return message
        }
    }
}

@MainActor
private final class MainActorQuitRecorder {
    private(set) var invocationCount = 0

    func recordInvocation() {
        invocationCount += 1
    }
}

private final class StubDiskArbitrationMonitoringSession: DiskArbitrationMonitoringSession, @unchecked Sendable {
    private(set) var activateCallCount = 0
    private(set) var deactivateCallCount = 0

    func activate(
        on queue: DispatchQueue,
        context: UnsafeMutableRawPointer,
        appearedCallback: @escaping DADiskAppearedCallback,
        disappearedCallback: @escaping DADiskDisappearedCallback,
        descriptionChangedCallback: @escaping DADiskDescriptionChangedCallback
    ) {
        _ = queue
        _ = context
        _ = appearedCallback
        _ = disappearedCallback
        _ = descriptionChangedCallback
        activateCallCount += 1
    }

    func deactivate() {
        deactivateCallCount += 1
    }
}
