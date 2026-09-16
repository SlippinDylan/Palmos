import Foundation
import CryptoKit
import Security

struct HelperCodeSigningIdentity: Equatable, Sendable {
    let identifier: String?
    let teamIdentifier: String?
    let isAdHoc: Bool
}

enum HelperInstallationPreflight {
    static let appIdentifier = "com.palmos.app"
    static let helperIdentifier = "com.palmos.smartservice"
    static let companionIdentifier = "com.palmos.smartservice.smartctl"
    static let companionRelativePath =
        "Contents/Library/Helpers/com.palmos.smartservice.smartctl"
    static let companionRequirementInfoKey = "PalmosSmartctlCompanionRequirement"
    static let companionDigestInfoKey = "PalmosSmartctlCompanionSHA256"

    private static let adHocSignatureFlag: UInt32 = 0x0002

    static func validate() throws -> URL {
        let appURL = Bundle.main.bundleURL.standardizedFileURL
        guard appURL.pathExtension == "app" else {
            throw HelperInstallerError.preflightFailed(
                "The running Palmos app bundle could not be located at \(appURL.path). Launch Palmos from a built .app bundle and try again."
            )
        }

        let helperURL = appURL.appendingPathComponent(
            "Contents/Library/LaunchServices/\(helperIdentifier)"
        )
        guard FileManager.default.fileExists(atPath: helperURL.path) else {
            throw HelperInstallerError.preflightFailed(
                "The SMART Helper is missing from \(helperURL.path). Rebuild or reinstall Palmos before trying again."
            )
        }
        let companionURL = appURL.appendingPathComponent(companionRelativePath)
        guard FileManager.default.fileExists(atPath: companionURL.path) else {
            throw HelperInstallerError.preflightFailed(
                "The signed smartctl companion is missing from \(companionURL.path). Rebuild or reinstall Palmos before trying again."
            )
        }

        let appCode = try staticCode(at: appURL, component: "Palmos")
        let helperCode = try staticCode(at: helperURL, component: "SMART Helper")
        let companionCode = try staticCode(at: companionURL, component: "smartctl companion")
        let appSigning = try signingIdentity(for: appCode, component: "Palmos")
        let helperSigning = try signingIdentity(for: helperCode, component: "SMART Helper")
        let companionSigning = try signingIdentity(
            for: companionCode,
            component: "smartctl companion"
        )

        try validateSigningRelationship(app: appSigning, helper: helperSigning)
        try validateCompanionSigningRelationship(
            helper: helperSigning,
            companion: companionSigning
        )
        try validateSignature(appCode, component: "Palmos")
        try validateSignature(helperCode, component: "SMART Helper")
        try validateSignature(
            companionCode,
            component: "smartctl companion",
            flags: SecCSFlags(rawValue: kSecCSCheckAllArchitectures)
        )

        let appPlist = try propertyList(
            at: appURL.appendingPathComponent("Contents/Info.plist"),
            component: "Palmos"
        )
        let helperPlist = try embeddedInfoPlist(
            at: helperURL,
            component: "SMART Helper"
        )
        let appRequirement = try appHelperRequirement(in: appPlist)
        let helperRequirements = try helperClientRequirements(in: helperPlist)
        let companionRequirement = try companionRequirement(in: helperPlist)
        let companionDigest = try companionDigest(in: helperPlist)

        try validate(
            requirement: appRequirement,
            owner: "Palmos",
            subject: "SMART Helper",
            subjectCode: helperCode
        )
        try validate(
            requirements: helperRequirements,
            owner: "SMART Helper",
            subject: "Palmos",
            subjectCode: appCode
        )
        try validate(
            requirement: companionRequirement,
            owner: "SMART Helper",
            subject: "smartctl companion",
            subjectCode: companionCode,
            flags: SecCSFlags(rawValue: kSecCSCheckAllArchitectures)
        )
        let companionData = try BundledSMARTCompanionReader.read(at: companionURL)
        guard sha256Hex(companionData) == companionDigest else {
            throw HelperInstallerError.preflightFailed(
                "The bundled smartctl companion does not match the digest embedded in the signed SMART Helper. Rebuild or reinstall Palmos before authorizing the update."
            )
        }
        return companionURL
    }

    static func validateSigningRelationship(
        app: HelperCodeSigningIdentity,
        helper: HelperCodeSigningIdentity
    ) throws {
        try validate(
            app,
            component: "Palmos",
            expectedIdentifier: appIdentifier
        )
        try validate(
            helper,
            component: "SMART Helper",
            expectedIdentifier: helperIdentifier
        )

        guard app.teamIdentifier == helper.teamIdentifier else {
            throw HelperInstallerError.preflightFailed(
                "Palmos and the SMART Helper are signed by different teams (\(app.teamIdentifier ?? "missing") and \(helper.teamIdentifier ?? "missing")). Sign both targets with the same Apple Development team."
            )
        }
    }

