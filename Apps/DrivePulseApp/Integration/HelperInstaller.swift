import Foundation
import Security
import ServiceManagement

protocol HelperInstalling: Sendable {
    func install() async throws
}

enum HelperInstallerError: LocalizedError {
    case authorizationFailed(OSStatus)
    case blessFailed(String)

    var errorDescription: String? {
        switch self {
        case .authorizationFailed:
            return "Authorization failed while preparing the SMART helper install."
        case let .blessFailed(message):
            return message
        }
    }
}

final class HelperInstaller: HelperInstalling {
    func install() async throws {
        try await Task.detached(priority: .userInitiated) {
            try Self.installPrivilegedHelper()
        }.value
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
            var rights = withUnsafeMutablePointer(to: &blessRight) { pointer in
                AuthorizationRights(count: 1, items: pointer)
            }
            return AuthorizationCreate(&rights, nil, flags, &authorizationRef)
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
            "com.drivepulse.smartservice" as CFString,
            authorizationRef,
            &unmanagedError
        )

        guard didBless else {
            let message = unmanagedError?
                .takeRetainedValue()
                .localizedDescription ?? "SMJobBless failed."
            throw HelperInstallerError.blessFailed(message)
        }
    }
}
