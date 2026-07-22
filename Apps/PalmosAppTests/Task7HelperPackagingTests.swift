import CryptoKit
import Foundation
import XCTest
@testable import PalmosApp

final class Task7HelperPackagingTests: XCTestCase {
    private enum AppHostError: Error, Equatable {
        case notAppHosted(String)
    }

    func testEmbeddedHelperIncludesBlessableLaunchdPlistSection() throws {
        let launchdPlist = try embeddedLaunchdPlist()

        XCTAssertEqual(
            launchdPlist["Label"] as? String,
            "com.palmos.smartservice"
        )

        let machServices = try XCTUnwrap(
            launchdPlist["MachServices"] as? [String: Any],
            "Expected launchd plist to define MachServices. Plist: \(launchdPlist)"
        )
        XCTAssertEqual(
            machServices["com.palmos.smartservice"] as? Bool,
            true
        )
    }

    func testAppBundleIncludesExactSmartmontoolsLicense() throws {
        let licenseURL = try XCTUnwrap(
            Bundle.main.url(
                forResource: "smartmontools-COPYING",
                withExtension: "txt"
            )
        )
        let data = try Data(contentsOf: licenseURL)
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()

        XCTAssertEqual(
            digest,
            "8177f97513213526df2cf6184d8ff986c675afb514d4e68a404010521b880643"
        )
    }

    func testAppBundleURLRequirementFailsForNonAppHostedTests() {
        let nonAppBundleURL = URL(fileURLWithPath: "/tmp/PalmosAppTests.xctest")

        XCTAssertThrowsError(try appBundleURL(for: nonAppBundleURL)) { error in
            XCTAssertEqual(
                error as? AppHostError,
                .notAppHosted(nonAppBundleURL.path)
            )
        }
    }

    func testHelperPreflightAcceptsMatchingDevelopmentSignatures() {
        let app = HelperCodeSigningIdentity(
            identifier: HelperInstallationPreflight.appIdentifier,
            teamIdentifier: "TESTTEAM",
            isAdHoc: false
        )
        let helper = HelperCodeSigningIdentity(
            identifier: HelperInstallationPreflight.helperIdentifier,
            teamIdentifier: "TESTTEAM",
            isAdHoc: false
        )

        XCTAssertNoThrow(
            try HelperInstallationPreflight.validateSigningRelationship(
                app: app,
                helper: helper
            )
        )
    }

    func testHelperPreflightRejectsAdHocAppBeforeAuthorization() {
        let app = HelperCodeSigningIdentity(
            identifier: HelperInstallationPreflight.appIdentifier,
            teamIdentifier: nil,
            isAdHoc: true
        )
        let helper = HelperCodeSigningIdentity(
            identifier: HelperInstallationPreflight.helperIdentifier,
            teamIdentifier: "TESTTEAM",
            isAdHoc: false
        )

        XCTAssertThrowsError(
            try HelperInstallationPreflight.validateSigningRelationship(
                app: app,
                helper: helper
            )
        ) { error in
            XCTAssertEqual(
                (error as? LocalizedError)?.errorDescription,
                "Palmos is ad-hoc signed and cannot participate in the SMART Helper trust check. Sign both Palmos targets with the same Apple Development team."
            )
        }
    }

    func testHelperPreflightRejectsMismatchedSigningTeams() {
        let app = HelperCodeSigningIdentity(
            identifier: HelperInstallationPreflight.appIdentifier,
            teamIdentifier: "APPTEAM",
            isAdHoc: false
        )
        let helper = HelperCodeSigningIdentity(
            identifier: HelperInstallationPreflight.helperIdentifier,
            teamIdentifier: "HELPERTEAM",
            isAdHoc: false
        )

        XCTAssertThrowsError(
            try HelperInstallationPreflight.validateSigningRelationship(
                app: app,
                helper: helper
            )
        ) { error in
            XCTAssertEqual(
                (error as? LocalizedError)?.errorDescription,
                "Palmos and the SMART Helper are signed by different teams (APPTEAM and HELPERTEAM). Sign both targets with the same Apple Development team."
            )
        }
    }

    func testHelperPreflightRejectsUnexpectedHelperIdentifier() {
        let app = HelperCodeSigningIdentity(
            identifier: HelperInstallationPreflight.appIdentifier,
            teamIdentifier: "TESTTEAM",
            isAdHoc: false
        )
        let helper = HelperCodeSigningIdentity(
            identifier: "com.example.wrong-helper",
            teamIdentifier: "TESTTEAM",
            isAdHoc: false
        )

        XCTAssertThrowsError(
            try HelperInstallationPreflight.validateSigningRelationship(
                app: app,
                helper: helper
            )
        ) { error in
            XCTAssertEqual(
                (error as? LocalizedError)?.errorDescription,
                "SMART Helper has signing identifier com.example.wrong-helper, expected com.palmos.smartservice. Check the target bundle identifier and code-signing settings."
            )
        }
    }

