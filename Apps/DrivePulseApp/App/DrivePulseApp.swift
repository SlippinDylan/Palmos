import SwiftUI

@main
struct DrivePulseApp: App {
    @StateObject private var controller = DrivePulseAppController()

    var body: some Scene {
        MenuBarExtra("DrivePulse", systemImage: "externaldrive") {
            MenuBarRootView(controller: controller)
        }
        .menuBarExtraStyle(.window)
    }
}
