import Foundation

public enum MediaBackingEvidence: Equatable, Sendable {
    case physical(ExternalPhysicalTransport)
    case virtual
    case unknown
}

public enum ExternalPhysicalTransport: Equatable, Sendable {
    case usb
    case thunderbolt
    case usb4
    case sd
    case tunnelledPCIe
}

public struct ExternalDeviceDescriptor: Sendable, Equatable {
    public var deviceInternal: Bool?
    public var transportPath: [String]
    public var isNetworkVolume: Bool
    public var isWholeMedia: Bool
    public var backingEvidence: MediaBackingEvidence

    public init(
        deviceInternal: Bool?,
        transportPath: [String],
        isNetworkVolume: Bool,
        isWholeMedia: Bool,
        backingEvidence: MediaBackingEvidence = .unknown
    ) {
        self.deviceInternal = deviceInternal
        self.transportPath = transportPath
        self.isNetworkVolume = isNetworkVolume
        self.isWholeMedia = isWholeMedia
        self.backingEvidence = backingEvidence
    }
}
