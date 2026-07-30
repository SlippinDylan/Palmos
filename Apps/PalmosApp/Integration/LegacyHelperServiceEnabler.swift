import Foundation
import os
import Security
import ServiceManagement

enum LegacyHelperServiceEnablerError: LocalizedError {
    case submitFailed(String)
    case serviceRemainsDisabled
    case serviceStatusTimedOut(Int)
    case removeFailed(String)
    case executionAndRemovalFailed(execution: String, removal: String)

    var errorDescription: String? {
        switch self {
        case let .submitFailed(message):
            return "Failed to submit the SMART Helper service repair job. \(message)"
        case .serviceRemainsDisabled:
            return "The SMART Helper service remains disabled after the repair attempt."
        case let .serviceStatusTimedOut(status):
            return "Timed out while waiting for the SMART Helper service to become enabled (status \(status))."
        case let .removeFailed(message):
            return "Failed to remove the SMART Helper service repair job. \(message)"
        case let .executionAndRemovalFailed(execution, removal):
            return "The SMART Helper service repair failed (\(execution)) and its temporary job could not be removed (\(removal))."
        }
    }
}

protocol LegacyHelperServiceJobManaging: AnyObject {
    func submitRepairJob(
        _ job: [String: Any],
        authorization: AuthorizationRef
    ) throws
    func helperServiceStatus() -> SMAppService.Status
    func removeRepairJob(
        authorization: AuthorizationRef,
        allowsMissing: Bool
    ) throws
    func waitBeforeInstallRetry()
    func waitBeforeNextStatusCheck()
}

/// Restores the launchd enable override before the legacy SMJobBless flow runs.
/// The submitted executable and every argument stay compile-time fixed so this
/// compatibility path cannot become a general privileged command runner.
struct LegacyHelperServiceEnabler {
    static let repairJobLabel = "com.palmos.smartservice.enable-repair"
    static let launchctlPath = "/bin/launchctl"
    static let serviceTarget = "system/com.palmos.smartservice"
    static let maximumInstallAttempts = 21
    static let maximumStatusChecks = 250
    static let helperPlistURL = URL(
        fileURLWithPath: "/Library/LaunchDaemons/com.palmos.smartservice.plist"
    )

    static var repairJob: [String: Any] {
        [
            "Label": repairJobLabel,
            "ProgramArguments": [launchctlPath, "enable", serviceTarget],
            "RunAtLoad": true,
            "LaunchOnlyOnce": true
        ]
    }

    private let jobManager: any LegacyHelperServiceJobManaging
    private let logger: Logger

    init(
        jobManager: any LegacyHelperServiceJobManaging = SystemLegacyHelperServiceJobManager(),
        logger: Logger = Logger(subsystem: "com.palmos.app", category: "HelperInstallation")
    ) {
        self.jobManager = jobManager
        self.logger = logger
    }

    var requiresRepair: Bool {
        Self.requiresRepair(for: jobManager.helperServiceStatus())
    }

    static func requiresRepair(for status: SMAppService.Status) -> Bool {
        status != .enabled
    }

