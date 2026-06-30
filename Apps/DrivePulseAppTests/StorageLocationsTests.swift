import XCTest
@testable import DrivePulseApp

final class StorageLocationsTests: XCTestCase {
    func testAppManagedDirectoriesResolveUnderLibraryUsingBundleIdentifier() throws {
        let root = URL(fileURLWithPath: "/tmp/DrivePulseStorageTests", isDirectory: true)
        let locations = StorageLocations(
            bundleIdentifier: "com.drivepulse.app",
            libraryDirectory: root.appendingPathComponent("Library", isDirectory: true),
            temporaryDirectory: root.appendingPathComponent("tmp", isDirectory: true)
        )

        XCTAssertEqual(
            try locations.applicationSupportDirectory(createIfMissing: false).path,
            "/tmp/DrivePulseStorageTests/Library/Application Support/com.drivepulse.app"
        )
        XCTAssertEqual(
            try locations.cachesDirectory(createIfMissing: false).path,
            "/tmp/DrivePulseStorageTests/Library/Caches/com.drivepulse.app"
        )
        XCTAssertEqual(
            try locations.logsDirectory(createIfMissing: false).path,
            "/tmp/DrivePulseStorageTests/Library/Logs/com.drivepulse.app"
        )
        XCTAssertEqual(
            locations.temporaryDirectory.path,
            "/tmp/DrivePulseStorageTests/tmp/com.drivepulse.app"
        )
    }

    func testCreateIfMissingBuildsAppManagedDirectories() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DrivePulseStorageLocationsTests-\(UUID().uuidString)", isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
        }

        let locations = StorageLocations(
            fileManager: fileManager,
            bundleIdentifier: "com.drivepulse.app",
            libraryDirectory: root.appendingPathComponent("Library", isDirectory: true),
            temporaryDirectory: root.appendingPathComponent("tmp", isDirectory: true)
        )

        let applicationSupportDirectory = try locations.applicationSupportDirectory()
        let cachesDirectory = try locations.cachesDirectory()
        let logsDirectory = try locations.logsDirectory()

        var isDirectory: ObjCBool = false
        XCTAssertTrue(fileManager.fileExists(atPath: applicationSupportDirectory.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertTrue(fileManager.fileExists(atPath: cachesDirectory.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertTrue(fileManager.fileExists(atPath: logsDirectory.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }
}
