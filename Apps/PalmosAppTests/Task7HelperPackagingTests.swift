import CryptoKit
import Foundation
import Security
import ServiceManagement
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

    func testAppBundleIncludesExactPalmosLicense() throws {
        try assertBundledLicense(
            resource: "LICENSE",
            extension: nil,
            expectedSHA256: "054515e39d8e9ec2004aeafc2aba2700aad7f7c94041c43fd316ac998c822b59"
        )
    }

    func testAppBundleIncludesExactMenuBarExtraAccessLicense() throws {
        try assertBundledLicense(
            resource: "MenuBarExtraAccess-LICENSE",
            extension: "txt",
            expectedSHA256: "c5359afef4354cebfefe6632278be29f6607fb6f4bd35c07028c9a7a639eebf3"
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

    private func assertBundledLicense(
        resource: String,
        extension fileExtension: String?,
        expectedSHA256: String
    ) throws {
        let licenseURL = try XCTUnwrap(
            Bundle.main.url(forResource: resource, withExtension: fileExtension)
        )
        let data = try Data(contentsOf: licenseURL)
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()

        XCTAssertEqual(digest, expectedSHA256)
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

    func testHelperInstallerRetriesOneXPCConnectionFailure() async throws {
        let provisioner = SequencedCompanionProvisioner(
            errors: [SMARTServiceClientError.connectionInvalidated]
        )
        let installer = HelperInstaller(
            provisioner: provisioner,
            prepareInstallation: { Data([1]) }
        )

        try await installer.install()

        let callCount = await provisioner.callCount
        XCTAssertEqual(callCount, 2)
    }

    func testHelperInstallerDoesNotRetryNonConnectionFailure() async {
        let provisioner = SequencedCompanionProvisioner(
            errors: [SMARTServiceClientError.companionInstallationUnconfirmed]
        )
        let installer = HelperInstaller(
            provisioner: provisioner,
            prepareInstallation: { Data([1]) }
        )

        do {
            try await installer.install()
            XCTFail("Expected companion verification to fail")
        } catch {
            XCTAssertEqual(
                error as? SMARTServiceClientError,
                .companionInstallationUnconfirmed
            )
        }

        let callCount = await provisioner.callCount
        XCTAssertEqual(callCount, 1)
    }

    func testHelperInstallerRetriesXPCConnectionOnlyOnce() async {
        let provisioner = SequencedCompanionProvisioner(
            errors: [
                SMARTServiceClientError.connectionInvalidated,
                SMARTServiceClientError.connectionInterrupted
            ]
        )
        let installer = HelperInstaller(
            provisioner: provisioner,
            prepareInstallation: { Data([1]) }
        )

        do {
            try await installer.install()
            XCTFail("Expected the second XPC connection failure")
        } catch {
            XCTAssertEqual(error as? SMARTServiceClientError, .connectionInterrupted)
        }
        let callCount = await provisioner.callCount
        XCTAssertEqual(callCount, 2)
    }

    func testHelperInstallerPropagatesCancellationIntoPreparationTask() async throws {
        let provisioner = SequencedCompanionProvisioner(errors: [])
        let installer = HelperInstaller(
            provisioner: provisioner,
            prepareInstallation: {
                for _ in 0..<500 {
                    try Task.checkCancellation()
                    Thread.sleep(forTimeInterval: 0.001)
                }
                return Data([1])
            }
        )
        let installation = Task {
            try await installer.install()
        }

        try await Task.sleep(for: .milliseconds(20))
        installation.cancel()

        do {
            try await installation.value
            XCTFail("Expected installation cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, received \(error)")
        }
        let callCount = await provisioner.callCount
        XCTAssertEqual(callCount, 0)
    }

    func testServiceRepairJobUsesOnlyFixedLaunchctlArguments() throws {
        let job = LegacyHelperServiceEnabler.repairJob

        XCTAssertEqual(
            Set(job.keys),
            Set(["Label", "ProgramArguments", "RunAtLoad", "LaunchOnlyOnce"])
        )
        XCTAssertEqual(
            job["Label"] as? String,
            "com.palmos.smartservice.enable-repair"
        )
        XCTAssertEqual(
            job["ProgramArguments"] as? [String],
            [
                "/bin/launchctl",
                "enable",
                "system/com.palmos.smartservice"
            ]
        )
        XCTAssertEqual(job["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(job["LaunchOnlyOnce"] as? Bool, true)
    }

    func testServiceRepairWaitsForSuccessAndRemovesTemporaryJob() throws {
        let manager = RecordingLegacyHelperServiceJobManager(
            statuses: [.requiresApproval, .enabled]
        )

        try withAuthorization { authorization in
            try LegacyHelperServiceEnabler(jobManager: manager)
                .repairService(authorization: authorization) {
                    manager.recordInstall()
                }
        }

        XCTAssertEqual(
            manager.events,
            ["remove-if-present", "submit", "install", "status", "wait", "status", "remove-if-present"]
        )
    }

    func testServiceRepairRetriesJobMustBeEnabledUntilInstallSucceeds() throws {
        let manager = RecordingLegacyHelperServiceJobManager(statuses: [.enabled])
        var installAttempts = 0

        try withAuthorization { authorization in
            try LegacyHelperServiceEnabler(jobManager: manager).repairService(
                authorization: authorization,
                shouldRetryInstall: { error in
                    guard case HelperInstallerError.serviceMustBeEnabled = error else {
                        return false
                    }
                    return true
                },
                installHelper: {
                    installAttempts += 1
                    manager.recordInstall()
                    if installAttempts < 3 {
                        throw HelperInstallerError.serviceMustBeEnabled("Not enabled yet")
                    }
                }
            )
        }

        XCTAssertEqual(installAttempts, 3)
        XCTAssertEqual(
            manager.events,
            [
                "remove-if-present", "submit", "install", "install-retry-wait",
                "install", "install-retry-wait", "install", "status",
                "remove-if-present"
            ]
        )
    }

    func testServiceRepairStopsAtJobMustBeEnabledRetryLimit() throws {
        let manager = RecordingLegacyHelperServiceJobManager(statuses: [.enabled])
        var installAttempts = 0

        XCTAssertThrowsError(
            try withAuthorization { authorization in
                try LegacyHelperServiceEnabler(jobManager: manager).repairService(
                    authorization: authorization,
                    shouldRetryInstall: { _ in true },
                    installHelper: {
                        installAttempts += 1
                        manager.recordInstall()
                        throw HelperInstallerError.serviceMustBeEnabled("Still disabled")
                    }
                )
            }
        ) { error in
            XCTAssertEqual(error.localizedDescription, "Still disabled")
        }

        XCTAssertEqual(
            installAttempts,
            LegacyHelperServiceEnabler.maximumInstallAttempts
        )
        XCTAssertEqual(
            manager.events.filter { $0 == "install-retry-wait" }.count,
            LegacyHelperServiceEnabler.maximumInstallAttempts - 1
        )
        XCTAssertEqual(manager.events.last, "remove-if-present")
    }

    func testJobMustBeEnabledRetryRequiresServiceManagementDomainAndCode() throws {
        let retryableError = try XCTUnwrap(CFErrorCreate(
            kCFAllocatorDefault,
            kSMErrorDomainFramework,
            kSMErrorJobMustBeEnabled,
            nil
        ))
        let wrongCode = try XCTUnwrap(CFErrorCreate(
            kCFAllocatorDefault,
            kSMErrorDomainFramework,
            kSMErrorJobNotFound,
            nil
        ))
        let wrongDomain = try XCTUnwrap(CFErrorCreate(
            kCFAllocatorDefault,
            NSCocoaErrorDomain as CFString,
            kSMErrorJobMustBeEnabled,
            nil
        ))

        XCTAssertTrue(HelperInstaller.isServiceMustBeEnabledError(retryableError))
        XCTAssertFalse(HelperInstaller.isServiceMustBeEnabledError(wrongCode))
        XCTAssertFalse(HelperInstaller.isServiceMustBeEnabledError(wrongDomain))
    }

    func testServiceRepairRemovesStaleJobBeforeSubmission() throws {
        let manager = RecordingLegacyHelperServiceJobManager(statuses: [.enabled])

        try withAuthorization { authorization in
            try LegacyHelperServiceEnabler(jobManager: manager)
                .repairService(authorization: authorization) {
                    manager.recordInstall()
                }
        }

        XCTAssertEqual(
            manager.events,
            ["remove-if-present", "submit", "install", "status", "remove-if-present"]
        )
    }

    func testOnlyEnabledLegacyServiceSkipsRepair() {
        XCTAssertFalse(
            LegacyHelperServiceEnabler.requiresRepair(for: .enabled)
        )
        XCTAssertTrue(
            LegacyHelperServiceEnabler.requiresRepair(for: .requiresApproval)
        )
        XCTAssertTrue(
            LegacyHelperServiceEnabler.requiresRepair(for: .notRegistered)
        )
        XCTAssertTrue(
            LegacyHelperServiceEnabler.requiresRepair(for: .notFound)
        )
    }

    func testServiceRepairDoesNotSubmitAfterStaleRemovalFailure() throws {
        let manager = RecordingLegacyHelperServiceJobManager(
            staleRemovalError: TestServiceRepairError.rejected
        )

        XCTAssertThrowsError(
            try withAuthorization { authorization in
                try LegacyHelperServiceEnabler(jobManager: manager)
                    .repairService(authorization: authorization) {}
            }
        ) { error in
            XCTAssertEqual(error as? TestServiceRepairError, .rejected)
        }
        XCTAssertEqual(manager.events, ["remove-if-present"])
    }

    func testServiceRepairPropagatesSubmitFailureWithoutPolling() throws {
        let manager = RecordingLegacyHelperServiceJobManager(
            submitError: TestServiceRepairError.rejected
        )

        XCTAssertThrowsError(
            try withAuthorization { authorization in
                try LegacyHelperServiceEnabler(jobManager: manager)
                    .repairService(authorization: authorization) {}
            }
        ) { error in
            XCTAssertEqual(error as? TestServiceRepairError, .rejected)
        }
        XCTAssertEqual(manager.events, ["remove-if-present", "submit"])
    }

    func testServiceRepairReportsServiceStillDisabledAfterRemovingJob() throws {
        let manager = RecordingLegacyHelperServiceJobManager(
            statuses: [.requiresApproval]
        )

        XCTAssertThrowsError(
            try withAuthorization { authorization in
                try LegacyHelperServiceEnabler(jobManager: manager)
                    .repairService(authorization: authorization) {}
            }
        ) { error in
            XCTAssertEqual(
                (error as? LocalizedError)?.errorDescription,
                "The SMART Helper service remains disabled after the repair attempt."
            )
        }
        XCTAssertEqual(manager.events.filter { $0 == "submit" }.count, 1)
        XCTAssertEqual(manager.events.filter { $0 == "status" }.count, 251)
        XCTAssertEqual(manager.events.last, "remove-if-present")
    }

    func testServiceRepairTimesOutForUnavailableLegacyStatus() throws {
        let manager = RecordingLegacyHelperServiceJobManager(statuses: [.notFound])

        XCTAssertThrowsError(
            try withAuthorization { authorization in
                try LegacyHelperServiceEnabler(jobManager: manager)
                    .repairService(authorization: authorization) {}
            }
        ) { error in
            XCTAssertEqual(
                (error as? LocalizedError)?.errorDescription,
                "Timed out while waiting for the SMART Helper service to become enabled (status 3)."
            )
        }
        XCTAssertEqual(manager.events.filter { $0 == "submit" }.count, 1)
        XCTAssertEqual(manager.events.filter { $0 == "status" }.count, 251)
        XCTAssertEqual(manager.events.last, "remove-if-present")
    }

    func testServiceRepairReportsExecutionAndRemovalFailures() throws {
        let manager = RecordingLegacyHelperServiceJobManager(
            statuses: [.notFound],
            finalRemovalError: TestServiceRepairError.rejected
        )

        XCTAssertThrowsError(
            try withAuthorization { authorization in
                try LegacyHelperServiceEnabler(jobManager: manager)
                    .repairService(authorization: authorization) {
                        throw TestServiceRepairError.rejected
                    }
            }
        ) { error in
            let description = (error as? LocalizedError)?.errorDescription
            XCTAssertTrue(description?.contains("Repair rejected") == true)
            XCTAssertTrue(description?.contains("could not be removed") == true)
        }
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

    private func withAuthorization<T>(
        _ body: (AuthorizationRef) throws -> T
    ) throws -> T {
        var authorizationRef: AuthorizationRef?
        let status = AuthorizationCreate(nil, nil, [], &authorizationRef)
        XCTAssertEqual(status, errAuthorizationSuccess)
        let authorization = try XCTUnwrap(authorizationRef)
        defer { AuthorizationFree(authorization, []) }
        return try body(authorization)
    }
}

private enum TestServiceRepairError: LocalizedError, Equatable {
    case rejected

    var errorDescription: String? {
        "Repair rejected"
    }
}

private final class RecordingLegacyHelperServiceJobManager:
    LegacyHelperServiceJobManaging
{
    private var statuses: [SMAppService.Status]
    private let submitError: Error?
    private let staleRemovalError: Error?
    private let finalRemovalError: Error?
    private var removalCallCount = 0
    private(set) var events: [String] = []

    init(
        statuses: [SMAppService.Status] = [.enabled],
        submitError: Error? = nil,
        staleRemovalError: Error? = nil,
        finalRemovalError: Error? = nil
    ) {
        self.statuses = statuses
        self.submitError = submitError
        self.staleRemovalError = staleRemovalError
        self.finalRemovalError = finalRemovalError
    }

    func submitRepairJob(
        _ job: [String: Any],
        authorization: AuthorizationRef
    ) throws {
        events.append("submit")
        if let submitError {
            throw submitError
        }
    }

    func helperServiceStatus() -> SMAppService.Status {
        events.append("status")
        guard statuses.count > 1 else { return statuses[0] }
        return statuses.removeFirst()
    }

    func removeRepairJob(
        authorization: AuthorizationRef,
        allowsMissing: Bool
    ) throws {
        removalCallCount += 1
        events.append(allowsMissing ? "remove-if-present" : "remove")
        if removalCallCount == 1, let staleRemovalError {
            throw staleRemovalError
        }
        if removalCallCount > 1, let finalRemovalError {
            throw finalRemovalError
        }
    }

    func waitBeforeNextStatusCheck() {
        events.append("wait")
    }

    func waitBeforeInstallRetry() {
        events.append("install-retry-wait")
    }

    func recordInstall() {
        events.append("install")
    }
}

private actor RecordingCompanionProvisioner: SMARTCompanionProvisioning {
    private(set) var binary: Data?

    func installBundledSmartctlCompanion(_ binary: Data) async throws {
        self.binary = binary
    }
}

private actor SequencedCompanionProvisioner: SMARTCompanionProvisioning {
    private var errors: [Error]
    private(set) var callCount = 0

    init(errors: [Error]) {
        self.errors = errors
    }

    func installBundledSmartctlCompanion(_ binary: Data) async throws {
        callCount += 1
        if errors.isEmpty == false {
            throw errors.removeFirst()
        }
    }
}
