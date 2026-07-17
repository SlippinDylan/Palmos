import Foundation
import XCTest
@testable import DrivePulseApp

final class Task7HelperPackagingTests: XCTestCase {
    private enum AppHostError: Error, Equatable {
        case notAppHosted(String)
    }

    func testEmbeddedHelperIncludesBlessableLaunchdPlistSection() throws {
        let launchdPlist = try embeddedLaunchdPlist()

        XCTAssertEqual(
            launchdPlist["Label"] as? String,
            "com.drivepulse.smartservice"
        )

        let machServices = try XCTUnwrap(
            launchdPlist["MachServices"] as? [String: Any],
            "Expected launchd plist to define MachServices. Plist: \(launchdPlist)"
        )
        XCTAssertEqual(
            machServices["com.drivepulse.smartservice"] as? Bool,
            true
        )
    }

    func testAppBundleURLRequirementFailsForNonAppHostedTests() {
        let nonAppBundleURL = URL(fileURLWithPath: "/tmp/DrivePulseAppTests.xctest")

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
                "DrivePulse is ad-hoc signed and cannot participate in the SMART Helper trust check. Sign both DrivePulse targets with the same Apple Development team."
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
                "DrivePulse and the SMART Helper are signed by different teams (APPTEAM and HELPERTEAM). Sign both targets with the same Apple Development team."
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
                "SMART Helper has signing identifier com.example.wrong-helper, expected com.drivepulse.smartservice. Check the target bundle identifier and code-signing settings."
            )
        }
    }

    func testBlessFailureDescriptionPreservesNestedNSErrorDetails() {
        let underlyingError = NSError(
            domain: "com.drivepulse.signing",
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
        XCTAssertTrue(message.contains("ServiceLabel=com.drivepulse.smartservice"))
        XCTAssertTrue(message.contains("Underlying error: [Domain: com.drivepulse.signing"))
        XCTAssertTrue(message.contains("Code: 17"))
        XCTAssertTrue(message.contains("Helper check rejected the app"))
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
            "Contents/Library/LaunchServices/com.drivepulse.smartservice"
        )

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: helperURL.path),
            "Expected embedded helper at \(helperURL.path)"
        )

        let rawLaunchdSection = try runTool(
            "/usr/bin/otool",
            arguments: ["-X", "-s", "__TEXT", "__launchd_plist", helperURL.path]
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
                XCTAssertEqual(word.count, 8, "Expected 32-bit hex words from otool, got \(word)")

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
            }
        }

        XCTAssertFalse(bytes.isEmpty, "No hex payload found in otool section output:\n\(output)")

        return Data(bytes)
    }
}
