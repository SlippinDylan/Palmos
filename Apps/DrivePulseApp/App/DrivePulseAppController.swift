import AppKit
import SwiftUI

import DrivePulseCore

@MainActor
final class DrivePulseAppController: ObservableObject {
    private static let throughputSamplingInterval: TimeInterval = 0.25
    private static let throughputHistoryLimit = 300
    private static let apfsEnrichmentRetryDelays: [TimeInterval] = [0.25, 0.75, 1.5]
    private static let actionSuccessFeedbackDuration: TimeInterval = 1.2
    private static let actionFailureFeedbackDuration: TimeInterval = 2.8
    private static let quitFeedbackDuration: TimeInterval = 0.75

    private enum SystemProfilerRefreshMode {
        case fetchIfNeeded
        case refresh

        func merged(with other: SystemProfilerRefreshMode) -> SystemProfilerRefreshMode {
            if self == .refresh || other == .refresh {
                return .refresh
            }
            return .fetchIfNeeded
        }
    }

    @Published private(set) var state: DrivePulseAppState
    @Published private(set) var actionFeedback: String?
    @Published private(set) var isPerformingSystemAction = false
    /// Bound to `menuBarExtraAccess(isPresented:)` so the panel can be
    /// dismissed programmatically (e.g. after opening Finder or Disk
    /// Utility) without desyncing the status item's highlight state — the
    /// way a raw `NSApp.keyWindow?.close()` call does.
    @Published var isMenuBarPanelPresented = true

    let settings: AppSettings
    let launchAtLoginController: LaunchAtLoginController

    private var discoveryObservation: (any ExternalDeviceDiscoveryObservation)?
    private var discoveryLoadTask: Task<Void, Never>?
    private var observationEnrichmentTask: Task<Void, Never>?
    private var apfsRetryTask: Task<Void, Never>?
    private var systemProfilerEnrichmentTask: Task<Void, Never>?
    private var pendingSystemProfilerRefreshMode: SystemProfilerRefreshMode?
    private var discoveryWriteGeneration = 0
    private var throughputSamplingTimer: Timer?
    private var actionFeedbackClearTask: Task<Void, Never>?
    private var quitTask: Task<Void, Never>?
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
    let deviceIOTracker: DeviceIOTracker
    let deviceIOQuiescer: DeviceIOQuiescer
    private let actionSuccessFeedbackDuration: TimeInterval
    private let actionFailureFeedbackDuration: TimeInterval
    private let quitFeedbackDuration: TimeInterval
    private let quitHandler: @MainActor @Sendable () -> Void

