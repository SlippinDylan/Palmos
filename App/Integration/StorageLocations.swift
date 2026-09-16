import Foundation

struct StorageLocations {
    enum LocationError: LocalizedError {
        case missingBundleIdentifier

        var errorDescription: String? {
            switch self {
            case .missingBundleIdentifier:
                return "Palmos requires a bundle identifier to resolve app-managed storage locations."
            }
        }
    }

    private let fileManager: FileManager
    private let applicationSupportRootDirectory: URL
    private let cachesRootDirectory: URL
    private let logsRootDirectory: URL
    let temporaryDirectory: URL

    init(fileManager: FileManager = .default, bundle: Bundle = .main) throws {
        guard let bundleIdentifier = bundle.bundleIdentifier, bundleIdentifier.isEmpty == false else {
            throw LocationError.missingBundleIdentifier
        }

        let libraryDirectory = try fileManager.url(
            for: .libraryDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )

        self.init(
            fileManager: fileManager,
            bundleIdentifier: bundleIdentifier,
            libraryDirectory: libraryDirectory,
            temporaryDirectory: fileManager.temporaryDirectory
        )
    }

    init(
        fileManager: FileManager = .default,
        bundleIdentifier: String,
        libraryDirectory: URL,
        temporaryDirectory: URL
    ) {
        self.fileManager = fileManager
        self.applicationSupportRootDirectory = libraryDirectory.appendingPathComponent(
            "Application Support",
            isDirectory: true
        )
        self.cachesRootDirectory = libraryDirectory.appendingPathComponent(
            "Caches",
            isDirectory: true
        )
        self.logsRootDirectory = libraryDirectory.appendingPathComponent(
            "Logs",
            isDirectory: true
        )
        self.temporaryDirectory = temporaryDirectory.appendingPathComponent(
            bundleIdentifier,
            isDirectory: true
        )
        self.bundleIdentifier = bundleIdentifier
    }

    let bundleIdentifier: String

    func applicationSupportDirectory(createIfMissing: Bool = true) throws -> URL {
        try appManagedDirectory(under: applicationSupportRootDirectory, createIfMissing: createIfMissing)
    }

    func cachesDirectory(createIfMissing: Bool = true) throws -> URL {
        try appManagedDirectory(under: cachesRootDirectory, createIfMissing: createIfMissing)
    }

    func logsDirectory(createIfMissing: Bool = true) throws -> URL {
        try appManagedDirectory(under: logsRootDirectory, createIfMissing: createIfMissing)
    }

    private func appManagedDirectory(under root: URL, createIfMissing: Bool) throws -> URL {
        let directory = root.appendingPathComponent(bundleIdentifier, isDirectory: true)
        if createIfMissing {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }
}