    func testCompanionPreflightAcceptsMatchingIdentifierTeamAndDigest() throws {
        let helper = HelperCodeSigningIdentity(
            identifier: HelperInstallationPreflight.helperIdentifier,
            teamIdentifier: "TESTTEAM",
            isAdHoc: false
        )
        let companion = HelperCodeSigningIdentity(
            identifier: HelperInstallationPreflight.companionIdentifier,
            teamIdentifier: "TESTTEAM",
            isAdHoc: false
        )

        XCTAssertNoThrow(
            try HelperInstallationPreflight.validateCompanionSigningRelationship(
                helper: helper,
                companion: companion
            )
        )
        XCTAssertEqual(
            try HelperInstallationPreflight.companionDigest(
                in: [HelperInstallationPreflight.companionDigestInfoKey: String(repeating: "a", count: 64)]
            ),
            String(repeating: "a", count: 64)
        )
    }

    func testCompanionPreflightRejectsMalformedDigest() {
        XCTAssertThrowsError(
            try HelperInstallationPreflight.companionDigest(
                in: [HelperInstallationPreflight.companionDigestInfoKey: "not-a-digest"]
            )
        )
    }

    func testBundledCompanionReaderRejectsSymbolicLinkWithinSizeLimit() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try FileManager.default.removeItem(at: temporaryDirectory)
        }

        let binaryURL = temporaryDirectory.appendingPathComponent("smartctl")
        try Data([0xcf, 0xfa, 0xed, 0xfe]).write(to: binaryURL)
        let symbolicLinkURL = temporaryDirectory.appendingPathComponent("smartctl-link")
        try FileManager.default.createSymbolicLink(
            at: symbolicLinkURL,
            withDestinationURL: binaryURL
        )

        XCTAssertThrowsError(
            try BundledSMARTCompanionReader.read(at: symbolicLinkURL)
        ) { error in
            XCTAssertEqual(
                (error as? LocalizedError)?.errorDescription,
                "The bundled smartctl companion is not a regular executable within the \(SMARTCompanionXPCLimits.binaryBytes)-byte installation limit."
            )
        }
    }

    func testHelperInstallerProvisionsCompanionAfterPreparation() async throws {
        let binary = Data([0xcf, 0xfa, 0xed, 0xfe, 1])
        let provisioner = RecordingCompanionProvisioner()
        let installer = HelperInstaller(
            provisioner: provisioner,
            prepareInstallation: { binary }
        )

        try await installer.install()

        let provisionedBinary = await provisioner.binary
        XCTAssertEqual(provisionedBinary, binary)
    }

    func testBlessFailureDescriptionPreservesNestedNSErrorDetails() {
        let underlyingError = NSError(
            domain: "com.palmos.signing",
            code: 17,
            userInfo: [NSLocalizedDescriptionKey: "Helper check rejected the app"]
        )
        let error = NSError(
            domain: "CFErrorDomainLaunchd",
            code: 4,
            userInfo: [
                NSLocalizedDescriptionKey: "The operation could not be completed",
                "ServiceLabel": HelperInstallationPreflight.helperIdentifier,
                NSUnderlyingErrorKey: underlyingError
            ]
        )

        let message = HelperInstallationPreflight.detailedErrorMessage(for: error)

        XCTAssertTrue(message.contains("SMJobBless failed."))
        XCTAssertTrue(message.contains("Domain: CFErrorDomainLaunchd"))
        XCTAssertTrue(message.contains("Code: 4"))
        XCTAssertTrue(message.contains("ServiceLabel=com.palmos.smartservice"))
        XCTAssertTrue(message.contains("Underlying error: [Domain: com.palmos.signing"))
        XCTAssertTrue(message.contains("Code: 17"))
        XCTAssertTrue(message.contains("Helper check rejected the app"))
    }

    func testHelperPreflightPreservesEveryAuthorizedClientRequirement() throws {
        let requirements = [
            "identifier \"com.palmos.app\" and certificate leaf[subject.OU] = \"OLDTEAM\"",
            "identifier \"com.palmos.app\" and certificate leaf[subject.OU] = \"NEWTEAM\""
        ]
        let plist: NSDictionary = ["SMAuthorizedClients": requirements]

        XCTAssertEqual(
            try HelperInstallationPreflight.helperClientRequirements(in: plist),
            requirements
        )
    }

    func testHelperPreflightRejectsEmptyAuthorizedClientRequirement() {
        let plist: NSDictionary = ["SMAuthorizedClients": [""]]

        XCTAssertThrowsError(
            try HelperInstallationPreflight.helperClientRequirements(in: plist)
        ) { error in
            XCTAssertEqual(
                (error as? LocalizedError)?.errorDescription,
                "The SMART Helper does not contain an SMAuthorizedClients requirement. Rebuild the helper with the correct Info.plist."
            )
        }
    }

    func testHelperPreflightAcceptsAnyMatchingAuthorizedClientRequirement() {
        let requirements = ["OLDTEAM", "NEWTEAM"]

        let matchingRequirement = HelperInstallationPreflight.firstMatchingRequirement(
            in: requirements,
            matches: { $0 == "NEWTEAM" }
        )

        XCTAssertEqual(matchingRequirement, "NEWTEAM")
    }

    func testHelperPreflightReportsNoMatchingAuthorizedClientRequirement() {
        let requirements = ["OLDTEAM", "NEWTEAM"]

        let matchingRequirement = HelperInstallationPreflight.firstMatchingRequirement(
            in: requirements,
            matches: { $0 == "OTHERTEAM" }
        )

        XCTAssertNil(matchingRequirement)
    }

    func testDecodeHexdumpSupportsByteAndWordFormats() throws {
        let expected = Data([0x3c, 0x3f, 0x78, 0x6d, 0x6c, 0x20, 0x76, 0x65])
        let byteFormat = "0000000100001000\t3c 3f 78 6d 6c 20 76 65"
        let wordFormat = "0000000100001000\t6d783f3c 6576206c"

        XCTAssertEqual(try decodeHexdump(byteFormat), expected)
        XCTAssertEqual(try decodeHexdump(wordFormat), expected)
    }

    private func appBundleURL() throws -> URL {
        try appBundleURL(for: Bundle.main.bundleURL)
    }

    private func appBundleURL(for bundleURL: URL) throws -> URL {
        guard bundleURL.pathExtension == "app" else {
            throw AppHostError.notAppHosted(bundleURL.path)
        }
        return bundleURL
    }

    private func embeddedLaunchdPlist() throws -> [String: Any] {
        let appBundleURL = try appBundleURL()
        let helperURL = appBundleURL.appendingPathComponent(
            "Contents/Library/LaunchServices/com.palmos.smartservice"
        )

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: helperURL.path),
            "Expected embedded helper at \(helperURL.path)"
        )

        var machineArchitecture = try runTool(
            "/usr/bin/uname",
            arguments: ["-m"]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        if machineArchitecture == "arm64e" {
            machineArchitecture = "arm64"
        }

        let rawLaunchdSection = try runTool(
            "/usr/bin/otool",
            arguments: [
                "-arch", machineArchitecture,
                "-X", "-s", "__TEXT", "__launchd_plist",
                helperURL.path
            ]
        )
        let plistData = try decodeHexdump(rawLaunchdSection)
        let plist = try PropertyListSerialization.propertyList(
            from: plistData,
            options: [],
            format: nil
        )

        return try XCTUnwrap(
            plist as? [String: Any],
            "Expected launchd section to decode into a property list dictionary."
        )
    }

    private func runTool(_ launchPath: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data + errorData, as: UTF8.self)

        guard process.terminationStatus == 0 else {
            XCTFail("\(launchPath) \(arguments.joined(separator: " ")) failed:\n\(output)")
            return output
        }

        return output
    }

    private func decodeHexdump(_ output: String) throws -> Data {
        var bytes: [UInt8] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count > 1 else {
                continue
            }

            for word in fields.dropFirst() where word.allSatisfy(\.isHexDigit) {
                switch word.count {
                case 2:
                    guard let byte = UInt8(word, radix: 16) else {
                        throw XCTSkip("Failed to decode hexdump byte \(word)")
                    }
                    bytes.append(byte)
                case 8:
                    var byteStart = word.startIndex
                    var wordBytes: [UInt8] = []
                    while byteStart < word.endIndex {
                        let byteEnd = word.index(byteStart, offsetBy: 2)
                        let byteString = word[byteStart..<byteEnd]
                        guard let byte = UInt8(byteString, radix: 16) else {
                            throw XCTSkip("Failed to decode hexdump byte \(byteString)")
                        }
                        wordBytes.append(byte)
                        byteStart = byteEnd
                    }

                    bytes.append(contentsOf: wordBytes.reversed())
                default:
                    continue
                }
            }
        }

        XCTAssertFalse(bytes.isEmpty, "No hex payload found in otool section output:\n\(output)")

        return Data(bytes)
    }
}

private actor RecordingCompanionProvisioner: SMARTCompanionProvisioning {
    private(set) var binary: Data?

    func installBundledSmartctlCompanion(_ binary: Data) async throws {
        self.binary = binary
    }
}
