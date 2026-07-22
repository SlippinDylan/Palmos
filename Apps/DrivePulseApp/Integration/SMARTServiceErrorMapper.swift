import Foundation

import DrivePulseCore

struct SMARTServiceErrorMapper: Sendable {
    private let isHelperInstalled: @Sendable () -> Bool

    init(isHelperInstalled: @escaping @Sendable () -> Bool) {
        self.isHelperInstalled = isHelperInstalled
    }

    func mapRefreshError(_ error: Error) -> SMARTServiceRefreshResult {
        let nsError = error as NSError
        let description = nsError.localizedDescription
        let normalizedDescription = description.lowercased()

        if nsError.domain == NSCocoaErrorDomain && nsError.code == 4099 {
            return isHelperInstalled() ? .failed(description) : .helperNotInstalled
        }

        if let connectionError = error as? SMARTServiceClientError,
           connectionError == .connectionInterrupted ||
           connectionError == .connectionInvalidated {
            return isHelperInstalled() ? .failed(description) : .helperNotInstalled
        }

        if nsError.domain == NSPOSIXErrorDomain &&
            (nsError.code == Int(EPERM) || nsError.code == Int(EACCES)) {
            return .permissionRequired
        }

        if normalizedDescription.contains("unsupported smart device name") {
            return .deviceUnavailable
        }

        if normalizedDescription.contains("smart support is unavailable") ||
            normalizedDescription.contains("smart unavailable") {
            return .unsupported
        }

        if normalizedDescription.contains("smartctl companion") &&
            (normalizedDescription.contains("not installed") ||
                normalizedDescription.contains("unavailable")) {
            return .companionUnavailable
        }

        if normalizedDescription.contains("using transport hint") &&
            (normalizedDescription.contains("unknown usb bridge") ||
                normalizedDescription.contains("unknown bridge") ||
                normalizedDescription.contains("specify device type")) {
            return .transportUnsupported
        }

        return .failed(description)
    }

    func mapCompletionError(_ error: SMARTReadCompletionError) -> SMARTServiceRefreshResult {
        switch error.code {
        case .executableUnavailable:
            return .companionUnavailable
        case .invalidRequest:
            return .deviceUnavailable
        case .commandFailed:
            return mapRefreshError(NSError(
                domain: "com.drivepulse.smartservice",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: error.message]
            ))
        case .timedOut, .cancelled, .busy, .duplicateRequest, .outputTooLarge, .internalFailure:
            return .failed(error.message)
        }
    }
}

enum SMARTServiceClientError: LocalizedError, Equatable {
    case invalidRemoteProxy
    case missingReplyData
    case connectionInterrupted
    case connectionInvalidated
    case unsupportedOccupancyEndpoint
    case mismatchedOccupancyWorkflow
    case mismatchedSMARTRequest
    case unsupportedCompanionInstallationEndpoint
    case companionInstallationUnconfirmed

    var errorDescription: String? {
        switch self {
        case .invalidRemoteProxy:
            return "Failed to create the SMART helper XPC proxy."
        case .missingReplyData:
            return "The SMART helper returned an empty response."
        case .connectionInterrupted:
            return "The SMART helper connection was interrupted."
        case .connectionInvalidated:
            return "The SMART helper connection was invalidated before completion."
        case .unsupportedOccupancyEndpoint:
            return "The SMART helper does not support disk occupancy scans."
        case .mismatchedOccupancyWorkflow:
            return "The SMART helper returned an occupancy result for another workflow."
        case .mismatchedSMARTRequest:
            return "The SMART helper returned a completion for another request."
        case .unsupportedCompanionInstallationEndpoint:
            return "The installed SMART Helper cannot install the bundled smartctl companion."
        case .companionInstallationUnconfirmed:
            return "The SMART Helper did not confirm that the trusted smartctl companion is available."
        }
    }
}
