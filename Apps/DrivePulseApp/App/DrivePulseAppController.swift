import AppKit
import Combine
import SwiftUI

import DrivePulseCore

@MainActor
final class DrivePulseAppController: ObservableObject {
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
    @Published var isMenuBarPanelPresented = true {
        didSet {
            throughputMetricsStore.setPanelPresented(isMenuBarPanelPresented)
        }
    }

    let settings: AppSettings
    let launchAtLoginController: LaunchAtLoginController
    let ejectCoordinator: EjectCoordinator
    let smartHelperManager: SMARTHelperManager
    let throughputMetricsStore: ThroughputMetricsStore

    private var discoveryObservation: (any ExternalDeviceDiscoveryObservation)?
    private var diskEjectIntentObservation: (any ExternalDeviceDiscoveryObservation)?
    private var discoveryLoadTask: Task<Void, Never>?
    private var discoveryObservationDebounceTask: Task<Void, Never>?
    private var observationEnrichmentTask: Task<Void, Never>?
    private var apfsRetryTask: Task<Void, Never>?
    private var systemProfilerEnrichmentTask: Task<Void, Never>?
    private var pendingSystemProfilerRefreshMode: SystemProfilerRefreshMode?
    private var discoveryWriteGeneration = 0
    private var throughputSamplingCoordinator: ThroughputSamplingCoordinator?
    private var actionFeedbackClearTask: Task<Void, Never>?
    private var quitTask: Task<Void, Never>?
    private var smartRefreshTasksByDeviceID: [DeviceID: Task<Void, Never>] = [:]
    private var smartRefreshGenerationsByDeviceID: [DeviceID: Int] = [:]
    private var ejectStateObservation: AnyCancellable?
    private var isSystemActionInFlight = false
    private var isEjectWorkflowActive = false
    private var isEjectActionLocked = false
    private var ejectWorkflowDeviceID: DeviceID?
    @Published private var suppressedEjectDeviceIDs: Set<DeviceID> = []
    private var pendingExternalEjectDeviceIDs: Set<DeviceID> = []
    private var externalEjectIntentExpiryTasks: [DeviceID: Task<Void, Never>] = [:]
    private var throughputSamplingTopology: [DeviceID: String] = [:]
    private let deviceDiscovery: any ExternalDeviceDiscovering
    private let diskSampler: any DiskSampling
    private let smartService: any SMARTServiceProviding
    private let systemActions: any SystemActionPerforming
    private let systemProfilerProvider: any SystemProfilerProviding
    private let diskUtilAPFSProvider: any DiskUtilAPFSProviding
    private let volumeCapacityRefresher: VolumeCapacityRefresher
    private let deviceContextMerger = DeviceContextMerger()
    let deviceIOTracker: DeviceIOTracker
    let deviceIOQuiescer: DeviceIOQuiescer
    private let actionSuccessFeedbackDuration: TimeInterval
    private let ejectSuccessFeedbackDuration: TimeInterval
    private let actionFailureFeedbackDuration: TimeInterval
    private let quitFeedbackDuration: TimeInterval
    private let discoveryObservationDebounce: Duration
    private let externalEjectIntentLifetime: Duration
    private let quitHandler: @MainActor @Sendable () -> Void

