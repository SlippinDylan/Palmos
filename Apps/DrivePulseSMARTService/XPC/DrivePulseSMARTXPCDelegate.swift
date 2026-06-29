import Foundation

final class DrivePulseSMARTXPCDelegate: NSObject, NSXPCListenerDelegate {
    private let authorizedClientRequirement: String?
    private let service: DrivePulseSMARTService

    init(
        service: DrivePulseSMARTService = DrivePulseSMARTService(),
        bundle: Bundle = .main
    ) {
        authorizedClientRequirement = Self.authorizedClientRequirement(from: bundle)
        self.service = service
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        guard let authorizedClientRequirement else {
            return false
        }

        newConnection.setCodeSigningRequirement(authorizedClientRequirement)
        newConnection.exportedInterface = NSXPCInterface(with: DrivePulseSMARTXPCProtocol.self)
        newConnection.exportedObject = service
        newConnection.resume()
        return true
    }

    private static func authorizedClientRequirement(from bundle: Bundle) -> String? {
        guard let authorizedClients = bundle.object(
            forInfoDictionaryKey: "SMAuthorizedClients"
        ) as? [String] else {
            return nil
        }

        let requirements = authorizedClients
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }

        guard requirements.isEmpty == false else {
            return nil
        }

        if requirements.count == 1 {
            return requirements[0]
        }

        return requirements
            .map { "(\($0))" }
            .joined(separator: " or ")
    }
}
