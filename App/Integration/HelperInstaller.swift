import Foundation
import os
import Security
import ServiceManagement

protocol HelperInstalling: Sendable {
    func install() async throws
}

enum HelperInstallerError: LocalizedError {
    case authorizationFailed(OSStatus)
    case preflightFailed(String)
    case blessFailed(String)
    case serviceMustBeEnabled(String)

    var errorDescription: String? {
        switch self {
        case let .authorizationFailed(status):
            return "Authorization failed while preparing the SMART Helper install. \(Self.describe(status))"
        case let .preflightFailed(message):
            return message
        case let .blessFailed(message), let .serviceMustBeEnabled(message):
            return message
        }
    }

    private static func describe(_ status: OSStatus) -> String {
        let description = SecCopyErrorMessageString(status, nil) as String?
        return "OSStatus \(status)\(description.map { ": \($0)" } ?? ".")"
    }
}

final class HelperInstaller: HelperInstalling {
    private static let logger = Logger(
        subsystem: "com.palmos.app",
        category: "HelperInstallation"
    )

    private let provisioner: any SMARTCompanionProvisioning
    private let prepareInstallation: @Sendable () throws -> Data

    init(
        provisioner: any SMARTCompanionProvisioning = SMARTServiceClient(),
        prepareInstallation: (@Sendable () throws -> Data)? = nil
    ) {
        self.provisioner = provisioner
        self.prepareInstallation = prepareInstallation ?? Self.prepareInstallation
    }

    func install() async throws {
        let prepareInstallation = self.prepareInstallation
        let preparationTask = Task.detached(priority: .userInitiated) {
            try prepareInstallation()
        }
        let binary = try await withTaskCancellationHandler {
            try await preparationTask.value
        } onCancel: {
            preparationTask.cancel()
        }
        try Task.checkCancellation()
        do {
            try await provisionCompanion(binary)
        } catch {
            Self.logger.error("SMART Helper XPC companion verification failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    private static func prepareInstallation() throws -> Data {
        try Task.checkCancellation()
        let companionURL = try HelperInstallationPreflight.validate()
        let binary = try BundledSMARTCompanionReader.read(at: companionURL)
        logger.notice("SMART Helper installation preflight completed")
        try installPrivilegedHelper()
        return binary
    }

    private static func installPrivilegedHelper() throws {
        let serviceEnabler = LegacyHelperServiceEnabler()
        let requiresServiceRepair = serviceEnabler.requiresRepair
        var authorizationRef: AuthorizationRef?
        let flags: AuthorizationFlags = [.interactionAllowed, .extendRights, .preAuthorize]
        let status = createAuthorization(
            requiresServiceRepair: requiresServiceRepair,
            flags: flags,
            authorizationRef: &authorizationRef
        )

        guard status == errAuthorizationSuccess, let authorizationRef else {
            if let authorizationRef {
                AuthorizationFree(authorizationRef, [.destroyRights])
            }
            logger.error("SMART Helper authorization failed with OSStatus \(status)")
            throw HelperInstallerError.authorizationFailed(status)
        }

        defer {
            AuthorizationFree(authorizationRef, [.destroyRights])
        }

        if requiresServiceRepair {
            logger.notice("Repairing the legacy SMART Helper service before XPC verification")
            try serviceEnabler.repairService(
                authorization: authorizationRef,
                shouldRetryInstall: { error in
                    guard case HelperInstallerError.serviceMustBeEnabled = error else {
                        return false
                    }
                    return true
                },
                installHelper: {
                    try blessPrivilegedHelper(authorization: authorizationRef)
                }
            )
        } else {
            try blessPrivilegedHelper(authorization: authorizationRef)
        }
    }

    private static func blessPrivilegedHelper(
        authorization: AuthorizationRef
    ) throws {
        try Task.checkCancellation()
        logger.notice("Blessing the SMART Helper")

        var unmanagedError: Unmanaged<CFError>?
        let didBless = SMJobBless(
            kSMDomainSystemLaunchd,
            HelperInstallationPreflight.helperIdentifier as CFString,
            authorization,
            &unmanagedError
        )

        guard didBless else {
            let error = unmanagedError?.takeRetainedValue()
            let message: String
            if let error {
                message = HelperInstallationPreflight.detailedErrorMessage(
                    for: error as Error as NSError
                )
            } else {
                message = "SMJobBless failed without returning an error. Check the macOS system log for ServiceManagement details."
            }
            logger.error("SMART Helper blessing failed: \(message, privacy: .public)")
            if let error, isServiceMustBeEnabledError(error) {
                throw HelperInstallerError.serviceMustBeEnabled(message)
            }
            throw HelperInstallerError.blessFailed(message)
        }
        logger.notice("SMJobBless completed; waiting for XPC companion verification")
    }

    private static func createAuthorization(
        requiresServiceRepair: Bool,
        flags: AuthorizationFlags,
        authorizationRef: inout AuthorizationRef?
    ) -> OSStatus {
        if requiresServiceRepair {
            return kSMRightModifySystemDaemons.withCString { modifyRightName in
                kSMRightBlessPrivilegedHelper.withCString { blessRightName in
                    var rightItems = [
                        AuthorizationItem(
                            name: modifyRightName,
                            valueLength: 0,
                            value: nil,
                            flags: 0
                        ),
                        AuthorizationItem(
                            name: blessRightName,
                            valueLength: 0,
                            value: nil,
                            flags: 0
                        )
                    ]
                    return createAuthorization(
                        rightItems: &rightItems,
                        flags: flags,
                        authorizationRef: &authorizationRef
                    )
                }
            }
        }

        return kSMRightBlessPrivilegedHelper.withCString { blessRightName in
            var rightItems = [AuthorizationItem(
                name: blessRightName,
                valueLength: 0,
                value: nil,
                flags: 0
            )]
            return createAuthorization(
                rightItems: &rightItems,
                flags: flags,
                authorizationRef: &authorizationRef
            )
        }
    }

    private static func createAuthorization(
        rightItems: inout [AuthorizationItem],
        flags: AuthorizationFlags,
        authorizationRef: inout AuthorizationRef?
    ) -> OSStatus {
        rightItems.withUnsafeMutableBufferPointer { buffer in
            var rights = AuthorizationRights(
                count: UInt32(buffer.count),
                items: buffer.baseAddress
            )
            return AuthorizationCreate(&rights, nil, flags, &authorizationRef)
        }
    }

    private func provisionCompanion(_ binary: Data) async throws {
        do {
            try await provisioner.installBundledSmartctlCompanion(binary)
        } catch where Self.isRetryableXPCConnectionError(error) {
            Self.logger.notice("Retrying SMART Helper XPC companion verification once")
            try await Task.sleep(for: .milliseconds(150))
            try await provisioner.installBundledSmartctlCompanion(binary)
        }
        Self.logger.notice("SMART Helper XPC companion verification completed")
    }

    private static func isRetryableXPCConnectionError(_ error: Error) -> Bool {
        if let clientError = error as? SMARTServiceClientError {
            return clientError == .invalidRemoteProxy ||
                clientError == .connectionInterrupted ||
                clientError == .connectionInvalidated
        }
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain && nsError.code == 4099
    }

    static func isServiceMustBeEnabledError(_ error: CFError) -> Bool {
        guard CFErrorGetCode(error) == kSMErrorJobMustBeEnabled else { return false }
        return CFEqual(CFErrorGetDomain(error), kSMErrorDomainFramework)
    }
}
