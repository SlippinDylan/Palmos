import Foundation
import Security
import ServiceManagement

protocol HelperInstalling: Sendable {
    func install() async throws
}

enum HelperInstallerError: LocalizedError {
    case authorizationFailed(OSStatus)
    case preflightFailed(String)
    case blessFailed(String)

    var errorDescription: String? {
        switch self {
        case let .authorizationFailed(status):
            return "Authorization failed while preparing the SMART Helper install. \(Self.describe(status))"
        case let .preflightFailed(message):
            return message
        case let .blessFailed(message):
            return message
        }
    }

    private static func describe(_ status: OSStatus) -> String {
        let description = SecCopyErrorMessageString(status, nil) as String?
        return "OSStatus \(status)\(description.map { ": \($0)" } ?? ".")"
    }
}

final class HelperInstaller: HelperInstalling {
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
        let binary = try await Task.detached(priority: .userInitiated) {
            try prepareInstallation()
        }.value
        try Task.checkCancellation()
        try await provisioner.installBundledSmartctlCompanion(binary)
    }

    private static func prepareInstallation() throws -> Data {
        let companionURL = try HelperInstallationPreflight.validate()
        let binary = try BundledSMARTCompanionReader.read(at: companionURL)
        try installPrivilegedHelper()
        return binary
    }

    private static func installPrivilegedHelper() throws {
        var authorizationRef: AuthorizationRef?
        let flags: AuthorizationFlags = [.interactionAllowed, .extendRights, .preAuthorize]
        let status = kSMRightBlessPrivilegedHelper.withCString { blessRightName in
            var blessRight = AuthorizationItem(
                name: blessRightName,
                valueLength: 0,
                value: nil,
                flags: 0
            )
            return withUnsafeMutablePointer(to: &blessRight) { pointer in
                var rights = AuthorizationRights(count: 1, items: pointer)
                return AuthorizationCreate(&rights, nil, flags, &authorizationRef)
            }
        }

        guard status == errAuthorizationSuccess, let authorizationRef else {
            throw HelperInstallerError.authorizationFailed(status)
        }

        defer {
            AuthorizationFree(authorizationRef, [])
        }

        var unmanagedError: Unmanaged<CFError>?
        let didBless = SMJobBless(
            kSMDomainSystemLaunchd,
            HelperInstallationPreflight.helperIdentifier as CFString,
            authorizationRef,
            &unmanagedError
        )

        guard didBless else {
            let message: String
            if let error = unmanagedError?.takeRetainedValue() {
                message = HelperInstallationPreflight.detailedErrorMessage(
                    for: error as Error as NSError
                )
            } else {
                message = "SMJobBless failed without returning an error. Check the macOS system log for ServiceManagement details."
            }
            throw HelperInstallerError.blessFailed(message)
        }
    }
}
