import MenuBarExtraAccess
import SwiftUI

@main
struct DrivePulseApp: App {
    @StateObject private var controller: DrivePulseAppController
    @StateObject private var settingsWindowActivator = SettingsWindowActivator()

    init() {
        _controller = StateObject(wrappedValue: Self.makeController())
    }

    @MainActor
    static func makeController(
        state: DrivePulseAppState? = nil,
        deviceIOTracker: DeviceIOTracker = DeviceIOTracker(),
        smartService: SMARTServiceClient? = nil,
        diskSampler: any DiskSampling = IOKitDiskSampler(),
        deviceDiscovery: any ExternalDeviceDiscovering = LiveExternalDeviceDiscovery(),
        systemProfilerProvider: (any SystemProfilerProviding)? = nil,
        diskUtilAPFSProvider: (any DiskUtilAPFSProviding)? = nil,
        volumeCapacityRefresher: VolumeCapacityRefresher? = nil,
        ejectTargetResolver: any EjectTargetResolving = LiveEjectTargetResolver(),
        diskEjecter: any DiskEjecting = DiskArbitrationEjectClient(),
        appOccupancyScanner: any AppOccupancyScanning = AppOccupancyScanner()
    ) -> DrivePulseAppController {
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
            resolver: ejectTargetResolver,
            quiescer: DeviceIOQuiescer(tracker: deviceIOTracker),
            ejecter: diskEjecter,
            occupancyScanner: OccupancyScanner(
                appScanner: appOccupancyScanner,
                helperScanner: smartService
            )
        )
        return DrivePulseAppController(
            state: state,
            smartService: smartService,
            diskSampler: diskSampler,
            deviceDiscovery: deviceDiscovery,
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

        MenuBarExtra("DrivePulse", systemImage: "externaldrive") {
            MenuBarRootView(controller: controller, settingsWindowActivator: settingsWindowActivator)
        }
        .menuBarExtraAccess(isPresented: $controller.isMenuBarPanelPresented)
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("Quit DrivePulse") {
                    controller.quit()
                }
                .keyboardShortcut("q", modifiers: .command)
            }
        }

        Settings {
            SettingsView(
                settings: controller.settings,
                launchAtLoginController: controller.launchAtLoginController
            )
            .onDisappear {
                settingsWindowActivator.settingsWindowDidClose()
            }
        }
    }
}
