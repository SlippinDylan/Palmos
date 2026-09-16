import Foundation

struct HelperDiskMedia: Equatable, Sendable {
    let whole: Bool
    let external: Bool
    let ejectable: Bool
}

enum HelperOccupancyError: Int, Error, Sendable {
    case invalidRequest = 1
    case unsafeTarget = 2
    case targetUnavailable = 3
    case helperBusy = 4
    case scanFailed = 5

    var nsError: NSError {
        NSError(
            domain: "com.palmos.smartservice.occupancy",
            code: rawValue,
            userInfo: [NSLocalizedDescriptionKey: "The occupancy scan could not be completed safely."]
        )
    }
}

struct HelperOccupancyRequestValidator: Sendable {
    typealias MediaLookup = @Sendable (String) async throws -> HelperDiskMedia?
    private let mediaLookup: MediaLookup

    init(mediaLookup: @escaping MediaLookup) {
        self.mediaLookup = mediaLookup
    }

    static func validateRequestBytes(_ data: Data) throws {
        guard data.count <= OccupancyXPCLimits.requestBytes else {
            throw HelperOccupancyError.invalidRequest
        }
    }

    static func validateBSDName(_ name: String) throws {
        guard name.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil else {
            throw HelperOccupancyError.invalidRequest
        }
    }

    static func validate(_ media: HelperDiskMedia) throws {
        guard media.whole, media.external, media.ejectable else {
            throw HelperOccupancyError.unsafeTarget
        }
    }

    func validate(_ request: OccupancyScanRequest) async throws {
        try Self.validateBSDName(request.physicalDeviceBSDName)
        guard let media = try await mediaLookup(request.physicalDeviceBSDName) else {
            throw HelperOccupancyError.targetUnavailable
        }
        try Self.validate(media)
    }
}