    init(
        state: DrivePulseAppState? = nil,
        settings: AppSettings = AppSettings(),
        launchAtLoginController: LaunchAtLoginController = LaunchAtLoginController(),
        systemActions: any SystemActionPerforming = SystemActions(),
        smartService: (any SMARTServiceProviding)? = nil,
        helperInstaller: any HelperInstalling = HelperInstaller(),
        diskSampler: any DiskSampling = IOKitDiskSampler(),
        deviceDiscovery: any ExternalDeviceDiscovering = LiveExternalDeviceDiscovery(),
        systemProfilerProvider: (any SystemProfilerProviding)? = nil,
        diskUtilAPFSProvider: (any DiskUtilAPFSProviding)? = nil,
        volumeCapacityRefresher: VolumeCapacityRefresher? = nil,
        deviceIOTracker: DeviceIOTracker = DeviceIOTracker(),
        actionSuccessFeedbackDuration: TimeInterval = 1.2,
        actionFailureFeedbackDuration: TimeInterval = 2.8,
        quitFeedbackDuration: TimeInterval = 0.75,
        quitHandler: @escaping @MainActor @Sendable () -> Void = {
            NSApplication.shared.terminate(nil)
        }
    ) {
        self.settings = settings
        self.launchAtLoginController = launchAtLoginController
        self.deviceDiscovery = deviceDiscovery
        self.diskSampler = diskSampler
        self.deviceIOTracker = deviceIOTracker
        self.deviceIOQuiescer = DeviceIOQuiescer(tracker: deviceIOTracker)
        self.smartService = smartService ?? SMARTServiceClient(deviceIOTracker: deviceIOTracker)
        self.helperInstaller = helperInstaller
        self.systemActions = systemActions
        self.systemProfilerProvider = systemProfilerProvider ?? LiveSystemProfilerProvider(
            deviceIOTracker: deviceIOTracker
        )
        self.diskUtilAPFSProvider = diskUtilAPFSProvider ?? LiveDiskUtilAPFSProvider(
            deviceIOTracker: deviceIOTracker
        )
        self.volumeCapacityRefresher = volumeCapacityRefresher ?? VolumeCapacityRefresher(
            deviceIOTracker: deviceIOTracker
        )
        self.actionSuccessFeedbackDuration = actionSuccessFeedbackDuration
        self.actionFailureFeedbackDuration = actionFailureFeedbackDuration
        self.quitFeedbackDuration = quitFeedbackDuration
        self.quitHandler = quitHandler
        self.state = state ?? DrivePulseAppState(
            devices: [],
            selectedDeviceID: nil
        )
        self.volumeCapacityRefresher.onUpdate = { [weak self] updates in
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
            observationEnrichmentTask?.cancel()
            apfsRetryTask?.cancel()
            systemProfilerEnrichmentTask?.cancel()
            discoveryObservation?.cancel()
            throughputSamplingTimer?.invalidate()
            actionFeedbackClearTask?.cancel()
            quitTask?.cancel()
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

    var selectedFooterActions: [SystemAction] {
        SystemAction.footerActions(for: state.selectedDevice)
    }

    func perform(_ action: SystemAction) {
        guard isPerformingSystemAction == false else {
            return
        }

        if action.dismissesMenuBarPanelOnDispatch {
            isMenuBarPanelPresented = false
        }

        isPerformingSystemAction = true
        clearActionFeedback()

        if action.intent == .quit {
            presentActionFeedback(
                action.successFeedbackMessage,
                clearsAfter: quitFeedbackDuration
            )
            quitTask?.cancel()
            quitTask = Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                try? await Task.sleep(nanoseconds: Self.nanoseconds(for: quitFeedbackDuration))
                guard Task.isCancelled == false else {
                    return
                }

                isPerformingSystemAction = false
                quitHandler()
            }
            return
        }

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            do {
                try await systemActions.perform(action)
                presentActionFeedback(
                    action.successFeedbackMessage,
                    clearsAfter: actionSuccessFeedbackDuration
                )
            } catch {
                presentActionFeedback(
                    error.localizedDescription,
                    clearsAfter: actionFailureFeedbackDuration
                )
            }

            isPerformingSystemAction = false
        }
    }

    func refresh() {
        loadDiscoveredDevices()
    }

    func quit() {
        quitHandler()
    }

    private func clearActionFeedback() {
        actionFeedbackClearTask?.cancel()
        actionFeedback = nil
    }

