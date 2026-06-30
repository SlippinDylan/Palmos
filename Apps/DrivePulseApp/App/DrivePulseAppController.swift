import AppKit
import SwiftUI

import DrivePulseCore

@MainActor
final class DrivePulseAppController: ObservableObject {
    private static let throughputSamplingInterval: TimeInterval = 0.25
    private static let throughputHistoryLimit = 300

    @Published private(set) var state: DrivePulseAppState
    @Published private(set) var actionFeedback: String?
    @Published private(set) var isPerformingSystemAction = false

    let settings: AppSettings
    let launchAtLoginController: LaunchAtLoginController

    private var discoveryObservation: (any ExternalDeviceDiscoveryObservation)?
    private var discoveryLoadTask: Task<Void, Never>?
    private var discoveryWriteGeneration = 0
    private var throughputSamplingTimer: Timer?
    private var lastDiskCountersByDeviceID: [DeviceID: DiskIOCounters] = [:]
    private var sessionMetricsReducersByDeviceID: [DeviceID: SessionMetricsReducer] = [:]
    private let deviceDiscovery: any ExternalDeviceDiscovering
    private let diskSampler: any DiskSampling
    private let smartService: any SMARTServiceProviding
    private let helperInstaller: any HelperInstalling
    private let systemActions: any SystemActionPerforming
    private let systemProfilerProvider: any SystemProfilerProviding
    private let diskUtilAPFSProvider: any DiskUtilAPFSProviding
    private let volumeCapacityRefresher: VolumeCapacityRefresher

    init(
        state: DrivePulseAppState? = nil,
        settings: AppSettings = AppSettings(),
        launchAtLoginController: LaunchAtLoginController = LaunchAtLoginController(),
        systemActions: any SystemActionPerforming = SystemActions(),
        smartService: any SMARTServiceProviding = SMARTServiceClient(),
        helperInstaller: any HelperInstalling = HelperInstaller(),
        diskSampler: any DiskSampling = IOKitDiskSampler(),
        deviceDiscovery: any ExternalDeviceDiscovering = LiveExternalDeviceDiscovery(),
        systemProfilerProvider: any SystemProfilerProviding = LiveSystemProfilerProvider(),
        diskUtilAPFSProvider: any DiskUtilAPFSProviding = LiveDiskUtilAPFSProvider(),
        volumeCapacityRefresher: VolumeCapacityRefresher = VolumeCapacityRefresher()
    ) {
        self.settings = settings
        self.launchAtLoginController = launchAtLoginController
        self.deviceDiscovery = deviceDiscovery
        self.diskSampler = diskSampler
        self.smartService = smartService
        self.helperInstaller = helperInstaller
        self.systemActions = systemActions
        self.systemProfilerProvider = systemProfilerProvider
        self.diskUtilAPFSProvider = diskUtilAPFSProvider
        self.volumeCapacityRefresher = volumeCapacityRefresher
        self.state = state ?? DrivePulseAppState(
            devices: [],
            selectedDeviceID: nil
        )
        volumeCapacityRefresher.onUpdate = { [weak self] updates in
            Task { @MainActor [weak self] in self?.applyCapacityUpdates(updates) }
        }
        self.discoveryObservation = deviceDiscovery.observeDevices { [weak self] devices in
            self?.applyObservedDevices(devices)
        }
        startThroughputSampling()

        if state == nil {
            loadDiscoveredDevices()
        }
    }

    deinit {
        MainActor.assumeIsolated {
            discoveryLoadTask?.cancel()
            discoveryObservation?.cancel()
            throughputSamplingTimer?.invalidate()
            volumeCapacityRefresher.stop()
        }
    }

    func selectDevice(_ id: DeviceID?) {
        let previousSelection = state.selectedDeviceID
        state.selectDevice(id)
        if state.selectedDeviceID != previousSelection {
            state.dismissSMARTPrompts()
        }
    }

