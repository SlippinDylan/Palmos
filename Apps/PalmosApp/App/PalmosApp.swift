import MenuBarExtraAccess
import SwiftUI

@main
struct PalmosApp: App {
    @StateObject private var controller: PalmosAppController
    @StateObject private var settingsWindowActivator = SettingsWindowActivator()

    init() {
        _controller = StateObject(wrappedValue: Self.makeController())
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
        // Must be declared before `Settings` — it hosts the `openSettings()`
        // call for the accessory-policy menu bar panel. See
        // SettingsWindowActivator.swift for why this is required.
        Window("Settings Bridge", id: SettingsWindowActivator.hiddenHostWindowID) {
            SettingsWindowHostView(activator: settingsWindowActivator)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 1, height: 1)

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
            CommandGroup(replacing: .appTermination) {
                Button("Quit Palmos") {
                    controller.quit()
                }
                .keyboardShortcut("q", modifiers: .command)
            }
        }

        Settings {
            SettingsView(
                settings: controller.settings,
                launchAtLoginController: controller.launchAtLoginController,
                smartHelperManager: controller.smartHelperManager,
                onInstallOrUpdateHelper: controller.installSMARTHelper,
                onRefreshHelperStatus: controller.refreshSMARTHelperStatus
            )
            .background(
                SettingsWindowAccessor(activator: settingsWindowActivator)
                    .frame(width: 0, height: 0)
            )
        }
        .windowResizability(.contentSize)
    }
}

enum MenuBarIcon {
    static func systemImageName(hasConnectedDevices: Bool) -> String {
        hasConnectedDevices ? "externaldrive.fill" : "externaldrive"
    }
}
