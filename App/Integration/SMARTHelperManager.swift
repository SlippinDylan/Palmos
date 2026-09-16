import Combine
import Foundation

enum SMARTHelperInspection: Equatable, Sendable {
    case notInstalled
    case installed
    case companionUnavailable
    case monitoringUpdateRequired
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
    case companionUnavailable
    case monitoringUpdateRequired
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
    private var inspectionTask: Task<SMARTHelperInspection, Never>?
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
        inspectionTask = nil
        inspectionGeneration += 1
        let generation = inspectionGeneration
        status = .checking
        let task = Task { [inspector] in
            await inspector.inspectSMARTHelper()
        }
        inspectionTask = task
        Task { [weak self] in
            let inspection = await task.value
            guard let self else { return }
            guard Task.isCancelled == false,
                  generation == inspectionGeneration else { return }
            inspectionTask = nil
            status = Self.status(for: inspection)
        }
    }

    func record(
        _ inspection: SMARTHelperInspection,
        authority: SMARTHelperEvidenceAuthority = .normal
    ) {
        guard status != .installing else { return }
        inspectionTask?.cancel()
        inspectionTask = nil
        inspectionGeneration += 1

        if authority == .authoritative {
            status = Self.status(for: inspection)
            return
        }

        switch inspection {
        case .monitoringUpdateRequired:
            status = .monitoringUpdateRequired
        case .updateRequired:
            status = .updateRequired
        case .installed:
            guard status != .monitoringUpdateRequired,
                  status != .updateRequired else { return }
            status = .installed
        case .companionUnavailable:
            status = .companionUnavailable
        case .notInstalled:
            switch status {
            case .installed, .companionUnavailable, .monitoringUpdateRequired,
                 .updateRequired, .installationFailed:
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
        inspectionTask = nil
        inspectionGeneration += 1
        let generation = inspectionGeneration
        status = .installing

        do {
            try await installer.install()
        } catch {
            status = .installationFailed(error.localizedDescription)
            return false
        }

        status = .checking
        let task = Task { [inspector] in
            await inspector.inspectSMARTHelper()
        }
        inspectionTask = task
        let inspection = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        guard Task.isCancelled == false,
              generation == inspectionGeneration else { return true }
        inspectionTask = nil
        status = Self.status(for: inspection)
        return true
    }

    private static func status(for inspection: SMARTHelperInspection) -> SMARTHelperStatus {
        switch inspection {
        case .notInstalled:
            return .notInstalled
        case .installed:
            return .installed
        case .companionUnavailable:
            return .companionUnavailable
        case .monitoringUpdateRequired:
            return .monitoringUpdateRequired
        case .updateRequired:
            return .updateRequired
        case .failed(let message):
            return .inspectionFailed(message)
        }
    }
}