    func refreshSelectedDeviceSMART() {
        guard let device = state.selectedDevice else {
            return
        }
        let deviceID = device.id
        guard state.smartDetails(for: deviceID)?.isRefreshing != true else {
            return
        }

        state.setSMARTRefreshing(for: deviceID)
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            let result = await smartService.refreshSMART(for: device)
            applySMARTRefreshResult(result, for: deviceID)
        }
    }

    func performSMARTPrimaryAction() {
        guard let details = state.selectedSMARTDetails else {
            return
        }
        guard details.isRefreshing == false else {
            return
        }

        switch details.primaryAction {
        case .installHelper, .updateHelper:
            state.presentSMARTPrompt(for: details.primaryAction)
        case .refresh:
            refreshSelectedDeviceSMART()
        }
    }

    func dismissSMARTPrompts() {
        state.dismissSMARTPrompts()
    }

    func installSMARTHelper() {
        guard let deviceID = state.presentation.promptDeviceID ?? state.selectedDeviceID,
              let details = state.smartDetails(for: deviceID) else {
            return
        }
        guard details.isRefreshing == false else {
            return
        }
        guard details.primaryAction == .installHelper || details.primaryAction == .updateHelper else {
            return
        }

        state.setSMARTHelperInstalling(for: deviceID)
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            do {
                try await helperInstaller.install()
            } catch {
                state.applySMARTResult(
                    for: deviceID,
                    snapshot: details.snapshot,
                    compatibility: details.compatibility,
                    lastError: error.localizedDescription
                )
                return
            }

            await refreshSelectedDeviceSMARTAfterInstall(for: deviceID)
        }
    }

    var selectedDeviceActions: [SystemAction] {
        SystemAction.actions(for: state.selectedDevice)
    }

    func perform(_ action: SystemAction) {
        guard isPerformingSystemAction == false else {
            return
        }

        isPerformingSystemAction = true
        actionFeedback = nil
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            do {
                try await systemActions.perform(action)
            } catch {
                actionFeedback = error.localizedDescription
            }

            isPerformingSystemAction = false
        }
    }

    func refresh() {
        loadDiscoveredDevices()
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    func sampleDeviceThroughput(at timestamp: Date = Date()) {
        pruneSamplingState()

        for device in state.devices {
            guard let counters = diskSampler.counters(forBSDName: device.physicalStoreBSDName) else {
                continue
            }

            defer {
                lastDiskCountersByDeviceID[device.id] = counters
            }

            guard let previousCounters = lastDiskCountersByDeviceID[device.id] else {
                continue
            }

            let readDelta = max(0, counters.readBytes - previousCounters.readBytes)
            let writeDelta = max(0, counters.writeBytes - previousCounters.writeBytes)
            var reducer = sessionMetricsReducersByDeviceID[device.id]
                ?? SessionMetricsReducer(historyLimit: Self.throughputHistoryLimit)
            reducer.ingest(
                readBytes: readDelta,
                writeBytes: writeDelta,
                at: timestamp
            )
            sessionMetricsReducersByDeviceID[device.id] = reducer
            state.applySessionMetrics(reducer.metrics, for: device.id)
        }
    }

    private func loadDiscoveredDevices() {
        discoveryLoadTask?.cancel()
        discoveryWriteGeneration += 1
        let generation = discoveryWriteGeneration
        let deviceDiscovery = deviceDiscovery
        let systemProfilerProvider = systemProfilerProvider
        let diskUtilAPFSProvider = diskUtilAPFSProvider
        discoveryLoadTask = Task { [weak self] in
            let devices = await deviceDiscovery.discoverDevices()
            guard !Task.isCancelled else { return }
            await systemProfilerProvider.fetchIfNeeded()
            guard !Task.isCancelled, let self else { return }
            let enriched = await self.enrichDevices(devices, diskUtilAPFSProvider: diskUtilAPFSProvider)
            guard !Task.isCancelled else { return }
            self.applyDiscoveredDevices(enriched, generation: generation)
        }
    }

    private func applyObservedDevices(_ devices: [ExternalDevice]) {
        discoveryWriteGeneration += 1
        let generation = discoveryWriteGeneration
        let systemProfilerProvider = systemProfilerProvider
        let diskUtilAPFSProvider = diskUtilAPFSProvider
        Task { [weak self] in
            guard let self else { return }
            await systemProfilerProvider.refresh()
            await diskUtilAPFSProvider.refresh()
            let enriched = await self.enrichDevices(devices, diskUtilAPFSProvider: diskUtilAPFSProvider)
            guard generation == self.discoveryWriteGeneration else { return }
            self.state.replaceDevices(enriched)
            self.pruneSamplingState()
            self.updateCapacityRefresher(from: enriched)
            self.triggerInitialSMARTForNewDevices(enriched)
        }
    }

    private func applyDiscoveredDevices(_ devices: [ExternalDevice], generation: Int) {
        guard generation == discoveryWriteGeneration else {
            return
        }

        state.replaceDevices(devices)
        pruneSamplingState()
        updateCapacityRefresher(from: devices)
        triggerInitialSMARTForNewDevices(devices)
    }

    private func enrichDevices(
        _ devices: [ExternalDevice],
        diskUtilAPFSProvider: any DiskUtilAPFSProviding
    ) async -> [ExternalDevice] {
        var result = devices
        let thunderboltDeviceCount = result.filter { $0.transportName == "Thunderbolt" }.count
        for i in result.indices {
            var device = result[i]
            // NVMe + PCI
            if let nvmeInfo = systemProfilerProvider.nvmeInfo(forBSDName: device.physicalStoreBSDName) {
                device.nvmeInfo = nvmeInfo
                device.pciInfo = systemProfilerProvider.pciInfo(forNVMeSerialNumber: nvmeInfo.serialNumber)
            }
            // Thunderbolt
            if device.transportName == "Thunderbolt", thunderboltDeviceCount == 1 {
                device.thunderboltInfo = systemProfilerProvider.thunderboltInfo()
            }
            // APFS container
            if let containerBSDName = device.apfsContainerBSDName {
                device.apfsContainerDetails = await diskUtilAPFSProvider.containerInfo(
                    forContainerBSDName: containerBSDName
                )
            }
            // Physical partitions (skip if already populated by discovery)
            if device.physicalPartitions.isEmpty {
                device.physicalPartitions = await diskUtilAPFSProvider.physicalPartitions(
                    forDiskBSDName: device.physicalStoreBSDName
                )
            }
            result[i] = device
        }
        return result
    }

    private func applyCapacityUpdates(_ updates: [VolumeCapacityRefresher.CapacityUpdate]) {
        let updatesByBSDName = Dictionary(uniqueKeysWithValues: updates.map { ($0.bsdName, $0) })
        for i in state.devices.indices {
            guard var containerDetails = state.devices[i].apfsContainerDetails else { continue }
            if let containerUpdate = containerDetails.volumes
                .compactMap({ updatesByBSDName[$0.bsdName] })
                .first {
                containerDetails.totalCapacityBytes = containerUpdate.totalBytes
                containerDetails.capacityInUseBytes = containerUpdate.consumedBytes
                containerDetails.capacityNotAllocatedBytes = containerUpdate.availableBytes
            }
            state.devices[i].apfsContainerDetails = containerDetails
        }
    }

    private func updateCapacityRefresher(from devices: [ExternalDevice]) {
        var mountPoints: [String: String] = [:]
        for device in devices {
            guard let volumes = device.apfsContainerDetails?.volumes else { continue }
            for volume in volumes {
                if let mountPoint = volume.mountPoint, !mountPoint.isEmpty {
                    mountPoints[volume.bsdName] = mountPoint
                }
            }
        }
        if mountPoints.isEmpty {
            volumeCapacityRefresher.stop()
        } else {
            volumeCapacityRefresher.start(mountPoints: mountPoints)
        }
    }

    private func refreshSelectedDeviceSMARTAfterInstall(for deviceID: DeviceID) async {
        guard let device = state.device(id: deviceID) else {
            return
        }

        let result = await smartService.refreshSMART(for: device)
        applySMARTRefreshResult(result, for: deviceID)
    }

    private func applySMARTRefreshResult(_ result: SMARTServiceRefreshResult, for deviceID: DeviceID) {
        switch result {
        case let .available(smartData, compatibility):
            state.applySMARTResult(
                for: deviceID,
                snapshot: .available(smartData),
                compatibility: compatibility
            )
        case .unsupported:
            state.applySMARTResult(for: deviceID, snapshot: .unsupported, compatibility: nil)
        case .transportUnsupported:
            state.applySMARTResult(for: deviceID, snapshot: .transportUnsupported, compatibility: nil)
        case .helperNotInstalled:
            state.applySMARTResult(for: deviceID, snapshot: .helperNotInstalled, compatibility: nil)
        case .updateRequired:
            state.applySMARTResult(for: deviceID, snapshot: .updateRequired, compatibility: nil)
        case .permissionRequired:
            state.applySMARTResult(for: deviceID, snapshot: .permissionRequired, compatibility: nil)
        case .deviceUnavailable:
            state.applySMARTResult(for: deviceID, snapshot: .deviceUnavailable, compatibility: nil)
        case let .failed(message):
            state.applySMARTResult(
                for: deviceID,
                snapshot: .failed(message),
                compatibility: nil,
                lastError: message
            )
        }
    }

    private func startThroughputSampling() {
        throughputSamplingTimer?.invalidate()
        throughputSamplingTimer = Timer.scheduledTimer(
            withTimeInterval: Self.throughputSamplingInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sampleDeviceThroughput()
            }
        }
    }

    private func triggerInitialSMARTForNewDevices(_ devices: [ExternalDevice]) {
        for device in devices {
            let deviceID = device.id
            guard state.smartDetails(for: deviceID)?.snapshot == .notRequested else { continue }
            state.setSMARTRefreshing(for: deviceID)
            let capturedDevice = device
            Task { @MainActor [weak self] in
                guard let self else { return }
                let result = await smartService.refreshSMART(for: capturedDevice)
                applySMARTRefreshResult(result, for: deviceID)
            }
        }
    }

    private func pruneSamplingState() {
        let liveDeviceIDs = Set(state.devices.map(\.id))
        lastDiskCountersByDeviceID = lastDiskCountersByDeviceID.filter { liveDeviceIDs.contains($0.key) }
        sessionMetricsReducersByDeviceID = sessionMetricsReducersByDeviceID.filter {
            liveDeviceIDs.contains($0.key)
        }
    }
}