    static func validateCompanionSigningRelationship(
        helper: HelperCodeSigningIdentity,
        companion: HelperCodeSigningIdentity
    ) throws {
        try validate(
            helper,
            component: "SMART Helper",
            expectedIdentifier: helperIdentifier
        )
        try validate(
            companion,
            component: "smartctl companion",
            expectedIdentifier: companionIdentifier
        )
        guard helper.teamIdentifier == companion.teamIdentifier else {
            throw HelperInstallerError.preflightFailed(
                "The SMART Helper and smartctl companion are signed by different teams (\(helper.teamIdentifier ?? "missing") and \(companion.teamIdentifier ?? "missing")). Sign both components with the same Apple Development team."
            )
        }
    }

    static func detailedErrorMessage(for error: NSError) -> String {
        "SMJobBless failed. \(describe(error: error))"
    }

    private static func validate(
        _ signing: HelperCodeSigningIdentity,
        component: String,
        expectedIdentifier: String
    ) throws {
        guard !signing.isAdHoc else {
            throw HelperInstallerError.preflightFailed(
                "\(component) is ad-hoc signed and cannot participate in the SMART Helper trust check. Sign both Palmos targets with the same Apple Development team."
            )
        }

        guard signing.teamIdentifier?.isEmpty == false else {
            throw HelperInstallerError.preflightFailed(
                "\(component) has no signing Team Identifier. Sign both Palmos targets with the same Apple Development team."
            )
        }

        guard signing.identifier == expectedIdentifier else {
            throw HelperInstallerError.preflightFailed(
                "\(component) has signing identifier \(signing.identifier ?? "missing"), expected \(expectedIdentifier). Check the target bundle identifier and code-signing settings."
            )
        }
    }

    private static func staticCode(at url: URL, component: String) throws -> SecStaticCode {
        var code: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(url as CFURL, [], &code)
        guard status == errSecSuccess, let code else {
            throw preflightError(
                "macOS could not inspect the \(component) code signature at \(url.path).",
                status: status
            )
        }
        return code
    }

    private static func signingIdentity(
        for code: SecStaticCode,
        component: String
    ) throws -> HelperCodeSigningIdentity {
        let information = try signingInformation(for: code, component: component)
        let identifier = information[kSecCodeInfoIdentifier as String] as? String
        let teamIdentifier = information[kSecCodeInfoTeamIdentifier as String] as? String
        let flags = (information[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0

        return HelperCodeSigningIdentity(
            identifier: identifier,
            teamIdentifier: teamIdentifier,
            isAdHoc: flags & adHocSignatureFlag != 0
        )
    }

    private static func signingInformation(
        for code: SecStaticCode,
        component: String
    ) throws -> NSDictionary {
        var rawInformation: CFDictionary?
        let status = SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &rawInformation
        )
        guard status == errSecSuccess, let rawInformation else {
            throw preflightError(
                "macOS could not read the \(component) code signature.",
                status: status
            )
        }
        return rawInformation
    }

    private static func validateSignature(
        _ code: SecStaticCode,
        component: String,
        flags: SecCSFlags = []
    ) throws {
        let status = SecStaticCodeCheckValidity(code, flags, nil)
        guard status == errSecSuccess else {
            throw preflightError(
                "The \(component) code signature is invalid or has been modified after signing.",
                status: status
            )
        }
    }

    private static func propertyList(at url: URL, component: String) throws -> NSDictionary {
        do {
            let data = try Data(contentsOf: url)
            let plist = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            )
            guard let dictionary = plist as? NSDictionary else {
                throw CocoaError(.propertyListReadCorrupt)
            }
            return dictionary
        } catch {
            throw HelperInstallerError.preflightFailed(
                "The \(component) Info.plist could not be read at \(url.path): \(error.localizedDescription)"
            )
        }
    }

    private static func embeddedInfoPlist(at url: URL, component: String) throws -> NSDictionary {
        guard let plist = CFBundleCopyInfoDictionaryForURL(url as CFURL) else {
            throw HelperInstallerError.preflightFailed(
                "The embedded \(component) Info.plist could not be read at \(url.path). Rebuild the helper with the correct Info.plist section."
            )
        }
        return plist as NSDictionary
    }

