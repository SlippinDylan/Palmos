import Foundation

/// Evidence used to keep a physical device identity stable across BSD-name changes.
public struct DeviceIdentityEvidence: Equatable, Sendable {
    public var mediaUUID: String?
    public var registryEntryID: UInt64?
    public var sessionID: String?

    public init(
        mediaUUID: String? = nil,
        registryEntryID: UInt64? = nil,
        sessionID: String? = nil
    ) {
        self.mediaUUID = mediaUUID
        self.registryEntryID = registryEntryID
        self.sessionID = sessionID
    }

    /// Resolves persistent evidence first, then boot-scoped evidence, and
    /// finally an explicit process-session fallback when the platform exposes
    /// no stable identifier.
    public func deviceID(for physicalBSDName: String) -> DeviceID {
        let normalizedSessionID = Self.normalized(sessionID)
        if let mediaUUID = Self.normalized(mediaUUID) {
            if let normalizedSessionID {
                return DeviceID(rawValue: "session:\(normalizedSessionID):media:\(mediaUUID)")
            }
            return DeviceID(rawValue: "media:\(mediaUUID)")
        }

        if let registryEntryID {
            let sessionID = normalizedSessionID ?? DeviceIdentityResolver.processSessionID
            return DeviceID(
                rawValue: "session:\(sessionID):registry:\(String(registryEntryID, radix: 16))"
            )
        }

        let sessionID = normalizedSessionID ?? DeviceIdentityResolver.processSessionID
        let bsdName = physicalBSDName.trimmingCharacters(in: .whitespacesAndNewlines)
        return DeviceID(rawValue: "session:\(sessionID):\(bsdName)")
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.isEmpty == false else {
            return nil
        }

        return value.lowercased()
    }
}

public enum DeviceIdentityResolver {
    /// Shared by discovery and eject adapters so their fallback IDs agree.
    public static let processSessionID = UUID().uuidString.lowercased()

    public static func isExternalPhysicalDevice(_ descriptor: ExternalDeviceDescriptor) -> Bool {
        guard descriptor.isWholeMedia else { return false }
        guard descriptor.isNetworkVolume == false else { return false }
        guard descriptor.deviceInternal != true else { return false }

        guard case let .physical(transport) = descriptor.backingEvidence else {
            return false
        }

        switch transport {
        case .usb, .thunderbolt, .usb4, .sd, .tunnelledPCIe:
            return true
        }
    }
}