    init(
        state: DrivePulseAppState? = nil,
        settings: AppSettings = AppSettings(),
        launchAtLoginController: LaunchAtLoginController = LaunchAtLoginController(),
        systemActions: any SystemActionPerforming = SystemActions(),
        smartService: (any SMARTServiceProviding)? = nil,
        helperInstaller: any HelperInstalling = HelperInstaller(),
        smartHelperManager: SMARTHelperManager? = nil,
        diskSampler: any DiskSampling = IOKitDiskSampler(),
        deviceDiscovery: any ExternalDeviceDiscovering = LiveExternalDeviceDiscovery(),
        systemProfilerProvider: (any SystemProfilerProviding)? = nil,
        diskUtilAPFSProvider: (any DiskUtilAPFSProviding)? = nil,
        volumeCapacityRefresher: VolumeCapacityRefresher? = nil,
        deviceIOTracker: DeviceIOTracker = DeviceIOTracker(),
        ejectCoordinator: EjectCoordinator? = nil,
        actionSuccessFeedbackDuration: TimeInterval = 1.2,
        ejectSuccessFeedbackDuration: TimeInterval = 4.0,
        actionFailureFeedbackDuration: TimeInterval = 2.8,
        quitFeedbackDuration: TimeInterval = 0.75,
        discoveryObservationDebounce: Duration = .milliseconds(75),
        externalEjectIntentLifetime: Duration = .seconds(5),
        quitHandler: @escaping @MainActor @Sendable () -> Void = {
            NSApplication.shared.terminate(nil)
        }
    ) {
        self.settings = settings
        self.launchAtLoginController = launchAtLoginController
        self.throughputMetricsStore = ThroughputMetricsStore()
        self.deviceDiscovery = deviceDiscovery
        self.diskSampler = diskSampler
        self.deviceIOTracker = deviceIOTracker
        self.deviceIOQuiescer = DeviceIOQuiescer(tracker: deviceIOTracker)
        let defaultSMARTService = SMARTServiceClient(deviceIOTracker: deviceIOTracker)
        let resolvedSMARTService = smartService ?? defaultSMARTService
        let resolvedHelperInspector = (resolvedSMARTService as? any SMARTHelperInspecting)
            ?? defaultSMARTService
        let resolvedOccupancyHelper = (resolvedSMARTService as? any HelperOccupancyScanning)
            ?? defaultSMARTService
        self.smartService = resolvedSMARTService
        self.smartHelperManager = smartHelperManager ?? SMARTHelperManager(
            inspector: resolvedHelperInspector,
            installer: helperInstaller
        )
        self.ejectCoordinator = ejectCoordinator ?? EjectCoordinator(
            resolver: LiveEjectTargetResolver(),
            quiescer: DeviceIOQuiescer(tracker: deviceIOTracker),
            ejecter: DiskArbitrationEjectClient(),
            occupancyScanner: OccupancyScanner(helperScanner: resolvedOccupancyHelper)
        )
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
        self.ejectSuccessFeedbackDuration = ejectSuccessFeedbackDuration
        self.actionFailureFeedbackDuration = actionFailureFeedbackDuration
        self.quitFeedbackDuration = quitFeedbackDuration
        self.discoveryObservationDebounce = discoveryObservationDebounce
        self.externalEjectIntentLifetime = externalEjectIntentLifetime
        self.quitHandler = quitHandler
        self.state = state ?? DrivePulseAppState(
            devices: [],
            selectedDeviceID: nil
        )
        self.throughputSamplingTopology = Self.samplingTopology(for: self.state.devices)
        self.volumeCapacityRefresher.onUpdate = { [weak self] updates in
            Task { @MainActor [weak self] in self?.applyCapacityUpdates(updates) }
        }
        self.discoveryObservation = deviceDiscovery.observeDevices { [weak self] devices in
            self?.applyObservedDevices(devices)
        }
        self.diskEjectIntentObservation = deviceDiscovery.observeDiskEjectIntents { [weak self] intent in
            self?.handleDiskEjectIntent(intent)
        }
        self.ejectStateObservation = self.ejectCoordinator.$state.sink { [weak self] state in
            self?.handleEjectStateChange(state)
        }
        reconcileThroughputSamplingLifecycle()

        if state == nil {
            loadDiscoveredDevices()
        }
    }

