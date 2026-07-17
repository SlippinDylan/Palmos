import Combine
import Foundation

enum SMARTHelperInspection: Equatable, Sendable {
    case notInstalled
    case installed
    case updateRequired
    case failed(String)
}

protocol SMARTHelperInspecting: Sendable {
    func inspectSMARTHelper() async -> SMARTHelperInspection
}

enum SMARTHelperStatus: Equatable {
    case notInstalled
    case checking
    case installed
    case updateRequired
    case installing
    case inspectionFailed(String)
    case installationFailed(String)
}

enum SMARTHelperEvidenceAuthority: Equatable {
    case normal
    case authoritative
}

@MainActor
final class SMARTHelperManager: ObservableObject {
    @Published private(set) var status: SMARTHelperStatus

    private let inspector: any SMARTHelperInspecting
    private let installer: any HelperInstalling
    private var inspectionTask: Task<Void, Never>?
    private var inspectionGeneration = 0

    init(
        inspector: any SMARTHelperInspecting,
        installer: any HelperInstalling,
        initialStatus: SMARTHelperStatus = .notInstalled
    ) {
        self.inspector = inspector
        self.installer = installer
        self.status = initialStatus
    }

    deinit {
        inspectionTask?.cancel()
    }

    func refreshStatus() {
        guard status != .installing else { return }
        inspectionTask?.cancel()
        inspectionGeneration += 1
        let generation = inspectionGeneration
        status = .checking
        inspectionTask = Task { [weak self] in
            guard let self else { return }
            let inspection = await inspector.inspectSMARTHelper()
            guard Task.isCancelled == false,
                  generation == inspectionGeneration else { return }
            status = Self.status(for: inspection)
        }
    }

    func record(
        _ inspection: SMARTHelperInspection,
        authority: SMARTHelperEvidenceAuthority = .normal
    ) {
        guard status != .installing else { return }
        inspectionTask?.cancel()
        inspectionGeneration += 1

        if authority == .authoritative {
            status = Self.status(for: inspection)
            return
        }

        switch inspection {
        case .updateRequired:
            status = .updateRequired
        case .installed:
            guard status != .updateRequired else { return }
            status = .installed
        case .notInstalled:
            switch status {
            case .installed, .updateRequired, .installationFailed:
                return
            case .notInstalled, .checking, .installing, .inspectionFailed:
                status = .notInstalled
            }
        case .failed(let message):
            status = .inspectionFailed(message)
        }
    }

    func installOrUpdate() async -> Bool {
        guard status != .checking, status != .installing else { return false }
        inspectionTask?.cancel()
        inspectionGeneration += 1
        status = .installing

        do {
            try await installer.install()
        } catch {
            status = .installationFailed(error.localizedDescription)
            return false
        }

        // SMJobBless returning successfully is the authoritative completion
        // signal. A handshake can briefly race launchd startup, so defer the
        // compatibility check to the next explicit status refresh.
        status = .installed
        return true
    }

    private static func status(for inspection: SMARTHelperInspection) -> SMARTHelperStatus {
        switch inspection {
        case .notInstalled:
            return .notInstalled
        case .installed:
            return .installed
        case .updateRequired:
            return .updateRequired
        case .failed(let message):
            return .inspectionFailed(message)
        }
    }
}
