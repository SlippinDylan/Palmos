import Darwin
import CryptoKit
import Foundation
import Security

protocol SMARTCompanionInstalling: Sendable {
    func install(binary: Data) throws
}

enum SMARTCompanionInstallerError: LocalizedError, Equatable {
    case invalidBinary
    case insecureDestinationDirectory
    case temporaryFileCreationFailed(Int32)
    case temporaryFileWriteFailed(Int32)
    case invalidFileMetadata
    case invalidCodeSignature(Int32)
    case unexpectedSigningIdentifier
    case missingTeamIdentifier
    case signingTeamMismatch
    case invalidEmbeddedRequirement(Int32)
    case requirementMismatch(Int32)
    case invalidEmbeddedDigest
    case digestMismatch
    case atomicInstallFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .invalidBinary:
            return "The bundled smartctl companion is not a bounded Mach-O executable."
        case .insecureDestinationDirectory:
            return "The privileged helper tools directory failed its ownership or permissions check."
        case let .temporaryFileCreationFailed(code):
            return "The SMART Helper could not create a secure companion staging file (errno \(code))."
        case let .temporaryFileWriteFailed(code):
            return "The SMART Helper could not write the companion staging file (errno \(code))."
        case .invalidFileMetadata:
            return "The staged smartctl companion failed its regular-file ownership or mode check."
        case let .invalidCodeSignature(status):
            return "The staged smartctl companion has an invalid embedded code signature (OSStatus \(status))."
        case .unexpectedSigningIdentifier:
            return "The staged smartctl companion has an unexpected signing identifier."
        case .missingTeamIdentifier:
            return "The SMART Helper or smartctl companion has no signing Team Identifier."
        case .signingTeamMismatch:
            return "The smartctl companion is not signed by the SMART Helper signing team."
        case let .invalidEmbeddedRequirement(status):
            return "The SMART Helper contains an invalid smartctl signing requirement (OSStatus \(status))."
        case let .requirementMismatch(status):
            return "The smartctl companion does not satisfy the SMART Helper signing requirement (OSStatus \(status))."
        case .invalidEmbeddedDigest:
            return "The SMART Helper contains an invalid smartctl companion SHA-256 digest."
        case .digestMismatch:
            return "The staged smartctl companion does not match the signed release digest."
        case let .atomicInstallFailed(code):
            return "The SMART Helper could not atomically install the smartctl companion (errno \(code))."
        }
    }
}

struct SMARTCompanionSigningIdentity: Equatable, Sendable {
    let identifier: String?
    let teamIdentifier: String?
    let isAdHoc: Bool
}

protocol SMARTCompanionCodeValidating: Sendable {
    func validateCompanion(at url: URL) throws
}

struct SecuritySMARTCompanionCodeValidator: SMARTCompanionCodeValidating, Sendable {
    static let requirementInfoKey = "PalmosSmartctlCompanionRequirement"
    static let digestInfoKey = "PalmosSmartctlCompanionSHA256"
    private static let adHocSignatureFlag: UInt32 = 0x0002

    let helperExecutableURL: URL
    let requirementSource: String
    let expectedSHA256: String

    init(
        helperExecutableURL: URL? = Bundle.main.executableURL,
        requirementSource: String? = Bundle.main.object(
            forInfoDictionaryKey: Self.requirementInfoKey
        ) as? String,
        expectedSHA256: String? = Bundle.main.object(
            forInfoDictionaryKey: Self.digestInfoKey
        ) as? String
    ) throws {
        guard let helperExecutableURL,
              let requirementSource,
              requirementSource.isEmpty == false else {
            throw SMARTCompanionInstallerError.invalidEmbeddedRequirement(errSecParam)
        }
        guard let expectedSHA256,
              Self.isValidSHA256(expectedSHA256) else {
            throw SMARTCompanionInstallerError.invalidEmbeddedDigest
        }
        self.helperExecutableURL = helperExecutableURL
        self.requirementSource = requirementSource
        self.expectedSHA256 = expectedSHA256
    }