    func repairService(
        authorization: AuthorizationRef,
        shouldRetryInstall: (Error) -> Bool = { _ in false },
        installHelper: () throws -> Void
    ) throws {
        try Task.checkCancellation()
        logger.notice("Clearing any stale SMART Helper service repair job")
        do {
            try jobManager.removeRepairJob(
                authorization: authorization,
                allowsMissing: true
            )
        } catch {
            logger.error("Stale SMART Helper repair job removal failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }

        logger.notice("Submitting the fixed SMART Helper service enable repair")
        do {
            try jobManager.submitRepairJob(Self.repairJob, authorization: authorization)
        } catch {
            logger.error("SMART Helper repair job submission failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }

        let executionError: Error?
        do {
            try Task.checkCancellation()
            try installHelperAfterServiceRepair(
                shouldRetry: shouldRetryInstall,
                installHelper: installHelper
            )
            try waitForEnabledService()
            executionError = nil
        } catch {
            executionError = error
        }

        do {
            try jobManager.removeRepairJob(
                authorization: authorization,
                allowsMissing: true
            )
        } catch {
            let removalMessage = error.localizedDescription
            logger.error("SMART Helper repair job removal failed: \(removalMessage, privacy: .public)")
            if let executionError {
                throw LegacyHelperServiceEnablerError.executionAndRemovalFailed(
                    execution: executionError.localizedDescription,
                    removal: removalMessage
                )
            }
            throw error
        }

        if let executionError {
            logger.error("SMART Helper service enable failed: \(executionError.localizedDescription, privacy: .public)")
            throw executionError
        }
        logger.notice("SMART Helper service enable repair completed")
    }

    private func installHelperAfterServiceRepair(
        shouldRetry: (Error) -> Bool,
        installHelper: () throws -> Void
    ) throws {
        for attempt in 0..<Self.maximumInstallAttempts {
            try Task.checkCancellation()
            do {
                try installHelper()
                return
            } catch {
                guard shouldRetry(error),
                      attempt + 1 < Self.maximumInstallAttempts else {
                    throw error
                }
                logger.notice("Waiting for the SMART Helper service enable repair before retrying SMJobBless")
                jobManager.waitBeforeInstallRetry()
            }
        }
    }

    private func waitForEnabledService() throws {
        for _ in 0..<Self.maximumStatusChecks {
            try Task.checkCancellation()
            if jobManager.helperServiceStatus() == .enabled {
                return
            }
            jobManager.waitBeforeNextStatusCheck()
        }

        let status = jobManager.helperServiceStatus()
        if status == .requiresApproval {
            throw LegacyHelperServiceEnablerError.serviceRemainsDisabled
        }
        throw LegacyHelperServiceEnablerError.serviceStatusTimedOut(status.rawValue)
    }
}

private final class SystemLegacyHelperServiceJobManager: LegacyHelperServiceJobManaging {
    private static let pollInterval: TimeInterval = 0.02

    func submitRepairJob(
        _ job: [String: Any],
        authorization: AuthorizationRef
    ) throws {
        var unmanagedError: Unmanaged<CFError>?
        let submitted = SMJobSubmit(
            kSMDomainSystemLaunchd,
            job as CFDictionary,
            authorization,
            &unmanagedError
        )
        guard submitted else {
            throw LegacyHelperServiceEnablerError.submitFailed(
                Self.consumeError(unmanagedError, fallback: "SMJobSubmit returned no error.")
            )
        }
    }

    func helperServiceStatus() -> SMAppService.Status {
        SMAppService.statusForLegacyPlist(
            at: LegacyHelperServiceEnabler.helperPlistURL
        )
    }

    func removeRepairJob(
        authorization: AuthorizationRef,
        allowsMissing: Bool
    ) throws {
        var unmanagedError: Unmanaged<CFError>?
        let removed = SMJobRemove(
            kSMDomainSystemLaunchd,
            LegacyHelperServiceEnabler.repairJobLabel as CFString,
            authorization,
            true,
            &unmanagedError
        )
        guard removed == false else { return }

        let error = unmanagedError?.takeRetainedValue()
        if allowsMissing,
           let error,
           Self.isServiceManagementJobNotFound(error) {
            return
        }
        throw LegacyHelperServiceEnablerError.removeFailed(
            Self.describe(error, fallback: "SMJobRemove returned no error.")
        )
    }

    func waitBeforeNextStatusCheck() {
        Thread.sleep(forTimeInterval: Self.pollInterval)
    }

    func waitBeforeInstallRetry() {
        Thread.sleep(forTimeInterval: 0.25)
    }

    private static func consumeError(
        _ unmanagedError: Unmanaged<CFError>?,
        fallback: String
    ) -> String {
        guard let error = unmanagedError?.takeRetainedValue() else {
            return fallback
        }
        return describe(error, fallback: fallback)
    }

    private static func describe(_ error: CFError?, fallback: String) -> String {
        guard let error else { return fallback }
        let nsError = error as Error as NSError
        return "Domain: \(nsError.domain), code: \(nsError.code), description: \(nsError.localizedDescription)"
    }

    private static func isServiceManagementJobNotFound(_ error: CFError) -> Bool {
        guard CFErrorGetCode(error) == kSMErrorJobNotFound else { return false }
        let domain = CFErrorGetDomain(error)
        return CFEqual(domain, kSMErrorDomainLaunchd) ||
            CFEqual(domain, kSMErrorDomainFramework) ||
            CFEqual(domain, kSMErrorDomainIPC)
    }
}
