import Foundation

public struct ExternalDeviceDescriptor: Sendable, Equatable {
    public var deviceInternal: Bool?
    public var transportPath: [String]
    public var isNetworkVolume: Bool
    public var isWholeMedia: Bool

    public init(
        deviceInternal: Bool?,
        transportPath: [String],
        isNetworkVolume: Bool,
        isWholeMedia: Bool
    ) {
        self.deviceInternal = deviceInternal
        self.transportPath = transportPath
        self.isNetworkVolume = isNetworkVolume
        self.isWholeMedia = isWholeMedia
    }
}
