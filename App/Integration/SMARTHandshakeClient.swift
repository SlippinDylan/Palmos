import Foundation

import PalmosCore

struct SMARTHandshakeClient: Sendable {
    private let isHelperInstalled: @Sendable () -> Bool
    private let fetchHandshake: @Sendable () async throws -> Data

    init(
        isHelperInstalled: @escaping @Sendable () -> Bool,
        fetchHandshake: @escaping @Sendable () async throws -> Data
    ) {
        self.isHelperInstalled = isHelperInstalled
        self.fetchHandshake = fetchHandshake
    }

    func fetch() async throws -> HelperHandshake {
        let data = try await fetchHandshake()
        try Task.checkCancellation()
        return try decode(from: data)
    }

    func evaluate(_ handshake: HelperHandshake) -> XPCCompatibilityResult {
        XPCCompatibilityPolicy.evaluate(
            appMajor: XPCContractVersion.currentMajor,
            appMinor: XPCContractVersion.currentMinor,
            helperMajor: handshake.contractMajor,
            helperMinor: handshake.contractMinor
        )
    }

    func evaluate(from data: Data) throws -> XPCCompatibilityResult {
        evaluate(try decode(from: data))
    }

    func decode(from data: Data) throws -> HelperHandshake {
        guard data.count <= SMARTXPCLimits.handshakeBytes else {
            throw PalmosXPCMessageError.encodedMessageTooLarge
        }
        return try PalmosXPCMessages.decode(HelperHandshake.self, from: data)
    }

    func capabilities(for handshake: HelperHandshake) -> XPCFeatureCapabilities {
        XPCFeatureCapabilities.negotiated(helperContractMinor: handshake.contractMinor)
    }

    func inspect() async -> SMARTHelperInspection {
        guard isHelperInstalled() else {
            return .notInstalled
        }

        do {
            let handshake = try await fetch()
            if evaluate(handshake) == .updateRequired {
                return .updateRequired
            }
            guard capabilities(for: handshake).observableSMARTFailures else {
                return .monitoringUpdateRequired
            }
            if handshake.smartctlCompanionAvailable == false {
                return .companionUnavailable
            }
            return .installed
        } catch {
            return isHelperInstalled()
                ? .failed(error.localizedDescription)
                : .notInstalled
        }
    }
}