    func validateCompanion(at url: URL) throws {
        let companionData = try Data(contentsOf: url, options: .mappedIfSafe)
        guard companionData.count <= SMARTCompanionXPCLimits.binaryBytes,
              Self.sha256Hex(companionData) == expectedSHA256 else {
            throw SMARTCompanionInstallerError.digestMismatch
        }
        let helperCode = try staticCode(at: helperExecutableURL)
        let companionCode = try staticCode(at: url)
        try validateSignature(helperCode)
        try validateSignature(companionCode)

        let helperIdentity = try signingIdentity(for: helperCode)
        let companionIdentity = try signingIdentity(for: companionCode)
        try Self.validateSigningRelationship(
            helper: helperIdentity,
            companion: companionIdentity
        )

        var requirement: SecRequirement?
        let parseStatus = SecRequirementCreateWithString(
            requirementSource as CFString,
            [],
            &requirement
        )
        guard parseStatus == errSecSuccess, let requirement else {
            throw SMARTCompanionInstallerError.invalidEmbeddedRequirement(parseStatus)
        }
        let validationStatus = SecStaticCodeCheckValidity(
            companionCode,
            SecCSFlags(rawValue: kSecCSCheckAllArchitectures),
            requirement
        )
        guard validationStatus == errSecSuccess else {
            throw SMARTCompanionInstallerError.requirementMismatch(validationStatus)
        }
    }

    static func validateSigningRelationship(
        helper: SMARTCompanionSigningIdentity,
        companion: SMARTCompanionSigningIdentity
    ) throws {
        guard helper.isAdHoc == false, companion.isAdHoc == false else {
            throw SMARTCompanionInstallerError.invalidCodeSignature(errSecCSUnsigned)
        }
        guard companion.identifier == SmartctlRunner.trustedExecutableIdentifier else {
            throw SMARTCompanionInstallerError.unexpectedSigningIdentifier
        }
        guard let helperTeam = helper.teamIdentifier, helperTeam.isEmpty == false,
              let companionTeam = companion.teamIdentifier, companionTeam.isEmpty == false else {
            throw SMARTCompanionInstallerError.missingTeamIdentifier
        }
        guard helperTeam == companionTeam else {
            throw SMARTCompanionInstallerError.signingTeamMismatch
        }
    }

    static func isValidSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { character in
            ("0"..."9").contains(String(character)) || ("a"..."f").contains(String(character))
        }
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func staticCode(at url: URL) throws -> SecStaticCode {
        var code: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(url as CFURL, [], &code)
        guard status == errSecSuccess, let code else {
            throw SMARTCompanionInstallerError.invalidCodeSignature(status)
        }
        return code
    }

    private func validateSignature(_ code: SecStaticCode) throws {
        let status = SecStaticCodeCheckValidity(
            code,
            SecCSFlags(rawValue: kSecCSCheckAllArchitectures),
            nil
        )
        guard status == errSecSuccess else {
            throw SMARTCompanionInstallerError.invalidCodeSignature(status)
        }
    }

    private func signingIdentity(for code: SecStaticCode) throws -> SMARTCompanionSigningIdentity {
        var rawInformation: CFDictionary?
        let status = SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &rawInformation
        )
        guard status == errSecSuccess, let information = rawInformation as? [String: Any] else {
            throw SMARTCompanionInstallerError.invalidCodeSignature(status)
        }
        let flags = (information[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        return SMARTCompanionSigningIdentity(
            identifier: information[kSecCodeInfoIdentifier as String] as? String,
            teamIdentifier: information[kSecCodeInfoTeamIdentifier as String] as? String,
            isAdHoc: flags & Self.adHocSignatureFlag != 0
        )
    }
}

struct SmartctlCompanionInstaller: SMARTCompanionInstalling, @unchecked Sendable {
    private let destinationURL: URL
    private let validator: (any SMARTCompanionCodeValidating)?
    private let ownerID: uid_t
    private let groupID: gid_t

    init(
        destinationURL: URL = URL(fileURLWithPath: SmartctlRunner.trustedExecutablePath),
        validator: (any SMARTCompanionCodeValidating)? = nil,
        ownerID: uid_t = 0,
        groupID: gid_t = 0
    ) {
        self.destinationURL = destinationURL
        self.validator = validator
        self.ownerID = ownerID
        self.groupID = groupID
    }

