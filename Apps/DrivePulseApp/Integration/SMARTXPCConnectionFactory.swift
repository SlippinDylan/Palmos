import Foundation

enum SMARTXPCConnectionFactory {
    static func fetchHelperHandshake(helperMachServiceName: String) async throws -> Data {
        try await withConnection(helperMachServiceName: helperMachServiceName) { proxy, connection, gate in
            proxy.fetchHelperHandshake { data, error in
                if let error {
                    gate.resume(throwing: error)
                    connection.invalidate()
                    return
                }

                guard let data else {
                    gate.resume(throwing: SMARTServiceClientError.missingReplyData)
                    connection.invalidate()
                    return
                }

                gate.resume(returning: data)
                connection.invalidate()
            }
        }
    }

    static func readSMARTData(
        _ requestData: Data,
        helperMachServiceName: String
    ) async throws -> Data {
        try await withConnection(helperMachServiceName: helperMachServiceName) { proxy, connection, gate in
            proxy.readSMARTData(for: requestData) { data, error in
                if let error {
                    gate.resume(throwing: error)
                    connection.invalidate()
                    return
                }

                guard let data else {
                    gate.resume(throwing: SMARTServiceClientError.missingReplyData)
                    connection.invalidate()
                    return
                }

                gate.resume(returning: data)
                connection.invalidate()
            }
        }
    }

    static func installSmartctlCompanion(
        _ requestData: Data,
        helperMachServiceName: String
    ) async throws -> Data {
        try await withConnection(helperMachServiceName: helperMachServiceName) { proxy, connection, gate in
            guard proxy.installSmartctlCompanion != nil else {
                gate.resume(throwing: SMARTServiceClientError.unsupportedCompanionInstallationEndpoint)
                connection.invalidate()
                return
            }
            proxy.installSmartctlCompanion?(for: requestData) { data, error in
                if let error {
                    gate.resume(throwing: error)
                } else if let data {
                    gate.resume(returning: data)
                } else {
                    gate.resume(throwing: SMARTServiceClientError.missingReplyData)
                }
                connection.invalidate()
            }
        }
    }

    private static func withConnection(
        helperMachServiceName: String,
        _ operation: @escaping (
            DrivePulseSMARTXPCProtocol,
            NSXPCConnection,
            XPCReplyGate
        ) -> Void
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let connection = NSXPCConnection(
                machServiceName: helperMachServiceName,
                options: .privileged
            )
            let gate = XPCReplyGate(continuation: continuation)
            connection.interruptionHandler = {
                gate.resume(throwing: SMARTServiceClientError.connectionInterrupted)
            }
            connection.invalidationHandler = {
                gate.resume(throwing: SMARTServiceClientError.connectionInvalidated)
            }
            connection.remoteObjectInterface = NSXPCInterface(with: DrivePulseSMARTXPCProtocol.self)
            connection.resume()

            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                gate.resume(throwing: error)
                connection.invalidate()
            }

            guard let proxy = proxy as? DrivePulseSMARTXPCProtocol else {
                gate.resume(throwing: SMARTServiceClientError.invalidRemoteProxy)
                connection.invalidate()
                return
            }

            operation(proxy, connection, gate)
        }
    }
}
