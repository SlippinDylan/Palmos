import MenuBarExtraAccess
import SwiftUI

@main
struct PalmosApp: App {
    @StateObject private var controller: PalmosAppController
    @StateObject private var settingsWindowActivator: SettingsWindowActivator
    private let applicationUpdater: ApplicationUpdateController

    init() {
        let controller = Self.makeController()
        let applicationUpdater = ApplicationUpdateController()
        _controller = StateObject(wrappedValue: controller)
        _settingsWindowActivator = StateObject(wrappedValue: SettingsWindowActivator(
            settings: controller.settings,
            launchAtLoginController: controller.launchAtLoginController,
            smartHelperManager: controller.smartHelperManager,
            onInstallOrUpdateHelper: { [weak controller] in
                controller?.installSMARTHelper()
            },
            onRefreshHelperStatus: { [weak controller] in
                controller?.refreshSMARTHelperStatus()
            },
            canCheckForUpdates: { [weak applicationUpdater] in
                applicationUpdater?.canCheckForUpdates == true
            },
            onCheckForUpdates: { [weak applicationUpdater] in
                applicationUpdater?.checkForUpdates()
            }
        ))
        self.applicationUpdater = applicationUpdater
    }

    @MainActor
    static func makeController(
        state: PalmosAppState? = nil,
        deviceIOTracker: DeviceIOTracker = DeviceIOTracker(),
        smartService: SMARTServiceClient? = nil,
        diskSampler: any DiskSampling = IOKitDiskSampler(),
        deviceDiscovery: (any ExternalDeviceDiscovering)? = nil,
        systemProfilerProvider: (any SystemProfilerProviding)? = nil,
        diskUtilAPFSProvider: (any DiskUtilAPFSProviding)? = nil,
        volumeCapacityRefresher: VolumeCapacityRefresher? = nil,
        ejectTargetResolver: (any EjectTargetResolving)? = nil,
        diskEjecter: any DiskEjecting = DiskArbitrationEjectClient(),
        appOccupancyScanner: any AppOccupancyScanning = AppOccupancyScanner()
    ) -> PalmosAppController {
        let identityMapper = ExternalDeviceDiscoveryMapper()
        let resolvedDeviceDiscovery = deviceDiscovery ?? LiveExternalDeviceDiscovery(mapper: identityMapper)
        let resolvedEjectTargetResolver = ejectTargetResolver ?? LiveEjectTargetResolver(
            snapshotProvider: LiveEjectTargetSnapshotProvider(mapper: identityMapper)
        )
        let smartService = smartService ?? SMARTServiceClient(deviceIOTracker: deviceIOTracker)
        let systemProfilerProvider = systemProfilerProvider ?? LiveSystemProfilerProvider(
            deviceIOTracker: deviceIOTracker
        )
        let diskUtilAPFSProvider = diskUtilAPFSProvider ?? LiveDiskUtilAPFSProvider(
            deviceIOTracker: deviceIOTracker
        )
        let volumeCapacityRefresher = volumeCapacityRefresher ?? VolumeCapacityRefresher(
            deviceIOTracker: deviceIOTracker
        )
        let ejectCoordinator = EjectCoordinator(
            resolver: resolvedEjectTargetResolver,
            quiescer: DeviceIOQuiescer(tracker: deviceIOTracker),
            ejecter: diskEjecter,
            occupancyScanner: OccupancyScanner(
                appScanner: appOccupancyScanner,
                helperScanner: smartService
            )
        )
        return PalmosAppController(
            state: state,
            smartService: smartService,
            diskSampler: diskSampler,
            deviceDiscovery: resolvedDeviceDiscovery,
            systemProfilerProvider: systemProfilerProvider,
            diskUtilAPFSProvider: diskUtilAPFSProvider,
            volumeCapacityRefresher: volumeCapacityRefresher,
            deviceIOTracker: deviceIOTracker,
            ejectCoordinator: ejectCoordinator
        )
    }

    var body: some Scene {
        MenuBarExtra(
            "Palmos",
            systemImage: MenuBarIcon.systemImageName(
                hasConnectedDevices: controller.panelDevices.isEmpty == false
            )
        ) {
            MenuBarRootView(controller: controller, settingsWindowActivator: settingsWindowActivator)
        }
        .menuBarExtraAccess(isPresented: $controller.isMenuBarPanelPresented)
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings") {
                    settingsWindowActivator.open()
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            CommandGroup(replacing: .appTermination) {
                Button("Quit Palmos") {
                    controller.quit()
                }
                .keyboardShortcut("q", modifiers: .command)
            }
        }
    }
}

enum MenuBarIcon {
    static func systemImageName(hasConnectedDevices: Bool) -> String {
        hasConnectedDevices ? "externaldrive.fill" : "externaldrive"
    }
}
