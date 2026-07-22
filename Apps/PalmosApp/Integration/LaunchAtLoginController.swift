import AppKit
import ServiceManagement

protocol LaunchAtLoginServicing: Sendable {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister(completionHandler: @escaping @Sendable (Error?) -> Void)
}

private final class LiveLaunchAtLoginService: LaunchAtLoginServicing, @unchecked Sendable {
    let service: SMAppService

    init(service: SMAppService) {
        self.service = service
    }

    var status: SMAppService.Status {
        service.status
    }

    func register() throws {
        try service.register()
    }

    func unregister(completionHandler: @escaping @Sendable (Error?) -> Void) {
        service.unregister(completionHandler: completionHandler)
    }
}

@MainActor
final class LaunchAtLoginController: ObservableObject {
    @Published private(set) var status: SMAppService.Status
    @Published private(set) var isUpdating = false
    @Published private(set) var lastErrorMessage: String?

    private let service: any LaunchAtLoginServicing

    init(service: any LaunchAtLoginServicing = LiveLaunchAtLoginService(service: .mainApp)) {
        self.service = service
        self.status = service.status
    }

    var isEnabled: Bool {
        switch status {
        case .enabled, .requiresApproval:
            return true
        case .notFound, .notRegistered:
            return false
        @unknown default:
            return false
        }
    }

    var needsApproval: Bool {
        status == .requiresApproval
    }

    func setEnabled(_ enabled: Bool) {
        guard isUpdating == false else {
            return
        }

        isUpdating = true
        lastErrorMessage = nil

        if enabled {
            do {
                try service.register()
            } catch {
                lastErrorMessage = error.localizedDescription
            }

            refreshStatus()
            isUpdating = false
            return
        }

        service.unregister { [weak self] error in
            Task { @MainActor in
                self?.lastErrorMessage = error?.localizedDescription
                self?.refreshStatus()
                self?.isUpdating = false
            }
        }
    }

    func refreshStatus() {
        status = service.status
    }

    func openLoginItemsSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else {
            return
        }

        NSWorkspace.shared.open(url)
    }
}