    private static func appHelperRequirement(in plist: NSDictionary) throws -> String {
        guard
            let requirements = plist["SMPrivilegedExecutables"] as? NSDictionary,
            let requirement = requirements[helperIdentifier] as? String,
            !requirement.isEmpty
        else {
            throw HelperInstallerError.preflightFailed(
                "Palmos does not contain an SMPrivilegedExecutables requirement for \(helperIdentifier). Rebuild the app with the correct Info.plist."
            )
        }
        return requirement
    }

    static func helperClientRequirements(in plist: NSDictionary) throws -> [String] {
        guard
            let requirements = plist["SMAuthorizedClients"] as? [String],
            !requirements.isEmpty,
            requirements.allSatisfy({ !$0.isEmpty })
        else {
            throw HelperInstallerError.preflightFailed(
                "The SMART Helper does not contain an SMAuthorizedClients requirement. Rebuild the helper with the correct Info.plist."
            )
        }
        return requirements
    }

    static func companionRequirement(in plist: NSDictionary) throws -> String {
        guard let requirement = plist[companionRequirementInfoKey] as? String,
              requirement.isEmpty == false else {
            throw HelperInstallerError.preflightFailed(
                "The SMART Helper does not contain a smartctl companion signing requirement. Rebuild the helper with the correct embedded Info.plist."
            )
        }
        return requirement
    }

    static func companionDigest(in plist: NSDictionary) throws -> String {
        guard let digest = plist[companionDigestInfoKey] as? String,
              digest.count == 64,
              digest.allSatisfy({ character in
                  ("0"..."9").contains(String(character)) || ("a"..."f").contains(String(character))
              }) else {
            throw HelperInstallerError.preflightFailed(
                "The SMART Helper does not contain a valid smartctl companion SHA-256 digest. Rebuild the helper with the signed release digest."
            )
        }
        return digest
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func validate(
        requirement source: String,
        owner: String,
        subject: String,
        subjectCode: SecStaticCode,
        flags: SecCSFlags = []
    ) throws {
        var requirement: SecRequirement?
        let parseStatus = SecRequirementCreateWithString(source as CFString, [], &requirement)
        guard parseStatus == errSecSuccess, let requirement else {
            throw preflightError(
                "The code-signing requirement embedded in \(owner) is invalid.",
                status: parseStatus
            )
        }

        let validationStatus = SecStaticCodeCheckValidity(subjectCode, flags, requirement)
        guard validationStatus == errSecSuccess else {
            throw preflightError(
                "The \(owner) signing requirement does not accept \(subject). Sign both targets with the same Apple Development team and verify their bundle identifiers.",
                status: validationStatus
            )
        }
    }

    private static func validate(
        requirements sources: [String],
        owner: String,
        subject: String,
        subjectCode: SecStaticCode
    ) throws {
        var lastStatus = errSecCSReqFailed
        let matchingRequirement = try firstMatchingRequirement(in: sources) { source in
            var requirement: SecRequirement?
            let status = SecRequirementCreateWithString(source as CFString, [], &requirement)
            guard status == errSecSuccess, let requirement else {
                throw preflightError(
                    "A code-signing requirement embedded in \(owner) is invalid.",
                    status: status
                )
            }
            let validationStatus = SecStaticCodeCheckValidity(subjectCode, [], requirement)
            lastStatus = validationStatus
            return validationStatus == errSecSuccess
        }

        guard matchingRequirement != nil else {
            throw preflightError(
                "The \(owner) signing requirements do not accept \(subject). Sign both targets with the same Apple Development team and verify their bundle identifiers.",
                status: lastStatus
            )
        }
    }

    static func firstMatchingRequirement(
        in sources: [String],
        matches: (String) throws -> Bool
    ) rethrows -> String? {
        for source in sources {
            if try matches(source) {
                return source
            }
        }

        return nil
    }

    private static func preflightError(_ message: String, status: OSStatus) -> HelperInstallerError {
        let statusDescription = SecCopyErrorMessageString(status, nil) as String?
        let detail = statusDescription.map { "OSStatus \(status): \($0)" } ?? "OSStatus \(status)"
        return .preflightFailed("\(message) \(detail)")
    }

    private static func describe(error: NSError) -> String {
        var fields = [
            "Domain: \(error.domain)",
            "Code: \(error.code)",
            "Description: \(error.localizedDescription)"
        ]

        let userInfo = error.userInfo
            .filter { $0.key != NSUnderlyingErrorKey }
            .map { "\($0.key)=\(String(describing: $0.value))" }
            .sorted()
        if !userInfo.isEmpty {
            fields.append("User info: \(userInfo.joined(separator: ", "))")
        }

        if let underlyingError = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            fields.append("Underlying error: [\(describe(error: underlyingError))]")
        }

        return fields.joined(separator: "; ")
    }
}