    private func presentActionFeedback(_ message: String, clearsAfter duration: TimeInterval) {
        actionFeedbackClearTask?.cancel()
        actionFeedback = message
        actionFeedbackClearTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            try? await Task.sleep(nanoseconds: Self.nanoseconds(for: duration))
            guard Task.isCancelled == false else {
                return
            }

            if actionFeedback == message {
                actionFeedback = nil
            }
        }
    }

    private static func nanoseconds(for duration: TimeInterval) -> UInt64 {
        UInt64((duration * 1_000_000_000).rounded())
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
        observationEnrichmentTask?.cancel()
        apfsRetryTask?.cancel()
        systemProfilerEnrichmentTask?.cancel()
        systemProfilerEnrichmentTask = nil
        pendingSystemProfilerRefreshMode = nil
        discoveryWriteGeneration += 1
        let generation = discoveryWriteGeneration
        let deviceDiscovery = deviceDiscovery
        let diskUtilAPFSProvider = diskUtilAPFSProvider
        discoveryLoadTask = Task { [weak self] in
            let devices = await deviceDiscovery.discoverDevices()
            guard !Task.isCancelled, let self else { return }
            let mergedDevices = self.mergeDevicesPreservingKnownContext(devices)
            // Show basic device list immediately; NVMe/TB/APFS enrichment follows
            self.applyDiscoveredDevices(mergedDevices, generation: generation)
            self.scheduleSystemProfilerEnrichment(.fetchIfNeeded)
            await diskUtilAPFSProvider.refresh(
                physicalBSDNames: Set(mergedDevices.map(\.physicalStoreBSDName))
            )
            guard !Task.isCancelled else { return }
            let apfsEnriched = await self.enrichDevicesWithAPFS(
                mergedDevices,
                diskUtilAPFSProvider: diskUtilAPFSProvider
            )
            guard !Task.isCancelled else { return }
            let mergedAPFSEnriched = self.mergeDevicesPreservingKnownContext(apfsEnriched)
            self.applyDiscoveredDevices(mergedAPFSEnriched, generation: generation)
            self.scheduleAPFSRetryIfNeeded(
                generation: generation,
                diskUtilAPFSProvider: diskUtilAPFSProvider
            )
        }
    }

    private func applyObservedDevices(_ devices: [ExternalDevice]) {
        observationEnrichmentTask?.cancel()
        apfsRetryTask?.cancel()
        discoveryWriteGeneration += 1
        let generation = discoveryWriteGeneration
        let diskUtilAPFSProvider = diskUtilAPFSProvider
        let mergedDevices = mergeDevicesPreservingKnownContext(devices)
        // Apply unenriched devices immediately so UI is responsive before system_profiler finishes
        state.replaceDevices(mergedDevices)
        pruneSamplingState()
        updateCapacityRefresher(from: mergedDevices)
        triggerInitialSMARTForNewDevices(mergedDevices)
        scheduleSystemProfilerEnrichment(.refresh)
        observationEnrichmentTask = Task { [weak self] in
            guard let self else { return }
            await diskUtilAPFSProvider.refresh(
                physicalBSDNames: Set(mergedDevices.map(\.physicalStoreBSDName))
            )
            guard !Task.isCancelled else { return }
            let apfsEnriched = await self.enrichDevicesWithAPFS(
                mergedDevices,
                diskUtilAPFSProvider: diskUtilAPFSProvider
            )
            guard generation == self.discoveryWriteGeneration, !Task.isCancelled else { return }
            let mergedAPFSEnriched = self.mergeDevicesPreservingKnownContext(apfsEnriched)
            self.state.replaceDevices(mergedAPFSEnriched)
            self.pruneSamplingState()
            self.updateCapacityRefresher(from: mergedAPFSEnriched)
            self.scheduleAPFSRetryIfNeeded(
                generation: generation,
                diskUtilAPFSProvider: diskUtilAPFSProvider
            )
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

    private func scheduleAPFSRetryIfNeeded(
        generation: Int,
        diskUtilAPFSProvider: any DiskUtilAPFSProviding
    ) {
        guard generation == discoveryWriteGeneration else {
            return
        }

        guard needsAPFSEnrichmentRetry(state.devices) else {
            apfsRetryTask?.cancel()
            apfsRetryTask = nil
            return
        }

        apfsRetryTask?.cancel()
        apfsRetryTask = Task { [weak self] in
            guard let self else { return }

            for delay in Self.apfsEnrichmentRetryDelays {
                if delay > 0 {
                    let delayNanoseconds = UInt64(delay * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: delayNanoseconds)
                }

                guard generation == self.discoveryWriteGeneration, !Task.isCancelled else { return }
                await diskUtilAPFSProvider.refresh(
                    physicalBSDNames: Set(self.state.devices.map(\.physicalStoreBSDName))
                )
                guard generation == self.discoveryWriteGeneration, !Task.isCancelled else { return }

                let enrichedDevices = await self.enrichDevicesWithAPFS(
                    self.state.devices,
                    diskUtilAPFSProvider: diskUtilAPFSProvider
                )
                guard generation == self.discoveryWriteGeneration, !Task.isCancelled else { return }

                let mergedEnrichedDevices = self.mergeDevicesPreservingKnownContext(enrichedDevices)
                self.applyDiscoveredDevices(mergedEnrichedDevices, generation: generation)
                if self.needsAPFSEnrichmentRetry(mergedEnrichedDevices) == false {
                    self.apfsRetryTask = nil
                    return
                }
            }

            self.apfsRetryTask = nil
        }
    }

    private func scheduleSystemProfilerEnrichment(_ mode: SystemProfilerRefreshMode) {
        if let existingPendingMode = pendingSystemProfilerRefreshMode {
            pendingSystemProfilerRefreshMode = existingPendingMode.merged(with: mode)
        } else {
            pendingSystemProfilerRefreshMode = mode
        }

        guard systemProfilerEnrichmentTask == nil else {
            return
        }

        let systemProfilerProvider = systemProfilerProvider
        systemProfilerEnrichmentTask = Task { @MainActor [weak self] in
            guard let self else { return }

            defer {
                self.systemProfilerEnrichmentTask = nil
            }

            while !Task.isCancelled {
                guard let mode = self.pendingSystemProfilerRefreshMode else {
                    return
                }
                self.pendingSystemProfilerRefreshMode = nil

                switch mode {
                case .fetchIfNeeded:
                    await systemProfilerProvider.fetchIfNeeded()
                case .refresh:
                    await systemProfilerProvider.refresh()
                }

                guard !Task.isCancelled else { return }
                let enrichedDevices = self.enrichDevicesWithSystemProfiler(self.state.devices)
                self.state.replaceDevices(enrichedDevices)
                self.pruneSamplingState()
                self.updateCapacityRefresher(from: enrichedDevices)
            }
        }
    }

    private func needsAPFSEnrichmentRetry(_ devices: [ExternalDevice]) -> Bool {
        devices.contains { device in
            guard device.apfsContainerBSDName != nil else {
                return false
            }
            guard let containerDetails = device.apfsContainerDetails else {
                return true
            }
            return containerDetails.volumes.contains(where: { $0.isVolumeDetailComplete == false })
        }
    }

    private func mergeDevicesPreservingKnownContext(_ devices: [ExternalDevice]) -> [ExternalDevice] {
        let existingDevicesByID = Dictionary(uniqueKeysWithValues: state.devices.map { ($0.id, $0) })
        return devices.map { incoming in
            guard let existing = existingDevicesByID[incoming.id] else {
                return incoming
            }
            return mergeKnownContext(from: existing, into: incoming)
        }
    }

    private func mergeKnownContext(from existing: ExternalDevice, into incoming: ExternalDevice) -> ExternalDevice {
        var merged = incoming

        if isGenericDisplayName(merged.displayName, for: merged.id) {
            merged.displayName = existing.displayName
        }
        if shouldPrefer(existing.transportName, over: merged.transportName) {
            merged.transportName = existing.transportName
        }
        if merged.capacityBytes == nil {
            merged.capacityBytes = existing.capacityBytes
        }
        if merged.apfsContainerBSDName == nil {
            merged.apfsContainerBSDName = existing.apfsContainerBSDName
        }
        if merged.volumes.isEmpty {
            merged.volumes = existing.volumes
        }
        if merged.nvmeInfo == nil {
            merged.nvmeInfo = existing.nvmeInfo
        }
        if merged.thunderboltInfo == nil {
            merged.thunderboltInfo = existing.thunderboltInfo
        }
        if merged.pciInfo == nil {
            merged.pciInfo = existing.pciInfo
        }
        if merged.apfsContainerDetails == nil {
            merged.apfsContainerDetails = existing.apfsContainerDetails
        }
        if merged.physicalPartitions.isEmpty {
            merged.physicalPartitions = existing.physicalPartitions
        }

        return merged
    }

    private func isGenericDisplayName(_ displayName: String, for deviceID: DeviceID) -> Bool {
        displayName == deviceID.rawValue.uppercased()
    }

    private func shouldPrefer(_ existingTransportName: String, over incomingTransportName: String) -> Bool {
        transportQualityScore(existingTransportName) > transportQualityScore(incomingTransportName)
    }

    private func transportQualityScore(_ transportName: String) -> Int {
        let normalizedTransport = transportName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch normalizedTransport {
        case "thunderbolt":
            return 40
        case "usb4":
            return 30
        case "usb", "usb-c", "sd":
            return 20
        case "external", "":
            return 0
        default:
            if normalizedTransport.hasPrefix("io")
                || normalizedTransport.contains("controller")
                || normalizedTransport.contains("storage") {
                return 0
            }
            return 10
        }
    }

    private func enrichDevicesWithAPFS(
        _ devices: [ExternalDevice],
        diskUtilAPFSProvider: any DiskUtilAPFSProviding
    ) async -> [ExternalDevice] {
        var result = devices
        for i in result.indices {
            var device = result[i]
            // APFS container
            if let containerBSDName = device.apfsContainerBSDName {
                let containerDetails = await diskUtilAPFSProvider.containerInfo(
                    forContainerBSDName: containerBSDName
                )
                device.apfsContainerDetails = mergeMountedVolumeMetadata(
                    into: containerDetails,
                    mountedVolumes: device.volumes
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

    private func enrichDevicesWithSystemProfiler(_ devices: [ExternalDevice]) -> [ExternalDevice] {
        var result = devices
        for i in result.indices {
            var device = result[i]
            if let nvmeInfo = systemProfilerProvider.nvmeInfo(
                forBSDName: device.physicalStoreBSDName,
                modelName: device.displayName
            ) {
                device.nvmeInfo = nvmeInfo
                device.pciInfo = systemProfilerProvider.pciInfo(forNVMeSerialNumber: nvmeInfo.serialNumber)
                if isThunderboltPCISlot(device.pciInfo?.slot) {
                    device.transportName = "Thunderbolt"
                }
            }
            result[i] = device
        }

        let thunderboltDeviceCount = result.filter { $0.transportName == "Thunderbolt" }.count
        if thunderboltDeviceCount == 1,
           let thunderboltInfo = systemProfilerProvider.thunderboltInfo(),
           let thunderboltDeviceIndex = result.firstIndex(where: { $0.transportName == "Thunderbolt" }) {
            result[thunderboltDeviceIndex].thunderboltInfo = thunderboltInfo
        }

        return result
    }

    private func isThunderboltPCISlot(_ slot: String?) -> Bool {
        guard let slot else {
            return false
        }
        return slot.localizedCaseInsensitiveContains("Thunderbolt@")
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
        var physicalBSDNames: [String: String] = [:]
        for device in devices {
            guard let volumes = device.apfsContainerDetails?.volumes else { continue }
            for volume in volumes {
                if let mountPoint = volume.mountPoint, !mountPoint.isEmpty {
                    mountPoints[volume.bsdName] = mountPoint
                    physicalBSDNames[volume.bsdName] = device.physicalStoreBSDName
                }
            }
        }
        if mountPoints.isEmpty {
            volumeCapacityRefresher.stop()
        } else {
            volumeCapacityRefresher.start(
                mountPoints: mountPoints,
                physicalBSDNames: physicalBSDNames
            )
        }
    }

    private func mergeMountedVolumeMetadata(
        into containerDetails: APFSContainerInfo?,
        mountedVolumes: [MountedVolume]
    ) -> APFSContainerInfo? {
        guard var containerDetails else {
            return nil
        }

        let mountPointPairs: [(String, String)] = mountedVolumes.compactMap { volume in
                guard let mountPoint = volume.mountPoint, mountPoint.isEmpty == false else {
                    return nil
                }
                return (volume.bsdName, mountPoint)
            }
        let mountPointsByBSDName = Dictionary(uniqueKeysWithValues: mountPointPairs)

        guard mountPointsByBSDName.isEmpty == false else {
            return containerDetails
        }

        for index in containerDetails.volumes.indices {
            let bsdName = containerDetails.volumes[index].bsdName
            if containerDetails.volumes[index].mountPoint == nil {
                containerDetails.volumes[index].mountPoint = mountPointsByBSDName[bsdName]
            }
        }

        return containerDetails
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
