import AppKit
import ServiceManagement

@MainActor
final class LaunchAtLoginController: ObservableObject {
    @Published private(set) var status: SMAppService.Status
    @Published private(set) var isUpdating = false
    @Published private(set) var lastErrorMessage: String?

    private let service: SMAppService

    init(service: SMAppService = .mainApp) {
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
        isUpdating = true
        lastErrorMessage = nil

        if enabled {
            do {
                try service.register()
            } catch {
                lastErrorMessage = error.localizedDescription
            }

            refresh()
            isUpdating = false
            return
        }

        service.unregister { [weak self] error in
            Task { @MainActor in
                self?.lastErrorMessage = error?.localizedDescription
                self?.refresh()
                self?.isUpdating = false
            }
        }
    }

    func openLoginItemsSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else {
            return
        }

        NSWorkspace.shared.open(url)
    }

    private func refresh() {
        status = service.status
    }
}