    isolated deinit {
        discoveryLoadTask?.cancel()
        discoveryObservationDebounceTask?.cancel()
        observationEnrichmentTask?.cancel()
        apfsRetryTask?.cancel()
        systemProfilerEnrichmentTask?.cancel()
        discoveryObservation?.cancel()
        diskEjectIntentObservation?.cancel()
        let coordinator: ThroughputSamplingCoordinator? = throughputSamplingCoordinator
        Task { await coordinator?.stop() }
        actionFeedbackClearTask?.cancel()
        quitTask?.cancel()
        smartRefreshTasksByDeviceID.values.forEach { $0.cancel() }
        externalEjectIntentExpiryTasks.values.forEach { $0.cancel() }
        volumeCapacityRefresher.stop()
    }

    func selectDevice(_ id: DeviceID?) {
        state.selectDevice(id)
    }

    func refreshSelectedDeviceSMART() {
        guard let device = selectedPanelDevice else { return }
        refreshSMART(for: device)
    }

    func installSMARTHelper() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard await smartHelperManager.installOrUpdate() else { return }
            state.devices.forEach {
                refreshSMART(
                    for: $0,
                    supersedingExisting: true,
                    helperEvidenceAuthority: .authoritative
                )
            }
        }
    }

    func refreshSMARTHelperStatus() {
        smartHelperManager.refreshStatus()
    }

    var panelDevices: [ExternalDevice] {
        state.devices.filter { suppressedEjectDeviceIDs.contains($0.id) == false }
    }

    var selectedPanelDevice: ExternalDevice? {
        let visibleDevices = panelDevices
        if let selectedDeviceID = state.selectedDeviceID,
           let selectedDevice = visibleDevices.first(where: { $0.id == selectedDeviceID }) {
            return selectedDevice
        }
        return visibleDevices.first
    }

    var selectedPanelDeviceID: DeviceID? {
        selectedPanelDevice?.id
    }

    var selectedPanelSMARTDetails: SMARTPresentationDetails? {
        guard let selectedPanelDeviceID else { return nil }
        return state.smartDetails(for: selectedPanelDeviceID)
    }

    var selectedFooterActions: [SystemAction] {
        SystemAction.footerActions(for: selectedPanelDevice).filter { action in
            guard action.kind == .eject, let deviceID = selectedPanelDevice?.id else {
                return true
            }
            return suppressedEjectDeviceIDs.contains(deviceID) == false
        }
    }

    func perform(_ action: SystemAction) {
        guard isPerformingSystemAction == false else {
            return
        }

        if case .ejectPhysicalDevice = action.intent {
            guard let device = selectedPanelDevice else { return }
            guard suppressedEjectDeviceIDs.contains(device.id) == false else { return }
            clearActionFeedback()
            if case .awaitingRecovery(let recovery) = ejectCoordinator.state,
               recovery.target.deviceID == device.id {
                ejectCoordinator.retry()
                return
            }
            guard ejectCoordinator.begin(
                deviceID: device.id,
                displayName: device.displayName,
                topologyGeneration: discoveryWriteGeneration
            ) else {
                return
            }
            ejectWorkflowDeviceID = device.id
            return
        }

        if action.dismissesMenuBarPanelOnDispatch {
            isMenuBarPanelPresented = false
        }

        setSystemActionInFlight(true)
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

                setSystemActionInFlight(false)
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

            setSystemActionInFlight(false)
        }
    }

    func cancelEject() {
        ejectCoordinator.cancel()
    }

    func retryEject() {
        ejectCoordinator.retry()
    }

    func requestForceEject() {
        ejectCoordinator.requestForce()
    }

    func confirmForceEject() {
        ejectCoordinator.confirmForce()
    }

    func cancelForceConfirmation() {
        ejectCoordinator.cancelForceConfirmation()
    }

    func refresh() {
        loadDiscoveredDevices(systemProfilerRefreshMode: .refresh)
    }

    func quit() {
        quitHandler()
    }

    private func clearActionFeedback() {
        actionFeedbackClearTask?.cancel()
        actionFeedback = nil
    }

    private func setSystemActionInFlight(_ isInFlight: Bool) {
        isSystemActionInFlight = isInFlight
        updateActionControlState()
    }

    private func setEjectActionLocked(_ isLocked: Bool) {
        isEjectActionLocked = isLocked
        updateActionControlState()
    }

    private func handleEjectStateChange(_ state: EjectWorkflowState) {
        isEjectWorkflowActive = state.isActiveWorkflow
        setEjectActionLocked(state.locksSystemActions)
        switch state {
        case .succeeded(let target):
            suppressDeviceFromPanel(target.deviceID)
            clearMountedVolumes(for: target.deviceID)
            ejectWorkflowDeviceID = nil
            presentActionFeedback(
                EjectLocalization.successFeedback(target: target),
                clearsAfter: ejectSuccessFeedbackDuration
            )
        case .externallyUnmounted(let target):
            clearMountedVolumes(for: target.deviceID)
            ejectWorkflowDeviceID = nil
        case .disappeared(let target):
            suppressDeviceFromPanel(target.deviceID)
            ejectWorkflowDeviceID = nil
            presentActionFeedback(
                EjectLocalization.disappearanceFeedback(target: target),
                clearsAfter: actionFailureFeedbackDuration
            )
        case .idle, .resolutionFailed, .failed:
            ejectWorkflowDeviceID = nil
        case .preparing, .working, .awaitingRecovery, .awaitingForceConfirmation:
            break
        }
    }

    private func updateActionControlState() {
        isPerformingSystemAction = isSystemActionInFlight || isEjectActionLocked
    }

    private func clearMountedVolumes(for deviceID: DeviceID) {
        invalidatePendingDeviceEnrichment()
        state.markDeviceUnmounted(deviceID)
        updateCapacityRefresher(from: state.devices)
        scheduleAPFSEnrichment(
            for: state.devices,
            generation: discoveryWriteGeneration
        )
    }

    private func invalidatePendingDeviceEnrichment() {
        // Enrichment tasks capture pre-eject snapshots. Letting one commit
        // after the terminal state would restore volumes that were just cleared.
        discoveryLoadTask?.cancel()
        discoveryObservationDebounceTask?.cancel()
        discoveryObservationDebounceTask = nil
        observationEnrichmentTask?.cancel()
        apfsRetryTask?.cancel()
        discoveryWriteGeneration += 1
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

    func applyThroughputSamplingResult(_ result: ThroughputSamplingResult) {
        if isEjectWorkflowActive, let ejectWorkflowDeviceID {
            throughputMetricsStore.resetCounterBaseline(for: ejectWorkflowDeviceID)
        }
        let snapshot = throughputSamplingSnapshot()
        throughputMetricsStore.ingest(result, for: snapshot)
    }

    private func throughputSamplingSnapshot() -> ThroughputSamplingSnapshot {
        let pausedDeviceID = isEjectWorkflowActive ? ejectWorkflowDeviceID : nil
        return ThroughputSamplingSnapshot(
            generation: discoveryWriteGeneration,
            devices: state.devices.compactMap {
                guard $0.id != pausedDeviceID else { return nil }
                return ThroughputSamplingDeviceSnapshot(
                    deviceID: $0.id,
                    physicalBSDName: $0.physicalStoreBSDName
                )
            }
        )
    }

    private func loadDiscoveredDevices(
        systemProfilerRefreshMode: SystemProfilerRefreshMode = .fetchIfNeeded
    ) {
        discoveryLoadTask?.cancel()
        observationEnrichmentTask?.cancel()
        apfsRetryTask?.cancel()
        systemProfilerEnrichmentTask?.cancel()
        systemProfilerEnrichmentTask = nil
        pendingSystemProfilerRefreshMode = nil
        discoveryWriteGeneration += 1
        ejectCoordinator.deviceTopologyDidChange(generation: discoveryWriteGeneration)
        let generation = discoveryWriteGeneration
        let deviceDiscovery = deviceDiscovery
        let diskUtilAPFSProvider = diskUtilAPFSProvider
        discoveryLoadTask = Task { [weak self] in
            let devices = await deviceDiscovery.discoverDevices()
            guard !Task.isCancelled, let self else { return }
            let mergedDevices = self.mergeDevicesPreservingKnownContext(devices)
            // Show basic device list immediately; NVMe/TB/APFS enrichment follows
            self.applyDiscoveredDevices(mergedDevices, generation: generation)
            self.scheduleSystemProfilerEnrichment(systemProfilerRefreshMode)
            await diskUtilAPFSProvider.refresh(targets: mergedDevices.map {
                APFSTopologyTarget(
                    physicalBSDName: $0.physicalStoreBSDName,
                    containerBSDName: $0.apfsContainerBSDName
                )
            })
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
        discoveryObservationDebounceTask?.cancel()
        let debounce = discoveryObservationDebounce
        discoveryObservationDebounceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: debounce)
            } catch {
                return
            }
            guard let self, Task.isCancelled == false else { return }
            discoveryObservationDebounceTask = nil
            applyCoalescedObservedDevices(devices)
        }
    }

    private func handleDiskEjectIntent(_ intent: DiskEjectIntent) {
        let matchingDevices = state.devices.filter { device in
            device.physicalStoreBSDName == intent.targetBSDName
                || device.apfsContainerBSDName == intent.targetBSDName
                || device.volumes.contains(where: { $0.bsdName == intent.targetBSDName })
        }
        guard matchingDevices.count == 1, let device = matchingDevices.first else {
            return
        }

        guard isEjectWorkflowActive == false || ejectWorkflowDeviceID != device.id else {
            return
        }

        pendingExternalEjectDeviceIDs.insert(device.id)
        scheduleExternalEjectIntentExpiry(for: device.id)
        if device.volumes.isEmpty {
            suppressDeviceAfterExternalEjectIntent(device.id)
        }
    }

    private func scheduleExternalEjectIntentExpiry(for deviceID: DeviceID) {
        externalEjectIntentExpiryTasks[deviceID]?.cancel()
        let lifetime = externalEjectIntentLifetime
        externalEjectIntentExpiryTasks[deviceID] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: lifetime)
            } catch {
                return
            }
            guard let self, Task.isCancelled == false else { return }
            pendingExternalEjectDeviceIDs.remove(deviceID)
            externalEjectIntentExpiryTasks.removeValue(forKey: deviceID)
        }
    }

    private func suppressDeviceAfterExternalEjectIntent(_ deviceID: DeviceID) {
        pendingExternalEjectDeviceIDs.remove(deviceID)
        externalEjectIntentExpiryTasks.removeValue(forKey: deviceID)?.cancel()
        guard suppressDeviceFromPanel(deviceID) else { return }
        invalidatePendingDeviceEnrichment()
    }

    @discardableResult
    private func suppressDeviceFromPanel(_ deviceID: DeviceID) -> Bool {
        guard suppressedEjectDeviceIDs.insert(deviceID).inserted else { return false }
        if state.selectedDeviceID == deviceID,
           let fallbackDevice = state.devices.first(where: {
               suppressedEjectDeviceIDs.contains($0.id) == false
           }) {
            state.selectDevice(fallbackDevice.id)
        }
        return true
    }

    private func reconcileExternalEjectIntents(with devices: [ExternalDevice]) {
        let liveDeviceIDs = Set(devices.map(\.id))
        let missingPendingDeviceIDs = pendingExternalEjectDeviceIDs.subtracting(liveDeviceIDs)
        for deviceID in missingPendingDeviceIDs {
            pendingExternalEjectDeviceIDs.remove(deviceID)
            externalEjectIntentExpiryTasks.removeValue(forKey: deviceID)?.cancel()
        }

        for device in devices
        where pendingExternalEjectDeviceIDs.contains(device.id) && device.volumes.isEmpty {
            suppressDeviceAfterExternalEjectIntent(device.id)
        }
    }

    private func applyCoalescedObservedDevices(_ devices: [ExternalDevice]) {
        let existingDeviceIDs = Set(state.devices.map(\.id))
        let containsNewDevice = devices.contains { existingDeviceIDs.contains($0.id) == false }
        reconcileExternalEjectIntents(with: devices)
        reconcileEjectSuppression(with: devices)
        observationEnrichmentTask?.cancel()
        apfsRetryTask?.cancel()
        discoveryWriteGeneration += 1
        ejectCoordinator.deviceTopologyDidChange(generation: discoveryWriteGeneration)
        let generation = discoveryWriteGeneration
        let mergedDevices = mergeDevicesPreservingKnownContext(devices)
        // Apply unenriched devices immediately so UI is responsive before system_profiler finishes
        state.replaceDevices(mergedDevices)
        pruneSamplingState()
        updateCapacityRefresher(from: mergedDevices)
        triggerInitialSMARTForNewDevices(mergedDevices)
        scheduleSystemProfilerEnrichment(containsNewDevice ? .refresh : .fetchIfNeeded)
        scheduleAPFSEnrichment(for: mergedDevices, generation: generation)
    }

    private func scheduleAPFSEnrichment(
        for devices: [ExternalDevice],
        generation: Int
    ) {
        observationEnrichmentTask?.cancel()
        guard devices.isEmpty == false else {
            observationEnrichmentTask = nil
            return
        }

        let diskUtilAPFSProvider = diskUtilAPFSProvider
        observationEnrichmentTask = Task { [weak self] in
            guard let self else { return }
            await diskUtilAPFSProvider.refresh(targets: devices.map {
                APFSTopologyTarget(
                    physicalBSDName: $0.physicalStoreBSDName,
                    containerBSDName: $0.apfsContainerBSDName
                )
            })
            guard !Task.isCancelled else { return }
            let apfsEnriched = await self.enrichDevicesWithAPFS(
                devices,
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

        reconcileExternalEjectIntents(with: devices)
        reconcileEjectSuppression(with: devices)
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
                await diskUtilAPFSProvider.refresh(targets: self.state.devices.map {
                    APFSTopologyTarget(
                        physicalBSDName: $0.physicalStoreBSDName,
                        containerBSDName: $0.apfsContainerBSDName
                    )
                })
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
        deviceContextMerger.merge(
            incoming: devices,
            existing: state.devices,
            preservingMountedVolumesFor: isEjectWorkflowActive ? ejectWorkflowDeviceID : nil
        )
    }

    private func enrichDevicesWithAPFS(
        _ devices: [ExternalDevice],
        diskUtilAPFSProvider: any DiskUtilAPFSProviding
    ) async -> [ExternalDevice] {
        await APFSDeviceEnricher().enrich(devices, using: diskUtilAPFSProvider)
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
            for volumeIndex in state.devices[i].volumes.indices {
                let bsdName = state.devices[i].volumes[volumeIndex].bsdName
                guard let update = updatesByBSDName[bsdName] else { continue }
                state.devices[i].volumes[volumeIndex].capacityTotalBytes = update.totalBytes
                state.devices[i].volumes[volumeIndex].capacityConsumedBytes = update.consumedBytes
                state.devices[i].volumes[volumeIndex].capacityAvailableBytes = update.availableBytes
            }
            guard var containerDetails = state.devices[i].apfsContainerDetails else { continue }
            if let containerUpdate = state.devices[i].volumes
                .compactMap({ updatesByBSDName[$0.bsdName] }).first {
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
            let enrichedMountPoints = Dictionary(uniqueKeysWithValues:
                (device.apfsContainerDetails?.volumes ?? []).compactMap { volume in
                    volume.mountPoint.map { (volume.bsdName, $0) }
                }
            )
            for volume in device.volumes {
                let mountPoint = volume.mountPoint ?? enrichedMountPoints[volume.bsdName]
                if let mountPoint, !mountPoint.isEmpty {
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

    private func refreshSMART(
        for device: ExternalDevice,
        supersedingExisting: Bool = false,
        helperEvidenceAuthority: SMARTHelperEvidenceAuthority = .normal
    ) {
        let deviceID = device.id
        if state.smartDetails(for: deviceID)?.isRefreshing == true,
           supersedingExisting == false {
            return
        }

        if supersedingExisting {
            smartRefreshTasksByDeviceID[deviceID]?.cancel()
        }

        let generation = smartRefreshGenerationsByDeviceID[deviceID, default: 0] + 1
        let topologyGeneration = discoveryWriteGeneration
        smartRefreshGenerationsByDeviceID[deviceID] = generation

        state.setSMARTRefreshing(for: deviceID)
        smartRefreshTasksByDeviceID[deviceID] = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await smartService.refreshSMART(
                for: device,
                topologyGeneration: topologyGeneration
            )
            guard Task.isCancelled == false,
                  smartRefreshGenerationsByDeviceID[deviceID] == generation else {
                return
            }
            smartRefreshTasksByDeviceID[deviceID] = nil
            applySMARTRefreshResult(
                result,
                for: deviceID,
                helperEvidenceAuthority: helperEvidenceAuthority
            )
        }
    }

    private func applySMARTRefreshResult(
        _ result: SMARTServiceRefreshResult,
        for deviceID: DeviceID,
        helperEvidenceAuthority: SMARTHelperEvidenceAuthority = .normal
    ) {
        switch result {
        case let .available(smartData, compatibility):
            smartHelperManager.record(.installed, authority: helperEvidenceAuthority)
            state.applySMARTResult(
                for: deviceID,
                snapshot: .available(smartData),
                compatibility: compatibility
            )
        case .unsupported:
            smartHelperManager.record(.installed, authority: helperEvidenceAuthority)
            state.applySMARTResult(for: deviceID, snapshot: .unsupported, compatibility: nil)
        case .transportUnsupported:
            smartHelperManager.record(.installed, authority: helperEvidenceAuthority)
            state.applySMARTResult(for: deviceID, snapshot: .transportUnsupported, compatibility: nil)
        case .companionUnavailable:
            smartHelperManager.record(.companionUnavailable, authority: helperEvidenceAuthority)
            state.applySMARTResult(
                for: deviceID,
                snapshot: .companionUnavailable,
                compatibility: nil
            )
        case .helperNotInstalled:
            smartHelperManager.record(.notInstalled, authority: helperEvidenceAuthority)
            state.applySMARTResult(for: deviceID, snapshot: .helperNotInstalled, compatibility: nil)
        case .updateRequired:
            smartHelperManager.record(.updateRequired, authority: helperEvidenceAuthority)
            state.applySMARTResult(for: deviceID, snapshot: .updateRequired, compatibility: nil)
        case .permissionRequired:
            smartHelperManager.record(.installed, authority: helperEvidenceAuthority)
            state.applySMARTResult(for: deviceID, snapshot: .permissionRequired, compatibility: nil)
        case .deviceUnavailable:
            smartHelperManager.record(.installed, authority: helperEvidenceAuthority)
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

    var isThroughputSamplingActive: Bool {
        throughputSamplingCoordinator != nil
    }

    var throughputSamplingInterval: Duration {
        isMenuBarPanelPresented ? .milliseconds(250) : .seconds(1)
    }

    private func reconcileThroughputSamplingLifecycle() {
        guard state.devices.isEmpty == false else {
            guard let coordinator = throughputSamplingCoordinator else { return }
            throughputSamplingCoordinator = nil
            Task { await coordinator.stop() }
            return
        }

        guard throughputSamplingCoordinator == nil else { return }
        let coordinator = ThroughputSamplingCoordinator(sampler: diskSampler)
        throughputSamplingCoordinator = coordinator
        Task { @MainActor [weak self, coordinator] in
            guard let self, self.throughputSamplingCoordinator === coordinator else { return }
            await coordinator.start(
                snapshotProvider: { @MainActor [weak self] in
                    self?.throughputSamplingSnapshot()
                },
                intervalProvider: { @MainActor [weak self] in
                    self?.throughputSamplingInterval ?? .seconds(1)
                },
                resultHandler: { @MainActor [weak self] result in
                    self?.applyThroughputSamplingResult(result)
                }
            )
            guard self.throughputSamplingCoordinator === coordinator else {
                await coordinator.stop()
                return
            }
        }
    }

    private func triggerInitialSMARTForNewDevices(_ devices: [ExternalDevice]) {
        for device in devices {
            guard state.smartDetails(for: device.id)?.snapshot == .notRequested else { continue }
            refreshSMART(for: device)
        }
    }

    private func reconcileEjectSuppression(with devices: [ExternalDevice]) {
        let remountedDeviceIDs = Set(devices.compactMap { device in
            device.volumes.isEmpty ? nil : device.id
        })
        suppressedEjectDeviceIDs.subtract(remountedDeviceIDs)
    }

    private func pruneSamplingState() {
        let liveDeviceIDs = Set(state.devices.map(\.id))
        let livePhysicalBSDNames = Set(state.devices.map(\.physicalStoreBSDName))
        let currentSamplingTopology = Self.samplingTopology(for: state.devices)
        if currentSamplingTopology != throughputSamplingTopology {
            diskSampler.invalidateCachedServices()
            throughputSamplingTopology = currentSamplingTopology
        }
        suppressedEjectDeviceIDs.formIntersection(liveDeviceIDs)
        let expiredPendingDeviceIDs = pendingExternalEjectDeviceIDs.subtracting(liveDeviceIDs)
        pendingExternalEjectDeviceIDs.formIntersection(liveDeviceIDs)
        expiredPendingDeviceIDs.forEach { deviceID in
            externalEjectIntentExpiryTasks.removeValue(forKey: deviceID)?.cancel()
        }
        let topologyGeneration = discoveryWriteGeneration
        Task {
            await deviceIOTracker.pruneSMARTSafetyScopes(
                liveDeviceIDs: liveDeviceIDs,
                livePhysicalBSDNames: livePhysicalBSDNames,
                topologyGeneration: topologyGeneration
            )
        }
        let removedSMARTDeviceIDs = Set(smartRefreshTasksByDeviceID.keys).subtracting(liveDeviceIDs)
        removedSMARTDeviceIDs.forEach { deviceID in
            smartRefreshTasksByDeviceID.removeValue(forKey: deviceID)?.cancel()
            smartRefreshGenerationsByDeviceID.removeValue(forKey: deviceID)
        }
        throughputMetricsStore.prune(liveDeviceIDs: liveDeviceIDs)
        reconcileThroughputSamplingLifecycle()
    }

    private static func samplingTopology(for devices: [ExternalDevice]) -> [DeviceID: String] {
        Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0.physicalStoreBSDName) })
    }
}

private extension EjectWorkflowState {
    var isActiveWorkflow: Bool {
        switch self {
        case .preparing, .working, .awaitingRecovery, .awaitingForceConfirmation:
            return true
        case .idle, .succeeded, .externallyUnmounted, .disappeared, .resolutionFailed, .failed:
            return false
        }
    }

    var locksSystemActions: Bool {
        switch self {
        case .preparing, .working, .awaitingForceConfirmation:
            return true
        case .idle, .awaitingRecovery, .succeeded, .externallyUnmounted, .disappeared,
             .resolutionFailed, .failed:
            return false
        }
    }
}
