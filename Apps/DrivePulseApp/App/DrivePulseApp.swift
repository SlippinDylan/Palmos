import MenuBarExtraAccess
import SwiftUI

@main
struct DrivePulseApp: App {
    @StateObject private var controller: DrivePulseAppController
    @StateObject private var settingsWindowActivator = SettingsWindowActivator()

    init() {
        let deviceIOTracker = DeviceIOTracker()
        let smartService = SMARTServiceClient(deviceIOTracker: deviceIOTracker)
        let ejectCoordinator = EjectCoordinator(
            resolver: LiveEjectTargetResolver(),
            quiescer: DeviceIOQuiescer(tracker: deviceIOTracker),
            ejecter: DiskArbitrationEjectClient(),
            occupancyScanner: OccupancyScanner(helperScanner: smartService)
        )
        _controller = StateObject(wrappedValue: DrivePulseAppController(
            smartService: smartService,
            deviceIOTracker: deviceIOTracker,
            ejectCoordinator: ejectCoordinator
        ))
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