    func install(binary: Data) throws {
        guard binary.isEmpty == false,
              binary.count <= SMARTCompanionXPCLimits.binaryBytes,
              Self.isMachO(binary) else {
            throw SMARTCompanionInstallerError.invalidBinary
        }

        let directoryURL = destinationURL.deletingLastPathComponent()
        try validateDestinationDirectory(directoryURL)
        let temporaryURL = directoryURL.appendingPathComponent(
            ".\(destinationURL.lastPathComponent).install-\(UUID().uuidString.lowercased())"
        )
        var shouldRemoveTemporaryFile = true
        defer {
            if shouldRemoveTemporaryFile {
                _ = unlink(temporaryURL.path)
            }
        }

        let descriptor = open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR | S_IXUSR
        )
        guard descriptor >= 0 else {
            throw SMARTCompanionInstallerError.temporaryFileCreationFailed(errno)
        }

        do {
            try write(binary, to: descriptor)
            guard fchown(descriptor, ownerID, groupID) == 0,
                  fchmod(descriptor, S_IRUSR | S_IWUSR | S_IXUSR | S_IRGRP | S_IXGRP | S_IROTH | S_IXOTH) == 0,
                  fsync(descriptor) == 0 else {
                throw SMARTCompanionInstallerError.temporaryFileWriteFailed(errno)
            }
        } catch {
            _ = close(descriptor)
            throw error
        }
        guard close(descriptor) == 0 else {
            throw SMARTCompanionInstallerError.temporaryFileWriteFailed(errno)
        }

        try validateStagedFile(temporaryURL)
        let codeValidator: any SMARTCompanionCodeValidating
        if let validator {
            codeValidator = validator
        } else {
            codeValidator = try SecuritySMARTCompanionCodeValidator()
        }
        try codeValidator.validateCompanion(at: temporaryURL)
        try syncDirectory(directoryURL)

        guard rename(temporaryURL.path, destinationURL.path) == 0 else {
            throw SMARTCompanionInstallerError.atomicInstallFailed(errno)
        }
        shouldRemoveTemporaryFile = false
        // The atomic replacement is the commit point. A post-rename directory
        // fsync failure must not be reported as an install failure after the
        // previous executable has already been replaced.
        try? syncDirectory(directoryURL)
    }

    static func isMachO(_ data: Data) -> Bool {
        guard data.count >= MemoryLayout<UInt32>.size else { return false }
        let magic = data.withUnsafeBytes { bytes in
            bytes.loadUnaligned(as: UInt32.self)
        }
        return [
            UInt32(MH_MAGIC), UInt32(MH_CIGAM), UInt32(MH_MAGIC_64), UInt32(MH_CIGAM_64),
            UInt32(FAT_MAGIC), UInt32(FAT_CIGAM), UInt32(FAT_MAGIC_64), UInt32(FAT_CIGAM_64)
        ].contains(magic)
    }

    private func validateDestinationDirectory(_ url: URL) throws {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == ownerID,
              metadata.st_gid == groupID,
              metadata.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
            throw SMARTCompanionInstallerError.insecureDestinationDirectory
        }
    }

    private func validateStagedFile(_ url: URL) throws {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == ownerID,
              metadata.st_gid == groupID,
              metadata.st_mode & 0o777 == 0o755 else {
            throw SMARTCompanionInstallerError.invalidFileMetadata
        }
    }

    private func write(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard var cursor = rawBuffer.baseAddress else {
                throw SMARTCompanionInstallerError.invalidBinary
            }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, cursor, remaining)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw SMARTCompanionInstallerError.temporaryFileWriteFailed(errno)
                }
                guard count > 0 else {
                    throw SMARTCompanionInstallerError.temporaryFileWriteFailed(EIO)
                }
                remaining -= count
                cursor = cursor.advanced(by: count)
            }
        }
    }

    private func syncDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw SMARTCompanionInstallerError.atomicInstallFailed(errno)
        }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw SMARTCompanionInstallerError.atomicInstallFailed(errno)
        }
    }
}
